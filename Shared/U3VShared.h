//
//  U3VShared.h
//  Shared between the DriverKit extension and the iPad app.
//
//  The driver exposes:
//    memory type 0            -> U3VControlPage (one 16 KB page, read/write in both processes)
//    memory type 1 + i        -> frame buffer i (payload at offset 0, page aligned, GPU readable)
//
//  Frame hand-off is lock free and syscall free on the app side: the driver publishes
//  `latest = (sequence << 8) | index` after a frame lands, the app's display loop reads it once
//  per vsync and claims the buffer with a compare-and-swap. Nothing is ever copied.
//

#ifndef U3VShared_h
#define U3VShared_h

#include <stdint.h>
#include <stdbool.h>

#define U3V_CONTROL_PAGE_MAGIC   0x55335650u   /* 'U3VP' */
#define U3V_CONTROL_PAGE_VERSION 1u
#define U3V_CONTROL_PAGE_SIZE    16384u
#define U3V_MAX_FRAME_BUFFERS    8u

/* External method selectors. */
enum {
    kU3VMethodGetDeviceInfo = 0,   /* scalar out: [maxCmd, maxAck, sirmAddress, responseTimeMs] */
    kU3VMethodReadMemory    = 1,   /* scalar in: [address, length<=4096]; struct out: bytes      */
    kU3VMethodWriteMemory   = 2,   /* scalar in: [address]; struct in: bytes (<=4096)            */
    kU3VMethodStartStream   = 3,   /* scalar in: [bufferCount]; scalar out: [count, bufferSize, payloadSize] */
    kU3VMethodStopStream    = 4,
    kU3VMethodCount
};

#define U3V_MAX_MEMORY_IO 4096u

enum {
    kU3VMemoryTypeControlPage = 0,
    kU3VMemoryTypeFrameBase   = 1,
};

/* Buffer ownership. Only these transitions are legal:
 *   driver: Free -> Queued -> Ready,  Ready -> Queued (steal an unclaimed frame when starved)
 *   app:    Ready -> Held (CAS),      Held -> Free (after the GPU is done reading)          */
enum {
    kU3VBufferFree   = 0,
    kU3VBufferQueued = 1,
    kU3VBufferReady  = 2,
    kU3VBufferHeld   = 3,
};

typedef struct {
    uint64_t blockId;
    uint64_t timestamp;          /* device ticks */
    uint32_t pixelFormat;        /* PFNC code */
    uint32_t width;
    uint32_t height;
    uint32_t offsetX;
    uint32_t offsetY;
    uint32_t paddingX;           /* bytes at the end of every line */
    uint32_t payloadType;
    uint32_t validPayloadSize;
    uint32_t trailerStatus;
    uint32_t reserved;
} U3VFrameInfo;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t bufferCount;
    uint32_t bufferSize;         /* bytes mapped per frame buffer (multiple of 16 KB) */
    uint32_t payloadCapacity;    /* bytes of image payload space at offset 0 */
    uint32_t streaming;
    uint64_t latest;             /* (sequence << 8) | index; 0 = nothing yet */
    uint32_t state[U3V_MAX_FRAME_BUFFERS];
    U3VFrameInfo info[U3V_MAX_FRAME_BUFFERS];
    uint64_t framesCompleted;
    uint64_t framesIncomplete;
    uint64_t framesStolen;       /* published frames reclaimed before the app looked at them */
    uint64_t transferErrors;
    int32_t  lastError;
    uint32_t startStage;         /* last U3VStartStage reached by the driver's Start() */
    int32_t  startError;         /* IOReturn of the failing stage, 0 when ready */
    uint32_t reserved;
} U3VControlPage;

/* Driver startup progress, so failures are visible without a log (the camera occupies
 * the iPad's only port, so the device log can't be collected over USB). */
enum {
    kU3VStageBuffers          = 1,
    kU3VStageActions          = 2,
    kU3VStageOpenControl      = 3,
    kU3VStageControlPipes     = 4,
    kU3VStageFindStream       = 5,
    kU3VStageOpenStream       = 6,
    kU3VStageStreamPipe       = 7,
    kU3VStageBootstrap        = 8,
    kU3VStageReady            = 100,
};

_Static_assert(sizeof(U3VControlPage) <= U3V_CONTROL_PAGE_SIZE, "control page too large");

/* Cross-process atomics on the shared page (same physical memory in both address spaces). */

static inline uint64_t U3VLoadLatest(const U3VControlPage *page) {
    return __atomic_load_n(&page->latest, __ATOMIC_ACQUIRE);
}

static inline void U3VStoreLatest(U3VControlPage *page, uint64_t value) {
    __atomic_store_n(&page->latest, value, __ATOMIC_RELEASE);
}

static inline uint32_t U3VLoadState(const U3VControlPage *page, uint32_t index) {
    return __atomic_load_n(&page->state[index], __ATOMIC_ACQUIRE);
}

static inline void U3VStoreState(U3VControlPage *page, uint32_t index, uint32_t value) {
    __atomic_store_n(&page->state[index], value, __ATOMIC_RELEASE);
}

static inline bool U3VCompareExchangeState(U3VControlPage *page, uint32_t index,
                                           uint32_t expected, uint32_t desired) {
    return __atomic_compare_exchange_n(&page->state[index], &expected, desired, false,
                                       __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

static inline uint32_t U3VLoadStartStage(const U3VControlPage *page) {
    return __atomic_load_n(&page->startStage, __ATOMIC_ACQUIRE);
}

static inline uint64_t U3VLoadCounter(const uint64_t *counter) {
    return __atomic_load_n(counter, __ATOMIC_RELAXED);
}

#endif /* U3VShared_h */
