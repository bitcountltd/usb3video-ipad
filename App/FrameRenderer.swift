//
//  FrameRenderer.swift
//  Display-driven, zero-copy presentation.
//
//  Every vsync the renderer peeks at the driver's `latest` word in shared memory. If a new
//  frame is there it claims the buffer (Ready -> Held), draws straight from the mapped USB
//  buffer wrapped as an MTLBuffer, and hands the buffer back (Held -> Free) when the GPU is done.
//  No syscalls, no copies, no per-frame allocations.
//

import Metal
import MetalKit
import QuartzCore

struct FrameParams {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var stride: UInt32 = 0
    var kind: UInt32 = 0
    var bytesPerSample: UInt32 = 1
    var redX: UInt32 = 0
    var redY: UInt32 = 0
    var scale: Float = 1.0 / 255.0
    var quadScale: SIMD2<Float> = .one
    var gamma: Float = 1
    var pad: Float = 0
}

struct PixelLayout {
    enum Kind: UInt32 { case mono = 0, bayer = 1, rgb = 2, bgr = 3 }
    let kind: Kind
    let bytesPerSample: Int
    let bitsUsed: Int
    let redX: UInt32
    let redY: UInt32
    let name: String

    /// PFNC pixel format codes (unpacked formats only).
    init?(pfnc: UInt32) {
        func bayer(_ name: String, _ rx: UInt32, _ ry: UInt32, _ bytes: Int, _ bits: Int) -> PixelLayout {
            PixelLayout(kind: .bayer, bytesPerSample: bytes, bitsUsed: bits, redX: rx, redY: ry, name: name)
        }
        switch pfnc {
        case 0x0108_0001: self = PixelLayout(kind: .mono, bytesPerSample: 1, bitsUsed: 8, redX: 0, redY: 0, name: "Mono8")
        case 0x0110_0003: self = PixelLayout(kind: .mono, bytesPerSample: 2, bitsUsed: 10, redX: 0, redY: 0, name: "Mono10")
        case 0x0110_0005: self = PixelLayout(kind: .mono, bytesPerSample: 2, bitsUsed: 12, redX: 0, redY: 0, name: "Mono12")
        case 0x0110_0007: self = PixelLayout(kind: .mono, bytesPerSample: 2, bitsUsed: 16, redX: 0, redY: 0, name: "Mono16")
        case 0x0108_0008: self = bayer("BayerGR8", 1, 0, 1, 8)
        case 0x0108_0009: self = bayer("BayerRG8", 0, 0, 1, 8)
        case 0x0108_000A: self = bayer("BayerGB8", 0, 1, 1, 8)
        case 0x0108_000B: self = bayer("BayerBG8", 1, 1, 1, 8)
        case 0x0110_000C: self = bayer("BayerGR10", 1, 0, 2, 10)
        case 0x0110_000D: self = bayer("BayerRG10", 0, 0, 2, 10)
        case 0x0110_000E: self = bayer("BayerGB10", 0, 1, 2, 10)
        case 0x0110_000F: self = bayer("BayerBG10", 1, 1, 2, 10)
        case 0x0110_0010: self = bayer("BayerGR12", 1, 0, 2, 12)
        case 0x0110_0011: self = bayer("BayerRG12", 0, 0, 2, 12)
        case 0x0110_0012: self = bayer("BayerGB12", 0, 1, 2, 12)
        case 0x0110_0013: self = bayer("BayerBG12", 1, 1, 2, 12)
        case 0x0110_002E: self = bayer("BayerGR16", 1, 0, 2, 16)
        case 0x0110_002F: self = bayer("BayerRG16", 0, 0, 2, 16)
        case 0x0110_0030: self = bayer("BayerGB16", 0, 1, 2, 16)
        case 0x0110_0031: self = bayer("BayerBG16", 1, 1, 2, 16)
        case 0x0218_0014: self = PixelLayout(kind: .rgb, bytesPerSample: 3, bitsUsed: 8, redX: 0, redY: 0, name: "RGB8")
        case 0x0218_0015: self = PixelLayout(kind: .bgr, bytesPerSample: 3, bitsUsed: 8, redX: 0, redY: 0, name: "BGR8")
        default: return nil
        }
    }

    private init(kind: Kind, bytesPerSample: Int, bitsUsed: Int, redX: UInt32, redY: UInt32, name: String) {
        self.kind = kind
        self.bytesPerSample = bytesPerSample
        self.bitsUsed = bitsUsed
        self.redX = redX
        self.redY = redY
        self.name = name
    }
}

