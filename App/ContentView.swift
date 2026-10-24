//
//  ContentView.swift
//

import MetalKit
import SwiftUI

@main
struct U3VCameraApp: App {
    @StateObject private var camera = CameraController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(camera)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var camera: CameraController
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let renderer = camera.renderer {
                MetalFrameView(renderer: renderer)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showControls.toggle() } }
            } else {
                Text("Metal is unavailable on this device.").foregroundStyle(.secondary)
            }

            if camera.state != .streaming {
                StatusOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showControls {
                HStack(alignment: .top) {
                    StatsBadge()
                    Spacer()
                    ControlPanel()
                        .frame(width: 340)
                        .transition(.move(edge: .trailing))
                }
                .padding()
            }
        }
        .alert("Camera", isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.message ?? "")
        }
        .statusBarHidden(!showControls)
    }
}

struct MetalFrameView: UIViewRepresentable {
    let renderer: FrameRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = view.window?.screen.maximumFramesPerSecond ?? 120
        view.delegate = renderer
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}

private struct StatusOverlay: View {
    @EnvironmentObject private var camera: CameraController

    var body: some View {
        VStack(spacing: 12) {
            switch camera.state {
            case .waitingForCamera:
                Image(systemName: "cable.connector").font(.system(size: 48))
                Text("Connect the USB3 Vision camera").font(.title2)
                Text("If it's already connected, make sure this app's driver is turned on in Settings, then unplug the camera and plug it back in.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                VStack(alignment: .leading, spacing: 2) {
                    Text("USB devices seen by iPadOS").font(.caption.bold())
                    ForEach(camera.usbDevices, id: \.self) { Text($0) }
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(.top, 8)
            case .connecting:
                ProgressView()
                Text("Reading camera description…")
            case .ready:
                Image(systemName: "video").font(.system(size: 48))
                Text("\(camera.info.vendor) \(camera.info.model)").font(.title2)
                Button("Start", action: camera.toggleStreaming).buttonStyle(.borderedProminent)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 48))
                Text(reason).multilineTextAlignment(.center)
            case .streaming:
                EmptyView()
            }
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct StatsBadge: View {
    @EnvironmentObject private var camera: CameraController

    var body: some View {
        if camera.state == .streaming {
            let s = camera.frameStats
            let c = camera.counters
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.width)×\(s.height) \(s.pixelFormat)")
                Text(String(format: "camera %.1f fps · display %.1f fps", c.receivedFPS, s.displayedFPS))
                Text("frames \(c.completed) · incomplete \(c.incomplete) · skipped \(c.stolen) · usb errors \(c.transferErrors)")
            }
            .font(.caption.monospacedDigit())
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ControlPanel: View {
    @EnvironmentObject private var camera: CameraController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(camera.info.model.isEmpty ? "No camera" : camera.info.model).font(.headline)
                    if !camera.info.serial.isEmpty {
                        Text("S/N \(camera.info.serial) · \(camera.info.version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(camera.state == .streaming ? "Stop" : "Start", action: camera.toggleStreaming)
                    .buttonStyle(.borderedProminent)
                    .tint(camera.state == .streaming ? .red : .accentColor)
                    .disabled(camera.state != .ready && camera.state != .streaming)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(camera.features) { feature in
                        FeatureRow(feature: feature)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Display gamma %.2f", camera.gamma)).font(.subheadline)
                        Slider(value: $camera.gamma, in: 0.4...2.6)
                    }
                }
            }
            .frame(maxHeight: 560)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct FeatureRow: View {
    @EnvironmentObject private var camera: CameraController
    let feature: Feature
    @State private var draft: Double = 0

    var body: some View {
        switch feature.kind {
        case .command:
            Button(feature.displayName) { camera.set(feature, to: .none) }
        case .boolean:
            Toggle(feature.displayName, isOn: Binding(
                get: { feature.value == .flag(true) },
                set: { camera.set(feature, to: .flag($0)) }))
                .disabled(!feature.writable)
        case .enumeration(let options):
            HStack {
                Text(feature.displayName).font(.subheadline)
                Spacer()
                Picker(feature.displayName, selection: Binding(
                    get: { if case .text(let s) = feature.value { return s } else { return "" } },
                    set: { camera.set(feature, to: .text($0)) })) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!feature.writable)
            }
        case .string:
            LabeledContent(feature.displayName, value: { if case .text(let s) = feature.value { return s } else { return "" } }())
        case .float(let lo, let hi, let unit):
            numeric(range: lo.flatMap { l in hi.map { l...$0 } }, step: nil, unit: unit)
        case .integer(let lo, let hi, let inc):
            numeric(range: lo.flatMap { l in hi.map { Double(l)...Double($0) } }, step: Double(inc), unit: "")
        }
    }

    @ViewBuilder
    private func numeric(range: ClosedRange<Double>?, step: Double?, unit: String) -> some View {
        let current: Double = { if case .number(let v) = feature.value { return v } else { return 0 } }()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feature.displayName).font(.subheadline)
                Spacer()
                Text(format(draft) + (unit.isEmpty ? "" : " \(unit)")).font(.subheadline.monospacedDigit())
            }
            if let range, range.lowerBound < range.upperBound, feature.writable {
                if let step {
                    Slider(value: $draft, in: range, step: step) { editing in
                        if !editing { camera.set(feature, to: .number(draft)) }
                    }
                } else {
                    Slider(value: $draft, in: range) { editing in
                        if !editing { camera.set(feature, to: .number(draft)) }
                    }
                }
            }
        }
        .onAppear { draft = current }
        .onChange(of: current) { _, value in draft = value }
    }

    private func format(_ v: Double) -> String {
        if case .integer = feature.kind { return String(Int64(v)) }
        return abs(v) >= 1000 ? String(format: "%.0f", v) : String(format: "%.3g", v)
    }
}
