//
//  CameraController.swift
//

import Foundation
import SwiftUI

struct DeviceInfo {
    var vendor = ""
    var model = ""
    var version = ""
    var serial = ""
}

struct StreamCounters {
    var completed: UInt64 = 0
    var incomplete: UInt64 = 0
    var stolen: UInt64 = 0
    var transferErrors: UInt64 = 0
    var receivedFPS: Double = 0
}

@MainActor
final class CameraController: ObservableObject {
    enum State: Equatable {
        case waitingForCamera
        case connecting
        case ready
        case streaming
        case failed(String)
    }

    @Published private(set) var state: State = .waitingForCamera
    @Published private(set) var info = DeviceInfo()
    @Published private(set) var features: [Feature] = []
    @Published private(set) var counters = StreamCounters()
    @Published private(set) var frameStats = FrameStats()
    @Published var message: String?
    @Published var gamma: Double = 1 {
        didSet { renderer?.gamma = Float(gamma) }
    }

    let renderer = FrameRenderer()

    /// Features shown in the control panel, in this order, when the camera has them.
    private static let featureNames = [
        "ExposureAuto", "ExposureTime", "ExposureTimeAbs", "ExposureTimeRaw",
        "GainAuto", "Gain", "GainRaw", "BlackLevel",
        "BalanceWhiteAuto", "Gamma",
        "AcquisitionFrameRateEnable", "AcquisitionFrameRateControl", "AcquisitionFrameRate",
        "TriggerMode", "TriggerSource", "TriggerSoftware",
        "PixelFormat", "Width", "Height", "OffsetX", "OffsetY",
        "BinningHorizontal", "BinningVertical", "ReverseX", "ReverseY",
        "DeviceTemperature",
    ]

    private let watcher = DriverWatcher()
    private let io = WorkerThread()
    private var connection: DriverConnection?
    private var genicam: GenICamDevice?
    private var statsTimer: Timer?
    private var lastCompleted: UInt64 = 0
    private var lastStatsTime = Date()