struct FrameStats {
    var displayedFPS: Double = 0
    var width: Int = 0
    var height: Int = 0
    var pixelFormat: String = ""
}

final class FrameRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private var control: SharedMapping?
    private var frames: [SharedMapping] = []
    private var buffers: [MTLBuffer] = []
    private var page: UnsafeMutablePointer<U3VControlPage>?
    private var lastSequence: UInt64 = 0
    private let inFlight = DispatchGroup()

    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsCount = 0
    private(set) var stats = FrameStats()
    var gamma: Float = 1
    var controlPage: UnsafeMutablePointer<U3VControlPage>? { page }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "frame_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "frame_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    /// Wrap the driver's frame buffers as GPU buffers. The memory is not copied.
    func attach(control: SharedMapping, frames: [SharedMapping]) throws {
        detach()
        var wrapped: [MTLBuffer] = []
        for frame in frames {
            guard let buffer = device.makeBuffer(bytesNoCopy: frame.pointer, length: frame.length,
                                                 options: .storageModeShared,
                                                 deallocator: nil) else {
                throw DriverError(operation: "Wrap frame buffer for Metal", code: ioReturnNoMemory)
            }
            wrapped.append(buffer)
        }
        self.control = control
        self.frames = frames
        self.buffers = wrapped
        self.page = control.pointer.assumingMemoryBound(to: U3VControlPage.self)
        lastSequence = 0
    }

    /// Waits for the GPU to finish with every buffer before the mappings go away.
    func detach() {
        inFlight.wait()
        page = nil
        buffers = []
        frames = []
        control = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let page else { return }
        let latest = U3VLoadLatest(page)
        let sequence = latest >> 8
        guard latest != 0, sequence != lastSequence else { return }
        let index = Int(latest & 0xFF)
        guard index < buffers.count,
              U3VCompareExchangeState(page, UInt32(index), UInt32(kU3VBufferReady), UInt32(kU3VBufferHeld)) else {
            return   // the driver reclaimed it; a newer frame is already on its way
        }
        lastSequence = sequence

        let info = frameInfo(page, index)
        guard let layout = PixelLayout(pfnc: info.pixelFormat), info.width > 0, info.height > 0,
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            U3VStoreState(page, UInt32(index), UInt32(kU3VBufferFree))
            return
        }

        var params = FrameParams()
        params.width = info.width
        params.height = info.height
        params.stride = info.width * UInt32(layout.bytesPerSample) + info.paddingX
        params.kind = layout.kind.rawValue
        params.bytesPerSample = UInt32(layout.kind == .rgb || layout.kind == .bgr ? 1 : layout.bytesPerSample)
        params.redX = layout.redX
        params.redY = layout.redY
        params.scale = 1 / Float((1 << layout.bitsUsed) - 1)
        params.gamma = 1 / max(gamma, 0.1)
        let viewAspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let imageAspect = Float(info.width) / Float(info.height)
        params.quadScale = imageAspect > viewAspect ? SIMD2(1, viewAspect / imageAspect)
                                                    : SIMD2(imageAspect / viewAspect, 1)

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&params, length: MemoryLayout<FrameParams>.stride, index: 0)
        encoder.setFragmentBuffer(buffers[index], offset: 0, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<FrameParams>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        inFlight.enter()
        let pagePointer = page
        commands.addCompletedHandler { [inFlight] _ in
            U3VStoreState(pagePointer, UInt32(index), UInt32(kU3VBufferFree))
            inFlight.leave()
        }
        commands.present(drawable)
        commands.commit()

        updateStats(info, layout)
    }

    private func frameInfo(_ page: UnsafeMutablePointer<U3VControlPage>, _ index: Int) -> U3VFrameInfo {
        let offset = MemoryLayout<U3VControlPage>.offset(of: \U3VControlPage.info)!
        return (UnsafeRawPointer(page) + offset).assumingMemoryBound(to: U3VFrameInfo.self)[index]
    }

    private func updateStats(_ info: U3VFrameInfo, _ layout: PixelLayout) {
        fpsCount += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1 {
            stats.displayedFPS = Double(fpsCount) / (now - fpsWindowStart)
            fpsCount = 0
            fpsWindowStart = now
        }
        stats.width = Int(info.width)
        stats.height = Int(info.height)
        stats.pixelFormat = layout.name
    }
}
