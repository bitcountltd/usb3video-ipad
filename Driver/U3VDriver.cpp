//
//  U3VDriver.cpp
//
//  Data path (no CPU copies anywhere):
//
//    camera --bulk IN DMA--> IOBufferMemoryDescriptor (frame slot) --mapped--> app
//                                                          \--MTLBuffer(bytesNoCopy)--> GPU
//
//  Every frame is three bulk-IN transfers into three whole buffers, all allocated with
//  IOUSBHostInterface::CreateIOBuffer (controller-optimised, never bounced):
//    leader  -> small per-slot buffer (parsed by the driver)
//    payload -> the frame buffer itself, one transfer for the whole image (shared with app/GPU)
//    trailer -> small per-slot buffer
//
//  History: sub-descriptors into one big buffer (CreateSubMemoryDescriptor), with or without
//  the AsyncIOBundled descriptor ring, panicked iPadOS 27.0 (24A446) on stream start:
//  "A kext releasing a(n) AppleUSBHostClientBufferMemoryDescriptor has corrupted the registry"
//  in IOUSBHostFamily. Hence whole buffers only.
//

#include <os/log.h>
#include <string.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/OSAction.h>
#include <USBDriverKit/IOUSBHostDevice.h>
#include <USBDriverKit/IOUSBHostInterface.h>
#include <USBDriverKit/IOUSBHostPipe.h>
#include <USBDriverKit/AppleUSBDescriptorParsing.h>
#include <USBDriverKit/USBDriverKitDefs.h>

#include "U3VDriver.h"
#include "U3VProtocol.h"
#include "U3VShared.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "U3VDriver: " fmt, ##__VA_ARGS__)

static constexpr uint32_t kSegmentsPerSlot   = 3;      // leader, payload, trailer
static constexpr uint32_t kLeaderSegment     = 0;
static constexpr uint32_t kPayloadSegment    = 1;
static constexpr uint32_t kTrailerSegment    = 2;
static constexpr uint32_t kFramesInFlight    = 3;
static constexpr uint32_t kMaxTransferSize   = 1024 * 1024;
static constexpr uint32_t kControlBufferSize = 8192;
static constexpr uint32_t kPageSize          = 16384;
static constexpr uint32_t kDefaultTimeoutMs  = 1000;

static inline uint32_t AlignUp(uint32_t value, uint32_t alignment) {
    return (value + alignment - 1) / alignment * alignment;
}

struct U3VDriver_IVars {
    IOUSBHostInterface *controlInterface;
    IOUSBHostInterface *streamInterface;
    IOUSBHostPipe      *controlOut;
    IOUSBHostPipe      *controlIn;
    IOUSBHostPipe      *streamIn;

    // Control channel
    IOLock                   *controlLock;
    IOBufferMemoryDescriptor *cmdMemory;
    IOBufferMemoryDescriptor *ackMemory;
    uint8_t                  *cmd;
    uint8_t                  *ack;
    uint32_t                  maxCmd;
    uint32_t                  maxAck;
    uint32_t                  responseTimeMs;
    uint16_t                  requestId;
    uint64_t                  sirmAddress;

    // Shared memory
    IOBufferMemoryDescriptor *pageMemory;
    U3VControlPage           *page;
    IOBufferMemoryDescriptor *frameMemory[U3V_MAX_FRAME_BUFFERS];
    IOBufferMemoryDescriptor *leaderMemory[U3V_MAX_FRAME_BUFFERS];
    IOBufferMemoryDescriptor *trailerMemory[U3V_MAX_FRAME_BUFFERS];
    uint8_t                  *leaderAddress[U3V_MAX_FRAME_BUFFERS];
    uint8_t                  *trailerAddress[U3V_MAX_FRAME_BUFFERS];

    // Stream geometry
    uint32_t segmentLength[kSegmentsPerSlot];
    uint32_t bufferCount;
    uint32_t bufferSize;
    uint32_t payloadCapacity;
    uint64_t requiredPayload;

    // Stream state (guarded by streamLock)
    IOLock   *streamLock;
    OSAction *segmentActions[U3V_MAX_FRAME_BUFFERS][kSegmentsPerSlot];   // one per transfer
    bool      streaming;
    bool      ready;            // Setup() completed; control/stream pipes are usable
    uint32_t  inFlight[U3V_MAX_FRAME_BUFFERS];
    uint32_t  inFlightHead;
    uint32_t  inFlightCount;
    uint32_t  segmentsDone[U3V_MAX_FRAME_BUFFERS];
    uint32_t  payloadBytes[U3V_MAX_FRAME_BUFFERS];
    uint32_t  leaderBytes[U3V_MAX_FRAME_BUFFERS];
    uint32_t  trailerBytes[U3V_MAX_FRAME_BUFFERS];
    bool      slotFailed[U3V_MAX_FRAME_BUFFERS];
    uint64_t  readySequence[U3V_MAX_FRAME_BUFFERS];
    uint64_t  sequence;
};

