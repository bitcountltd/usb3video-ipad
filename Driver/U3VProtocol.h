//
//  U3VProtocol.h
//  USB3 Vision 1.0 wire formats and bootstrap register offsets (driver side only).
//

#ifndef U3VProtocol_h
#define U3VProtocol_h

#include <stdint.h>

/* USB class codes */
#define U3V_INTERFACE_CLASS        0xEF
#define U3V_INTERFACE_SUBCLASS     0x05
#define U3V_PROTOCOL_CONTROL       0x00
#define U3V_PROTOCOL_EVENT         0x01
#define U3V_PROTOCOL_STREAM        0x02

/* U3VCP (control channel) */
#define U3VCP_MAGIC                0x43563355u   /* 'U3VC' */
#define U3VCP_FLAG_REQUEST_ACK     0x4000
#define U3VCP_READMEM_CMD          0x0800
#define U3VCP_READMEM_ACK          0x0801
#define U3VCP_WRITEMEM_CMD         0x0802
#define U3VCP_WRITEMEM_ACK         0x0803
#define U3VCP_PENDING_ACK          0x0805

/* Stream channel */
#define U3VSP_LEADER_MAGIC         0x4C563355u   /* 'U3VL' */
#define U3VSP_TRAILER_MAGIC        0x54563355u   /* 'U3VT' */

/* ABRM */
#define ABRM_MAX_DEVICE_RESPONSE_TIME 0x01CC
#define ABRM_SBRM_ADDRESS             0x01D8

/* SBRM */
#define SBRM_MAX_CMD_TRANSFER      0x0014
#define SBRM_MAX_ACK_TRANSFER      0x0018
#define SBRM_SIRM_ADDRESS          0x0020

/* SIRM */
#define SIRM_INFO                  0x0000
#define SIRM_CONTROL               0x0004
#define SIRM_REQ_PAYLOAD_SIZE      0x0008
#define SIRM_REQ_LEADER_SIZE       0x0010
#define SIRM_REQ_TRAILER_SIZE      0x0014
#define SIRM_MAX_LEADER_SIZE       0x0018
#define SIRM_PAYLOAD_SIZE          0x001C
#define SIRM_PAYLOAD_COUNT         0x0020
#define SIRM_TRANSFER1_SIZE        0x0024
#define SIRM_TRANSFER2_SIZE        0x0028
#define SIRM_MAX_TRAILER_SIZE      0x002C
#define SIRM_INFO_ALIGNMENT_SHIFT  24
#define SIRM_CONTROL_STREAM_ENABLE 0x1

#pragma pack(push, 1)

typedef struct {
    uint32_t magic;
    uint16_t flagsOrStatus;
    uint16_t command;
    uint16_t length;      /* bytes following this header */
    uint16_t requestId;
} U3VCPHeader;

typedef struct {
    U3VCPHeader header;
    uint64_t address;
    uint16_t reserved;
    uint16_t readLength;
} U3VCPReadMemCmd;

typedef struct {
    U3VCPHeader header;
    uint64_t address;
    /* data follows */
} U3VCPWriteMemCmd;

typedef struct {
    U3VCPHeader header;
    uint16_t reserved;
    uint16_t timeoutMs;
} U3VCPPendingAck;

typedef struct {
    uint32_t magic;
    uint16_t reserved0;
    uint16_t leaderSize;
    uint64_t blockId;
    uint16_t reserved1;
    uint16_t payloadType;
    uint64_t timestamp;
    uint32_t pixelFormat;
    uint32_t sizeX;
    uint32_t sizeY;
    uint32_t offsetX;
    uint32_t offsetY;
    uint16_t paddingX;
    uint16_t reserved2;
} U3VImageLeader;

typedef struct {
    uint32_t magic;
    uint16_t reserved0;
    uint16_t trailerSize;
    uint64_t blockId;
    uint16_t status;
    uint16_t reserved1;
    uint64_t validPayloadSize;
    uint32_t sizeY;
} U3VImageTrailer;

#pragma pack(pop)

#endif /* U3VProtocol_h */
