//
//  DriverConnection.swift
//  Thin IOKit wrapper around the U3VDriver user client.
//

import Foundation

/// kIOReturnNoMemory (the IOKit macro isn't importable into Swift).
let ioReturnNoMemory = kern_return_t(bitPattern: 0xE000_02BD)

struct DriverError: LocalizedError {
    let operation: String
    let code: kern_return_t

    var errorDescription: String? {
        String(format: "%@ failed (0x%08x)", operation, UInt32(bitPattern: code))
    }
}

private func check(_ code: kern_return_t, _ operation: String) throws {
    if code != KERN_SUCCESS {
        throw DriverError(operation: operation, code: code)
    }
}

/// Watches for the driver's service to appear and disappear (camera plugged / unplugged).
final class DriverWatcher {
    var onArrival: ((io_service_t) -> Void)?
    var onRemoval: (() -> Void)?

    private var port: IONotificationPortRef?
    private var arrivalIterator: io_iterator_t = 0
    private var removalIterator: io_iterator_t = 0

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceNameMatching("U3VDriver"),
                                         { refcon, iterator in
            let watcher = Unmanaged<DriverWatcher>.fromOpaque(refcon!).takeUnretainedValue()
            watcher.drain(iterator, arrived: true)
        }, refcon, &arrivalIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceNameMatching("U3VDriver"),
                                         { refcon, iterator in
            let watcher = Unmanaged<DriverWatcher>.fromOpaque(refcon!).takeUnretainedValue()
            watcher.drain(iterator, arrived: false)
        }, refcon, &removalIterator)

        // Arm both notifications and pick up a camera that is already attached.
        drain(arrivalIterator, arrived: true)
        drain(removalIterator, arrived: false)
    }

    private func drain(_ iterator: io_iterator_t, arrived: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            if arrived {
                onArrival?(service)
            } else {
                onRemoval?()
            }
            IOObjectRelease(service)
        }
    }

    deinit {
        if arrivalIterator != 0 { IOObjectRelease(arrivalIterator) }
        if removalIterator != 0 { IOObjectRelease(removalIterator) }
        if let port { IONotificationPortDestroy(port) }
    }
}

/// A mapping of driver memory into this process. Unmapped on deinit.
final class SharedMapping {
    let pointer: UnsafeMutableRawPointer
    let length: Int
    private let connection: io_connect_t
    private let type: UInt32

    fileprivate init(connection: io_connect_t, type: UInt32) throws {
        var address: mach_vm_address_t = 0
        var size: mach_vm_size_t = 0
        try check(IOConnectMapMemory64(connection, type, mach_task_self_, &address, &size, IOOptionBits(kIOMapAnywhere)),
                  "Map memory \(type)")
        guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(address)) else {
            throw DriverError(operation: "Map memory \(type)", code: ioReturnNoMemory)
        }
        self.pointer = pointer
        self.length = Int(size)
        self.connection = connection
        self.type = type
    }

    deinit {
        IOConnectUnmapMemory64(connection, type, mach_task_self_, mach_vm_address_t(UInt(bitPattern: pointer)))
    }
}

struct StreamLayout {
    let bufferCount: Int
    let bufferSize: Int
    let payloadSize: Int
}

/// Register access and stream control. Calls block; use from a background queue.
final class DriverConnection {
    private let connection: io_connect_t

    init(service: io_service_t) throws {
        var connection: io_connect_t = 0
        try check(IOServiceOpen(service, mach_task_self_, 0, &connection), "Open driver")
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    func readMemory(address: UInt64, length: Int) throws -> Data {
        var result = Data(capacity: length)
        var offset = 0
        var chunk = [UInt8](repeating: 0, count: Int(U3V_MAX_MEMORY_IO))
        while offset < length {
            let count = min(Int(U3V_MAX_MEMORY_IO), length - offset)
            var input: [UInt64] = [address + UInt64(offset), UInt64(count)]
            var outSize = count
            try check(IOConnectCallMethod(connection, UInt32(kU3VMethodReadMemory), &input, 2, nil, 0,
                                          nil, nil, &chunk, &outSize),
                      String(format: "Read 0x%llx", address + UInt64(offset)))
            result.append(contentsOf: chunk[0..<outSize])
            offset += count
        }
        return result
    }

    func writeMemory(address: UInt64, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = min(Int(U3V_MAX_MEMORY_IO), data.count - offset)
            var input: [UInt64] = [address + UInt64(offset)]
            try data[data.startIndex + offset ..< data.startIndex + offset + count].withUnsafeBytes { bytes in
                try check(IOConnectCallMethod(connection, UInt32(kU3VMethodWriteMemory), &input, 1,
                                              bytes.baseAddress, count, nil, nil, nil, nil),
                          String(format: "Write 0x%llx", address + UInt64(offset)))
            }
            offset += count
        }
    }

    func read<T: FixedWidthInteger>(_ type: T.Type = T.self, at address: UInt64) throws -> T {
        let data = try readMemory(address: address, length: MemoryLayout<T>.size)
        return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }

    func readString(at address: UInt64, length: Int = 64) throws -> String {
        let data = try readMemory(address: address, length: length)
        let bytes = data.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    func startStream(bufferCount: Int) throws -> StreamLayout {
        var input: [UInt64] = [UInt64(bufferCount)]
        var output = [UInt64](repeating: 0, count: 3)
        var outputCount: UInt32 = 3
        try check(IOConnectCallMethod(connection, UInt32(kU3VMethodStartStream), &input, 1, nil, 0,
                                      &output, &outputCount, nil, nil), "Start stream")
        return StreamLayout(bufferCount: Int(output[0]), bufferSize: Int(output[1]), payloadSize: Int(output[2]))
    }

    func stopStream() throws {
        try check(IOConnectCallMethod(connection, UInt32(kU3VMethodStopStream), nil, 0, nil, 0,
                                      nil, nil, nil, nil), "Stop stream")
    }

    func mapControlPage() throws -> SharedMapping {
        try SharedMapping(connection: connection, type: UInt32(kU3VMemoryTypeControlPage))
    }

    func mapFrameBuffer(_ index: Int) throws -> SharedMapping {
        try SharedMapping(connection: connection, type: UInt32(kU3VMemoryTypeFrameBase) + UInt32(index))
    }
}