#pragma mark - Lifecycle

bool U3VDriver::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(U3VDriver_IVars, 1);
    if (ivars == nullptr) {
        return false;
    }
    ivars->controlLock = IOLockAlloc();
    ivars->streamLock = IOLockAlloc();
    ivars->maxCmd = 1024;
    ivars->maxAck = 1024;
    ivars->responseTimeMs = kDefaultTimeoutMs;
    return ivars->controlLock != nullptr && ivars->streamLock != nullptr;
}

void U3VDriver::free()
{
    if (ivars != nullptr) {
        ReleaseBuffers();
        OSSafeReleaseNULL(ivars->pageMemory);
        OSSafeReleaseNULL(ivars->cmdMemory);
        OSSafeReleaseNULL(ivars->ackMemory);
        for (uint32_t i = 0; i < U3V_MAX_FRAME_BUFFERS; i++) {
            for (uint32_t j = 0; j < kSegmentsPerSlot; j++) OSSafeReleaseNULL(ivars->segmentActions[i][j]);
        }
        if (ivars->controlLock) IOLockFree(ivars->controlLock);
        if (ivars->streamLock) IOLockFree(ivars->streamLock);
    }
    IOSafeDeleteNULL(ivars, U3VDriver_IVars, 1);
    super::free();
}

static kern_return_t AllocateMapped(uint64_t size, IOBufferMemoryDescriptor **memory, uint8_t **address)
{
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, size, kPageSize, memory);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    (*memory)->SetLength(size);
    IOAddressSegment range = {};
    ret = (*memory)->GetAddressRange(&range);
    if (ret != kIOReturnSuccess) {
        OSSafeReleaseNULL(*memory);
        return ret;
    }
    *address = reinterpret_cast<uint8_t *>(range.address);
    memset(*address, 0, size);
    return kIOReturnSuccess;
}

kern_return_t IMPL(U3VDriver, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    uint8_t *pageAddress = nullptr;
    ret = AllocateMapped(U3V_CONTROL_PAGE_SIZE, &ivars->pageMemory, &pageAddress);
    if (ret != kIOReturnSuccess) {
        LOG("control page allocation failed 0x%x", ret);
        Stop(provider, SUPERDISPATCH);
        return ret;
    }
    ivars->page = reinterpret_cast<U3VControlPage *>(pageAddress);
    ivars->page->magic = U3V_CONTROL_PAGE_MAGIC;
    ivars->page->version = U3V_CONTROL_PAGE_VERSION;

    // Register first and stay registered even if the camera setup below fails, so the app
    // can connect and read startStage/startError from the control page.
    RegisterService();

    ret = Setup(provider);
    ivars->page->startError = ret;
    if (ret == kIOReturnSuccess) {
        ivars->page->startStage = kU3VStageReady;
        ivars->ready = true;
        LOG("ready: maxCmd %u maxAck %u SIRM 0x%llx response %u ms",
            ivars->maxCmd, ivars->maxAck, ivars->sirmAddress, ivars->responseTimeMs);
    } else {
        LOG("setup failed at stage %u: 0x%x", ivars->page->startStage, ret);
    }
    return kIOReturnSuccess;
}

kern_return_t U3VDriver::Setup(IOService *provider)
{
    ivars->page->startStage = kU3VStageBuffers;
    kern_return_t ret = AllocateMapped(kControlBufferSize, &ivars->cmdMemory, &ivars->cmd);
    if (ret == kIOReturnSuccess) ret = AllocateMapped(kControlBufferSize, &ivars->ackMemory, &ivars->ack);
    if (ret != kIOReturnSuccess) return ret;

    ivars->page->startStage = kU3VStageActions;
    for (uint32_t i = 0; ret == kIOReturnSuccess && i < U3V_MAX_FRAME_BUFFERS; i++) {
        for (uint32_t j = 0; ret == kIOReturnSuccess && j < kSegmentsPerSlot; j++) {
            ret = CreateActionStreamComplete(sizeof(uint32_t), &ivars->segmentActions[i][j]);
            if (ret == kIOReturnSuccess) {
                *static_cast<uint32_t *>(ivars->segmentActions[i][j]->GetReference()) = i * kSegmentsPerSlot + j;
            }
        }
    }
    if (ret != kIOReturnSuccess) return ret;

    ret = OpenInterfaces(provider);
    if (ret != kIOReturnSuccess) return ret;

    // Bootstrap registers: response time, SBRM -> max packet sizes and SIRM address.
    ivars->page->startStage = kU3VStageBootstrap;
    uint32_t responseMs = 0;
    uint64_t sbrm = 0;
    uint32_t maxCmd = 0, maxAck = 0;
    if (ReadMemory(ABRM_MAX_DEVICE_RESPONSE_TIME, &responseMs, sizeof(responseMs)) == kIOReturnSuccess && responseMs) {
        ivars->responseTimeMs = responseMs + 100;
    }
    ret = ReadMemory(ABRM_SBRM_ADDRESS, &sbrm, sizeof(sbrm));
    if (ret == kIOReturnSuccess) ret = ReadMemory(sbrm + SBRM_MAX_CMD_TRANSFER, &maxCmd, sizeof(maxCmd));
    if (ret == kIOReturnSuccess) ret = ReadMemory(sbrm + SBRM_MAX_ACK_TRANSFER, &maxAck, sizeof(maxAck));
    if (ret == kIOReturnSuccess) ret = ReadMemory(sbrm + SBRM_SIRM_ADDRESS, &ivars->sirmAddress, sizeof(ivars->sirmAddress));
    if (ret != kIOReturnSuccess) return ret;
    if (maxCmd) ivars->maxCmd = maxCmd < kControlBufferSize ? maxCmd : kControlBufferSize;
    if (maxAck) ivars->maxAck = maxAck < kControlBufferSize ? maxAck : kControlBufferSize;
    return kIOReturnSuccess;
}