    init() {
        watcher.onArrival = { [weak self] service in
            IOObjectRetain(service)
            Task { @MainActor in self?.connect(service) }
        }
        watcher.onRemoval = { [weak self] in
            Task { @MainActor in self?.disconnected() }
        }
        watcher.start()
        refreshUSBDevices()
        inventoryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUSBDevices() }
        }
    }

    // MARK: Diagnostics

    @Published private(set) var usbDevices: [String] = []
    @Published private(set) var driverStatus: String?

    private static let stageNames: [UInt32: String] = [
        UInt32(kU3VStageBuffers): "allocating buffers",
        UInt32(kU3VStageActions): "creating completions",
        UInt32(kU3VStageOpenControl): "opening control interface",
        UInt32(kU3VStageControlPipes): "finding control endpoints",
        UInt32(kU3VStageFindStream): "finding streaming interface",
        UInt32(kU3VStageOpenStream): "opening streaming interface",
        UInt32(kU3VStageStreamPipe): "finding streaming endpoint",
        UInt32(kU3VStageBootstrap): "reading bootstrap registers",
        UInt32(kU3VStageReady): "ready",
    ]

    /// Waits for the driver's Start() to finish (it registers before configuring the camera).
    private nonisolated static func driverStartResult(_ connection: DriverConnection) throws -> (UInt32, Int32) {
        let control = try connection.mapControlPage()
        let page = control.pointer.assumingMemoryBound(to: U3VControlPage.self)
        for _ in 0..<100 {
            let stage = U3VLoadStartStage(page)
            if stage == UInt32(kU3VStageReady) || page.pointee.startError != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return (U3VLoadStartStage(page), page.pointee.startError)
    }
    private var inventoryTimer: Timer?

    private func refreshUSBDevices() {
        guard state != .streaming else { return }
        var lines = USBInventory.snapshot()
        if let driverStatus { lines.append("driver: \(driverStatus)") }
        if lines != usbDevices {
            usbDevices = lines
            USBInventory.write(lines)
        }
    }

    /// Runs blocking driver calls off the main thread, one at a time.
    private func background<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            io.enqueue {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    // MARK: Connection

    private func connect(_ service: io_service_t) {
        defer { IOObjectRelease(service) }
        guard connection == nil else { return }
        state = .connecting
        do {
            let connection = try DriverConnection(service: service)
            self.connection = connection
            Task { await load(connection) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func load(_ connection: DriverConnection) async {
        do {
            let (stage, error) = try await background { try Self.driverStartResult(connection) }
            let stageName = Self.stageNames[stage] ?? "stage \(stage)"
            if stage != UInt32(kU3VStageReady) {
                driverStatus = String(format: "setup failed while %@ (0x%08x)", stageName, UInt32(bitPattern: error))
                refreshUSBDevices()
                state = .failed("Driver couldn't set up the camera: \(driverStatus!)")
                return
            }
            driverStatus = "ready"
            refreshUSBDevices()
            let (info, device) = try await background { () -> (DeviceInfo, GenICamDevice?) in
                var info = DeviceInfo()
                info.vendor = try connection.readString(at: 0x0004)
                info.model = try connection.readString(at: 0x0044)
                info.version = try connection.readString(at: 0x00C4)
                info.serial = try connection.readString(at: 0x0144)
                let device = try? GenICamDevice(port: connection, xml: GenICamDevice.loadDescription(from: connection))
                return (info, device)
            }
            self.info = info
            self.genicam = device
            if device == nil {
                message = "Couldn't read the camera's GenICam description; only streaming is available."
            }
            await refreshFeatures()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func disconnected() {
        driverStatus = nil
        statsTimer?.invalidate()
        renderer?.detach()
        connection = nil
        genicam = nil
        features = []
        state = .waitingForCamera
    }

    // MARK: Features

    func refreshFeatures() async {
        guard let genicam else { return }
        features = (try? await background {
            Self.featureNames.compactMap { genicam.feature($0) }
        }) ?? []
    }

    func set(_ feature: Feature, to value: FeatureValue) {
        guard let genicam else { return }
        Task {
            do {
                try await background {
                    switch (feature.kind, value) {
                    case (.enumeration, .text(let symbol)): try genicam.setEnum(feature.name, symbol: symbol)
                    case (.boolean, .flag(let on)): try genicam.setInt(feature.name, on ? 1 : 0)
                    case (.integer, .number(let v)): try genicam.setInt(feature.name, Int64(v.rounded()))
                    case (.float, .number(let v)): try genicam.setFloat(feature.name, v)
                    case (.command, _): try genicam.execute(feature.name)
                    default: break
                    }
                }
            } catch {
                message = "\(feature.displayName): \(error.localizedDescription)"
            }
            await refreshFeatures()
        }
    }

    // MARK: Acquisition

    func toggleStreaming() {
        if state == .streaming {
            Task { await stop() }
        } else if state == .ready {
            Task { await start() }
        }
    }

    private func start() async {
        guard let connection, let renderer else { return }
        let genicam = self.genicam
        do {
            let (control, frames) = try await background { () -> (SharedMapping, [SharedMapping]) in
                if genicam?.has("TLParamsLocked") == true { try? genicam?.setInt("TLParamsLocked", 1) }
                let layout = try connection.startStream(bufferCount: Int(U3V_MAX_FRAME_BUFFERS))
                let control = try connection.mapControlPage()
                let frames = try (0..<layout.bufferCount).map { try connection.mapFrameBuffer($0) }
                return (control, frames)
            }
            try renderer.attach(control: control, frames: frames)
            renderer.gamma = Float(gamma)
            try await background {
                if let genicam, genicam.has("AcquisitionStart") { try genicam.execute("AcquisitionStart") }
            }
            state = .streaming
            startStatsTimer()
        } catch {
            message = error.localizedDescription
            await stop()
        }
    }

    private func stop() async {
        guard let connection else { return }
        let genicam = self.genicam
        statsTimer?.invalidate()
        _ = try? await background {
            if let genicam, genicam.has("AcquisitionStop") { try? genicam.execute("AcquisitionStop") }
            try connection.stopStream()
            if genicam?.has("TLParamsLocked") == true { try? genicam?.setInt("TLParamsLocked", 0) }
        }
        renderer?.detach()
        if self.connection != nil { state = .ready }
        await refreshFeatures()
    }

    private func startStatsTimer() {
        lastCompleted = 0
        lastStatsTime = Date()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCounters() }
        }
    }

    private func updateCounters() {
        guard let renderer, let page = renderer.controlPage else { return }
        var c = StreamCounters()
        c.completed = U3VLoadCounter(&page.pointee.framesCompleted)
        c.incomplete = U3VLoadCounter(&page.pointee.framesIncomplete)
        c.stolen = U3VLoadCounter(&page.pointee.framesStolen)
        c.transferErrors = U3VLoadCounter(&page.pointee.transferErrors)
        let now = Date()
        c.receivedFPS = Double(c.completed &- lastCompleted) / now.timeIntervalSince(lastStatsTime)
        lastCompleted = c.completed
        lastStatsTime = now
        counters = c
        frameStats = renderer.stats
    }
}

/// Serial worker for blocking driver and GenICam calls. A dedicated thread so it gets a large
/// stack: GenICam formulas and node chains recurse, and GCD threads only have 512 KB.
final class WorkerThread: Thread {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []

    override init() {
        super.init()
        name = "u3v.control"
        stackSize = 16 << 20
        qualityOfService = .userInitiated
        start()
    }

    func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    override func main() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}
