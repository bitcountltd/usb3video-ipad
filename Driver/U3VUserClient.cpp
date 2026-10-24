//
//  U3VUserClient.cpp
//

#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/OSData.h>

#include "U3VUserClient.h"
#include "U3VDriver.h"
#include "U3VShared.h"

struct U3VUserClient_IVars {
    U3VDriver *driver;
    bool startedStream;
};

bool U3VUserClient::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(U3VUserClient_IVars, 1);
    return ivars != nullptr;
}

void U3VUserClient::free()
{
    if (ivars != nullptr) {
        OSSafeReleaseNULL(ivars->driver);
    }
    IOSafeDeleteNULL(ivars, U3VUserClient_IVars, 1);
    super::free();
}

kern_return_t IMPL(U3VUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    ivars->driver = OSDynamicCast(U3VDriver, provider);
    if (ivars->driver == nullptr) {
        Stop(provider, SUPERDISPATCH);
        return kIOReturnNoDevice;
    }
    ivars->driver->retain();
    return kIOReturnSuccess;
}

kern_return_t IMPL(U3VUserClient, Stop)
{
    // App went away (or crashed) mid-stream: don't leave the camera streaming into nothing.
    if (ivars->driver && ivars->startedStream) {
        ivars->driver->StopStream();
    }
    return Stop(provider, SUPERDISPATCH);
}

static kern_return_t GetDeviceInfo(OSObject *target, void *, IOUserClientMethodArguments *args)
{
    U3VUserClient_IVars *ivars = static_cast<U3VUserClient *>(target)->ivars;
    ivars->driver->GetDeviceInfo(&args->scalarOutput[0], &args->scalarOutput[1],
                                 &args->scalarOutput[2], &args->scalarOutput[3]);
    return kIOReturnSuccess;
}

static kern_return_t ReadMemory(OSObject *target, void *, IOUserClientMethodArguments *args)
{
    U3VUserClient_IVars *ivars = static_cast<U3VUserClient *>(target)->ivars;
    uint64_t address = args->scalarInput[0];
    uint64_t length = args->scalarInput[1];
    if (length == 0 || length > U3V_MAX_MEMORY_IO || length > args->structureOutputMaximumSize) {
        return kIOReturnBadArgument;
    }
    uint8_t buffer[U3V_MAX_MEMORY_IO];
    kern_return_t ret = ivars->driver->ReadMemory(address, buffer, static_cast<uint32_t>(length));
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    args->structureOutput = OSData::withBytes(buffer, length);
    return args->structureOutput ? kIOReturnSuccess : kIOReturnNoMemory;
}

static kern_return_t WriteMemory(OSObject *target, void *, IOUserClientMethodArguments *args)
{
    U3VUserClient_IVars *ivars = static_cast<U3VUserClient *>(target)->ivars;
    OSData *data = args->structureInput;
    if (data == nullptr || data->getLength() == 0 || data->getLength() > U3V_MAX_MEMORY_IO) {
        return kIOReturnBadArgument;
    }
    return ivars->driver->WriteMemory(args->scalarInput[0], data->getBytesNoCopy(),
                                      static_cast<uint32_t>(data->getLength()));
}

static kern_return_t StartStream(OSObject *target, void *, IOUserClientMethodArguments *args)
{
    U3VUserClient_IVars *ivars = static_cast<U3VUserClient *>(target)->ivars;
    kern_return_t ret = ivars->driver->StartStream(static_cast<uint32_t>(args->scalarInput[0]),
                                                   &args->scalarOutput[0], &args->scalarOutput[1],
                                                   &args->scalarOutput[2]);
    if (ret == kIOReturnSuccess) {
        ivars->startedStream = true;
    }
    return ret;
}

static kern_return_t StopStream(OSObject *target, void *, IOUserClientMethodArguments *)
{
    U3VUserClient_IVars *ivars = static_cast<U3VUserClient *>(target)->ivars;
    ivars->startedStream = false;
    return ivars->driver->StopStream();
}

static const IOUserClientMethodDispatch sMethods[kU3VMethodCount] = {
    { // kU3VMethodGetDeviceInfo
        .function = &GetDeviceInfo,
        .checkCompletionExists = false,
        .checkScalarInputCount = 0,
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 4,
        .checkStructureOutputSize = 0,
    },
    { // kU3VMethodReadMemory
        .function = &ReadMemory,
        .checkCompletionExists = false,
        .checkScalarInputCount = 2,
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = kIOUserClientVariableStructureSize,
    },
    { // kU3VMethodWriteMemory
        .function = &WriteMemory,
        .checkCompletionExists = false,
        .checkScalarInputCount = 1,
        .checkStructureInputSize = kIOUserClientVariableStructureSize,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
    { // kU3VMethodStartStream
        .function = &StartStream,
        .checkCompletionExists = false,
        .checkScalarInputCount = 1,
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 3,
        .checkStructureOutputSize = 0,
    },
    { // kU3VMethodStopStream
        .function = &StopStream,
        .checkCompletionExists = false,
        .checkScalarInputCount = 0,
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
};

kern_return_t U3VUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments *arguments,
                                            const IOUserClientMethodDispatch *, OSObject *, void *)
{
    if (selector >= kU3VMethodCount) {
        return kIOReturnUnsupported;
    }
    return super::ExternalMethod(selector, arguments, &sMethods[selector], this, nullptr);
}

kern_return_t IMPL(U3VUserClient, CopyClientMemoryForType)
{
    kern_return_t ret = ivars->driver->CopyClientMemory(type, memory);
    if (ret == kIOReturnSuccess && options) {
        *options = 0;   // read/write: the app flips buffer ownership flags in the control page
    }
    return ret;
}