kern_return_t IMPL(U3VDriver, Stop)
{
    StopStream();
    if (ivars->streamInterface) {
        ivars->streamInterface->Close(this, 0);
    }
    if (ivars->controlInterface) {
        ivars->controlInterface->Close(this, 0);
    }
    OSSafeReleaseNULL(ivars->streamIn);
    OSSafeReleaseNULL(ivars->controlIn);
    OSSafeReleaseNULL(ivars->controlOut);
    OSSafeReleaseNULL(ivars->streamInterface);
    OSSafeReleaseNULL(ivars->controlInterface);
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(U3VDriver, NewUserClient)
{
    IOService *client = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    *userClient = OSDynamicCast(IOUserClient, client);
    if (*userClient == nullptr) {
        client->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

#pragma mark - USB plumbing

static void FindBulkPipes(IOUSBHostInterface *interface, IOUSBHostPipe **in, IOUSBHostPipe **out)
{
    const IOUSBConfigurationDescriptor *config = interface->CopyConfigurationDescriptor();
    if (config == nullptr) {
        return;
    }
    const IOUSBInterfaceDescriptor *ifDesc = interface->GetInterfaceDescriptor(config);
    const IOUSBEndpointDescriptor *ep = nullptr;
    while (ifDesc && (ep = IOUSBGetNextEndpointDescriptor(config, ifDesc, reinterpret_cast<const IOUSBDescriptorHeader *>(ep)))) {
        if (IOUSBGetEndpointType(ep) != kIOUSBEndpointTypeBulk) {
            continue;
        }
        bool isIn = IOUSBGetEndpointDirection(ep) == kIOUSBEndpointDirectionIn;
        IOUSBHostPipe **target = isIn ? in : out;
        if (target && *target == nullptr) {
            interface->CopyPipe(IOUSBGetEndpointAddress(ep), target);
        }
    }
    IOUSBHostFreeDescriptor(config);
}

static bool InterfaceMatches(IOUSBHostInterface *interface, uint8_t protocol)
{
    const IOUSBConfigurationDescriptor *config = interface->CopyConfigurationDescriptor();
    if (config == nullptr) {
        return false;
    }
    const IOUSBInterfaceDescriptor *d = interface->GetInterfaceDescriptor(config);
    bool match = d && d->bInterfaceClass == U3V_INTERFACE_CLASS &&
                 d->bInterfaceSubClass == U3V_INTERFACE_SUBCLASS && d->bInterfaceProtocol == protocol;
    IOUSBHostFreeDescriptor(config);
    return match;
}

kern_return_t U3VDriver::OpenInterfaces(IOService *provider)
{
    ivars->controlInterface = OSDynamicCast(IOUSBHostInterface, provider);
    if (ivars->controlInterface == nullptr) {
        return kIOReturnNoDevice;
    }
    ivars->controlInterface->retain();
    ivars->page->startStage = kU3VStageOpenControl;
    kern_return_t ret = ivars->controlInterface->Open(this, 0, 0);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    ivars->page->startStage = kU3VStageControlPipes;
    FindBulkPipes(ivars->controlInterface, &ivars->controlIn, &ivars->controlOut);
    if (!ivars->controlIn || !ivars->controlOut) {
        LOG("control interface is missing bulk endpoints");
        return kIOReturnNoResources;
    }

    // We match the control interface; the streaming interface is its sibling on the same device.
    ivars->page->startStage = kU3VStageFindStream;
    IOUSBHostDevice *device = nullptr;
    ret = ivars->controlInterface->CopyDevice(&device);
    if (ret != kIOReturnSuccess || device == nullptr) {
        return ret != kIOReturnSuccess ? ret : kIOReturnNoDevice;
    }
    uintptr_t iterator = 0;
    if (device->CreateInterfaceIterator(&iterator) == kIOReturnSuccess) {
        IOUSBHostInterface *candidate = nullptr;
        while (device->CopyInterface(iterator, &candidate) == kIOReturnSuccess && candidate) {
            if (ivars->streamInterface == nullptr && InterfaceMatches(candidate, U3V_PROTOCOL_STREAM)) {
                ivars->streamInterface = candidate;
            } else {
                candidate->release();
            }
            candidate = nullptr;
        }
        device->DestroyInterfaceIterator(iterator);
    }
    device->release();

    if (ivars->streamInterface == nullptr) {
        LOG("no USB3 Vision streaming interface found");
        return kIOReturnNotFound;
    }
    ivars->page->startStage = kU3VStageOpenStream;
    ret = ivars->streamInterface->Open(this, 0, 0);
    if (ret != kIOReturnSuccess) {
        LOG("opening streaming interface failed 0x%x", ret);
        OSSafeReleaseNULL(ivars->streamInterface);
        return ret;
    }
    ivars->page->startStage = kU3VStageStreamPipe;
    FindBulkPipes(ivars->streamInterface, &ivars->streamIn, nullptr);
    return ivars->streamIn ? kIOReturnSuccess : kIOReturnNoResources;
}

#pragma mark - Control channel (GenCP over U3VCP)

kern_return_t U3VDriver::Transact(uint16_t command, uint64_t address, const void *writeData,
                                  uint32_t writeLength, void *readData, uint32_t readLength)
{
    if (ivars->controlOut == nullptr || ivars->controlIn == nullptr) {
        return kIOReturnNotReady;
    }
    IOLockLock(ivars->controlLock);

    uint16_t id = ++ivars->requestId;
    if (id == 0) id = ivars->requestId = 1;

    uint32_t cmdSize;
    uint32_t ackSize;
    uint16_t expectedAck;
    U3VCPHeader *header = reinterpret_cast<U3VCPHeader *>(ivars->cmd);
    header->magic = U3VCP_MAGIC;
    header->flagsOrStatus = U3VCP_FLAG_REQUEST_ACK;
    header->command = command;
    header->requestId = id;
    if (command == U3VCP_READMEM_CMD) {
        U3VCPReadMemCmd *read = reinterpret_cast<U3VCPReadMemCmd *>(ivars->cmd);
        read->address = address;
        read->reserved = 0;
        read->readLength = static_cast<uint16_t>(readLength);
        header->length = sizeof(U3VCPReadMemCmd) - sizeof(U3VCPHeader);
        cmdSize = sizeof(U3VCPReadMemCmd);
        ackSize = sizeof(U3VCPHeader) + readLength;
        expectedAck = U3VCP_READMEM_ACK;
    } else {
        U3VCPWriteMemCmd *write = reinterpret_cast<U3VCPWriteMemCmd *>(ivars->cmd);
        write->address = address;
        memcpy(ivars->cmd + sizeof(U3VCPWriteMemCmd), writeData, writeLength);
        header->length = static_cast<uint16_t>(sizeof(uint64_t) + writeLength);
        cmdSize = sizeof(U3VCPWriteMemCmd) + writeLength;
        ackSize = sizeof(U3VCPHeader) + 4;
        expectedAck = U3VCP_WRITEMEM_ACK;
    }
    // A pending ack is 16 bytes; never ask for less or it would overflow the request.
    if (ackSize < sizeof(U3VCPPendingAck)) ackSize = sizeof(U3VCPPendingAck);

    uint32_t transferred = 0;
    kern_return_t ret = ivars->controlOut->IO(ivars->cmdMemory, cmdSize, &transferred, kDefaultTimeoutMs);
    if (ret != kIOReturnSuccess) {
        LOG("command send failed 0x%x", ret);
        ivars->controlOut->ClearStall(true);
        IOLockUnlock(ivars->controlLock);
        return ret;
    }

    uint32_t timeoutMs = ivars->responseTimeMs;
    for (int attempts = 0; attempts < 32; attempts++) {
        ret = ivars->controlIn->IO(ivars->ackMemory, ackSize, &transferred, timeoutMs);
        if (ret != kIOReturnSuccess) {
            if (ret != kIOReturnTimeout) ivars->controlIn->ClearStall(true);
            break;
        }
        const U3VCPHeader *ack = reinterpret_cast<const U3VCPHeader *>(ivars->ack);
        if (transferred < sizeof(U3VCPHeader) || ack->magic != U3VCP_MAGIC) {
            ret = kIOReturnBadMessageID;
            continue;
        }
        if (ack->command == U3VCP_PENDING_ACK) {
            const U3VCPPendingAck *pending = reinterpret_cast<const U3VCPPendingAck *>(ivars->ack);
            timeoutMs = pending->timeoutMs + 100;
            continue;
        }
        if (ack->requestId != id || ack->command != expectedAck) {
            ret = kIOReturnBadMessageID;    // stale ack from an earlier timed-out request
            continue;
        }
        if (ack->flagsOrStatus != 0) {
            LOG("device status 0x%04x for cmd 0x%04x @0x%llx", ack->flagsOrStatus, command, address);
            ret = kIOReturnDeviceError;
            break;
        }
        if (command == U3VCP_READMEM_CMD) {
            if (ack->length < readLength) {
                ret = kIOReturnUnderrun;
                break;
            }
            memcpy(readData, ivars->ack + sizeof(U3VCPHeader), readLength);
        }
        ret = kIOReturnSuccess;
        break;
    }

    IOLockUnlock(ivars->controlLock);
    return ret;
}

kern_return_t U3VDriver::ReadMemory(uint64_t address, void *buffer, uint32_t length)
{
    uint8_t *out = static_cast<uint8_t *>(buffer);
    uint32_t chunkMax = ivars->maxAck - sizeof(U3VCPHeader);
    while (length > 0) {
        uint32_t chunk = length < chunkMax ? length : chunkMax;
        kern_return_t ret = Transact(U3VCP_READMEM_CMD, address, nullptr, 0, out, chunk);
        if (ret != kIOReturnSuccess) return ret;
        address += chunk;
        out += chunk;
        length -= chunk;
    }
    return kIOReturnSuccess;
}

kern_return_t U3VDriver::WriteMemory(uint64_t address, const void *buffer, uint32_t length)
{
    const uint8_t *in = static_cast<const uint8_t *>(buffer);
    uint32_t chunkMax = ivars->maxCmd - sizeof(U3VCPWriteMemCmd);
    while (length > 0) {
        uint32_t chunk = length < chunkMax ? length : chunkMax;
        kern_return_t ret = Transact(U3VCP_WRITEMEM_CMD, address, in, chunk, nullptr, 0);
        if (ret != kIOReturnSuccess) return ret;
        address += chunk;
        in += chunk;
        length -= chunk;
    }
    return kIOReturnSuccess;
}

void U3VDriver::GetDeviceInfo(uint64_t *maxCmd, uint64_t *maxAck, uint64_t *sirm, uint64_t *responseMs)
{
    *maxCmd = ivars->maxCmd;
    *maxAck = ivars->maxAck;
    *sirm = ivars->sirmAddress;
    *responseMs = ivars->responseTimeMs;
}

#pragma mark - Buffers

void U3VDriver::ReleaseBuffers()
{
    for (uint32_t i = 0; i < U3V_MAX_FRAME_BUFFERS; i++) {
        OSSafeReleaseNULL(ivars->frameMemory[i]);
        OSSafeReleaseNULL(ivars->leaderMemory[i]);
        OSSafeReleaseNULL(ivars->trailerMemory[i]);
        ivars->leaderAddress[i] = nullptr;
        ivars->trailerAddress[i] = nullptr;
    }
    ivars->bufferCount = 0;
    ivars->bufferSize = 0;
}

static kern_return_t CreateUSBBuffer(IOUSBHostInterface *interface, uint32_t size,
                                     IOBufferMemoryDescriptor **memory, uint8_t **address)
{
    kern_return_t ret = interface->CreateIOBuffer(kIOMemoryDirectionIn, size, memory);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    (*memory)->SetLength(size);
    if (address) {
        IOAddressSegment range = {};
        ret = (*memory)->GetAddressRange(&range);
        if (ret != kIOReturnSuccess) {
            OSSafeReleaseNULL(*memory);
            return ret;
        }
        *address = reinterpret_cast<uint8_t *>(range.address);
        memset(*address, 0, size);
    }
    return kIOReturnSuccess;
}

kern_return_t U3VDriver::ConfigureBuffers(uint32_t count)
{
    // The payload starts at offset 0 of the frame buffer, so the app hands the whole mapping
    // to Metal without an offset; the size is page rounded for MTLBuffer(bytesNoCopy:).
    uint32_t size = AlignUp(ivars->payloadCapacity, kPageSize);
    if (size == ivars->bufferSize && count == ivars->bufferCount) {
        return kIOReturnSuccess;
    }

    ReleaseBuffers();
    for (uint32_t i = 0; i < count; i++) {
        IOUSBHostInterface *usb = ivars->streamInterface;
        kern_return_t ret = CreateUSBBuffer(usb, size, &ivars->frameMemory[i], nullptr);
        if (ret == kIOReturnSuccess) {
            ret = CreateUSBBuffer(usb, AlignUp(ivars->segmentLength[kLeaderSegment], 4096),
                                  &ivars->leaderMemory[i], &ivars->leaderAddress[i]);
        }
        if (ret == kIOReturnSuccess) {
            ret = CreateUSBBuffer(usb, AlignUp(ivars->segmentLength[kTrailerSegment], 4096),
                                  &ivars->trailerMemory[i], &ivars->trailerAddress[i]);
        }
        if (ret != kIOReturnSuccess) {
            LOG("USB buffer allocation failed (%u bytes) 0x%x", size, ret);
            ReleaseBuffers();
            return ret;
        }
    }
    ivars->bufferCount = count;
    ivars->bufferSize = size;
    ivars->page->bufferCount = count;
    ivars->page->bufferSize = size;
    ivars->page->payloadCapacity = ivars->payloadCapacity;
    return kIOReturnSuccess;
}

kern_return_t U3VDriver::CopyClientMemory(uint64_t type, IOMemoryDescriptor **memory)
{
    IOBufferMemoryDescriptor *md = nullptr;
    if (type == kU3VMemoryTypeControlPage) {
        md = ivars->pageMemory;
    } else if (type >= kU3VMemoryTypeFrameBase && type - kU3VMemoryTypeFrameBase < ivars->bufferCount) {
        md = ivars->frameMemory[type - kU3VMemoryTypeFrameBase];
    }
    if (md == nullptr) {
        return kIOReturnBadArgument;
    }
    md->retain();
    *memory = md;
    return kIOReturnSuccess;
}

#pragma mark - Streaming

kern_return_t U3VDriver::StartStream(uint32_t requestedBuffers, uint64_t *bufferCount,
                                     uint64_t *bufferSize, uint64_t *payloadSize)
{
    if (!ivars->ready || ivars->streamIn == nullptr) {
        return kIOReturnNotReady;
    }
    StopStream();

    uint64_t sirm = ivars->sirmAddress;
    uint32_t info = 0, reqLeader = 0, reqTrailer = 0;
    uint64_t reqPayload = 0;
    kern_return_t ret = ReadMemory(sirm + SIRM_INFO, &info, sizeof(info));
    if (ret == kIOReturnSuccess) ret = ReadMemory(sirm + SIRM_REQ_PAYLOAD_SIZE, &reqPayload, sizeof(reqPayload));
    if (ret == kIOReturnSuccess) ret = ReadMemory(sirm + SIRM_REQ_LEADER_SIZE, &reqLeader, sizeof(reqLeader));
    if (ret == kIOReturnSuccess) ret = ReadMemory(sirm + SIRM_REQ_TRAILER_SIZE, &reqTrailer, sizeof(reqTrailer));
    if (ret != kIOReturnSuccess) return ret;
    if (reqPayload == 0 || reqPayload > 0x7fffffff) return kIOReturnBadArgument;

    uint32_t alignment = 1u << ((info >> SIRM_INFO_ALIGNMENT_SHIFT) & 0x1f);
    uint32_t required = static_cast<uint32_t>(reqPayload);
    uint32_t leaderSize = AlignUp(reqLeader ? reqLeader : 1024, alignment);
    uint32_t trailerSize = AlignUp(reqTrailer ? reqTrailer : 1024, alignment);

    // Ask the camera for the whole image as one transfer, read with one request straight into
    // the frame buffer. If the camera refuses that size, split it into 1 MB transfers; the
    // single host request still receives them back to back (no short packets until the end).
    uint32_t transfer = AlignUp(required, alignment);
    uint32_t count = 1;
    uint32_t final1 = 0;
    uint32_t zero = 0;
    ret = WriteMemory(sirm + SIRM_MAX_LEADER_SIZE, &leaderSize, 4);
    if (ret == kIOReturnSuccess) ret = WriteMemory(sirm + SIRM_MAX_TRAILER_SIZE, &trailerSize, 4);
    if (ret == kIOReturnSuccess && WriteMemory(sirm + SIRM_PAYLOAD_SIZE, &transfer, 4) != kIOReturnSuccess) {
        transfer = kMaxTransferSize / alignment * alignment;
        count = required / transfer;
        final1 = AlignUp(required % transfer, alignment);
        ret = WriteMemory(sirm + SIRM_PAYLOAD_SIZE, &transfer, 4);
    }
    if (ret == kIOReturnSuccess) ret = WriteMemory(sirm + SIRM_PAYLOAD_COUNT, &count, 4);
    if (ret == kIOReturnSuccess) ret = WriteMemory(sirm + SIRM_TRANSFER1_SIZE, &final1, 4);
    if (ret == kIOReturnSuccess) ret = WriteMemory(sirm + SIRM_TRANSFER2_SIZE, &zero, 4);
    if (ret != kIOReturnSuccess) {
        LOG("SIRM configuration failed 0x%x", ret);
        return ret;
    }

    IOLockLock(ivars->streamLock);
    ivars->requiredPayload = required;
    ivars->payloadCapacity = transfer * count + final1;
    ivars->segmentLength[kLeaderSegment] = leaderSize;
    ivars->segmentLength[kPayloadSegment] = ivars->payloadCapacity;
    ivars->segmentLength[kTrailerSegment] = trailerSize;

    uint32_t buffers = requestedBuffers;
    if (buffers < kFramesInFlight + 2) buffers = kFramesInFlight + 2;
    if (buffers > U3V_MAX_FRAME_BUFFERS) buffers = U3V_MAX_FRAME_BUFFERS;
    ret = ConfigureBuffers(buffers);
    if (ret != kIOReturnSuccess) {
        IOLockUnlock(ivars->streamLock);
        return ret;
    }
    LOG("stream: payload %u = %u x %u + %u, leader %u, trailer %u, %u buffers of %u bytes",
        required, count, transfer, final1, leaderSize, trailerSize, buffers, ivars->bufferSize);
    IOLockUnlock(ivars->streamLock);

    ivars->streamIn->ClearStall(true);
    uint32_t enable = SIRM_CONTROL_STREAM_ENABLE;
    ret = WriteMemory(sirm + SIRM_CONTROL, &enable, 4);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    IOLockLock(ivars->streamLock);
    U3VControlPage *page = ivars->page;
    for (uint32_t i = 0; i < U3V_MAX_FRAME_BUFFERS; i++) {
        U3VStoreState(page, i, kU3VBufferFree);
        ivars->readySequence[i] = 0;
    }
    U3VStoreLatest(page, 0);
    page->framesCompleted = page->framesIncomplete = page->framesStolen = page->transferErrors = 0;
    page->lastError = 0;
    ivars->inFlightHead = ivars->inFlightCount = 0;
    ivars->streaming = true;
    page->streaming = 1;
    Replenish();
    IOLockUnlock(ivars->streamLock);

    *bufferCount = ivars->bufferCount;
    *bufferSize = ivars->bufferSize;
    *payloadSize = ivars->requiredPayload;
    return kIOReturnSuccess;
}

kern_return_t U3VDriver::StopStream()
{
    IOLockLock(ivars->streamLock);
    bool wasStreaming = ivars->streaming;
    ivars->streaming = false;
    if (ivars->page) ivars->page->streaming = 0;
    IOLockUnlock(ivars->streamLock);
    if (!wasStreaming) {
        return kIOReturnSuccess;
    }

    uint32_t disable = 0;
    WriteMemory(ivars->sirmAddress + SIRM_CONTROL, &disable, 4);
    if (ivars->streamIn) {
        ivars->streamIn->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    }

    IOLockLock(ivars->streamLock);
    for (uint32_t i = 0; i < ivars->bufferCount; i++) {
        if (U3VLoadState(ivars->page, i) != kU3VBufferHeld) {
            U3VStoreState(ivars->page, i, kU3VBufferFree);
        }
    }
    ivars->inFlightHead = ivars->inFlightCount = 0;
    IOLockUnlock(ivars->streamLock);
    return kIOReturnSuccess;
}

// Called with streamLock held.
kern_return_t U3VDriver::QueueSlot(uint32_t slot)
{
    ivars->segmentsDone[slot] = 0;
    ivars->payloadBytes[slot] = 0;
    ivars->leaderBytes[slot] = 0;
    ivars->trailerBytes[slot] = 0;
    ivars->slotFailed[slot] = false;

    IOMemoryDescriptor *buffers[kSegmentsPerSlot] = {
        ivars->leaderMemory[slot], ivars->frameMemory[slot], ivars->trailerMemory[slot],
    };
    kern_return_t ret = kIOReturnSuccess;
    for (uint32_t s = 0; s < kSegmentsPerSlot && ret == kIOReturnSuccess; s++) {
        ret = ivars->streamIn->AsyncIO(buffers[s], ivars->segmentLength[s], ivars->segmentActions[slot][s], 0);
    }
    if (ret != kIOReturnSuccess) {
        ivars->page->lastError = ret;
        return ret;
    }
    U3VStoreState(ivars->page, slot, kU3VBufferQueued);
    ivars->inFlight[(ivars->inFlightHead + ivars->inFlightCount) % U3V_MAX_FRAME_BUFFERS] = slot;
    ivars->inFlightCount++;
    return kIOReturnSuccess;
}

// Called with streamLock held. Keeps kFramesInFlight frames queued on the bus.
void U3VDriver::Replenish()
{
    U3VControlPage *page = ivars->page;
    while (ivars->streaming && ivars->inFlightCount < kFramesInFlight) {
        int pick = -1;
        for (uint32_t i = 0; i < ivars->bufferCount && pick < 0; i++) {
            if (U3VCompareExchangeState(page, i, kU3VBufferFree, kU3VBufferQueued)) pick = static_cast<int>(i);
        }
        if (pick < 0) {
            // App is slow: reclaim the oldest published-but-unclaimed frame, never the newest
            // unless the bus would otherwise go idle.
            uint64_t newest = U3VLoadLatest(page) >> 8;
            int oldest = -1;
            for (uint32_t i = 0; i < ivars->bufferCount; i++) {
                if (U3VLoadState(page, i) != kU3VBufferReady) continue;
                if (ivars->readySequence[i] == newest && ivars->inFlightCount > 0) continue;
                if (oldest < 0 || ivars->readySequence[i] < ivars->readySequence[oldest]) oldest = static_cast<int>(i);
            }
            if (oldest >= 0 && U3VCompareExchangeState(page, oldest, kU3VBufferReady, kU3VBufferQueued)) {
                pick = oldest;
                page->framesStolen++;
            }
        }
        if (pick < 0 || QueueSlot(static_cast<uint32_t>(pick)) != kIOReturnSuccess) {
            if (pick >= 0) U3VStoreState(page, pick, kU3VBufferFree);
            break;
        }
    }
}

// Called with streamLock held.
void U3VDriver::SegmentDone(uint32_t slot, uint32_t segment, IOReturn status, uint32_t bytes)
{
    if (status != kIOReturnSuccess) {
        ivars->slotFailed[slot] = true;
        if (status != kIOReturnAborted) {
            ivars->page->transferErrors++;
            ivars->page->lastError = status;
        }
    }
    if (segment == kLeaderSegment) {
        ivars->leaderBytes[slot] = bytes;
    } else if (segment == kTrailerSegment) {
        ivars->trailerBytes[slot] = bytes;
    } else {
        ivars->payloadBytes[slot] += bytes;
    }
    if (++ivars->segmentsDone[slot] == kSegmentsPerSlot) {
        FinishFrame(slot);
    }
}

// Called with streamLock held.
void U3VDriver::FinishFrame(uint32_t slot)
{
    U3VControlPage *page = ivars->page;
    if (ivars->inFlightCount > 0 && ivars->inFlight[ivars->inFlightHead] == slot) {
        ivars->inFlightHead = (ivars->inFlightHead + 1) % U3V_MAX_FRAME_BUFFERS;
        ivars->inFlightCount--;
    }

    const U3VImageLeader *leader = reinterpret_cast<const U3VImageLeader *>(ivars->leaderAddress[slot]);
    const U3VImageTrailer *trailer = reinterpret_cast<const U3VImageTrailer *>(ivars->trailerAddress[slot]);
    bool ok = !ivars->slotFailed[slot] &&
              ivars->leaderBytes[slot] >= sizeof(U3VImageLeader) && leader->magic == U3VSP_LEADER_MAGIC &&
              ivars->trailerBytes[slot] >= 20 && trailer->magic == U3VSP_TRAILER_MAGIC &&
              trailer->blockId == leader->blockId;

    if (ok) {
        U3VFrameInfo *info = &page->info[slot];
        info->blockId = leader->blockId;
        info->timestamp = leader->timestamp;
        info->pixelFormat = leader->pixelFormat;
        info->width = leader->sizeX;
        info->height = leader->sizeY;
        info->offsetX = leader->offsetX;
        info->offsetY = leader->offsetY;
        info->paddingX = leader->paddingX;
        info->payloadType = leader->payloadType;
        info->validPayloadSize = static_cast<uint32_t>(trailer->validPayloadSize);
        info->trailerStatus = trailer->status;

        uint64_t seq = ++ivars->sequence;
        ivars->readySequence[slot] = seq;
        U3VStoreState(page, slot, kU3VBufferReady);
        U3VStoreLatest(page, (seq << 8) | slot);
        page->framesCompleted++;
    } else {
        if (ivars->streaming) page->framesIncomplete++;
        U3VStoreState(page, slot, kU3VBufferFree);
    }

    Replenish();
}

void IMPL(U3VDriver, StreamComplete)
{
    // Each transfer has its own action whose reference holds slot * kSegmentsPerSlot + segment.
    uint32_t tag = *static_cast<const uint32_t *>(action->GetReference());
    IOLockLock(ivars->streamLock);
    if (ivars->streaming) {
        SegmentDone(tag / kSegmentsPerSlot, tag % kSegmentsPerSlot, status, actualByteCount);
    }
    IOLockUnlock(ivars->streamLock);
}
