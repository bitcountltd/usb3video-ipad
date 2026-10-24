# U3V Camera for iPad

An iPad app that drives a USB3 Vision industrial camera (written for the Toshiba Teli BU505MCF)
connected to the iPad's USB‑C port. It has two parts: a DriverKit USB driver embedded in the app,
and a Metal renderer.

The BU505MCF is **not** a UVC webcam, so iPadOS can't use it as an external camera on its
own. This project implements the USB3 Vision control and streaming protocols itself.

## Data path

```
camera ──bulk IN DMA──▶ frame buffer (IOBufferMemoryDescriptor, in the driver)
                              │  mapped into the app (IOConnectMapMemory64)
                              ▼
                     MTLBuffer(bytesNoCopy:)  ──▶ fragment shader ──▶ drawable
```

* **No copies.** The USB controller DMAs into buffers that the app maps directly. The
  same memory is wrapped as an `MTLBuffer` without copying. The fragment shader reads the raw
  Bayer, mono or RGB bytes, demosaics them, and writes straight into the drawable in one pass.
  There are no textures, uploads, or intermediate passes.
* **Three transfers per frame.** Leader, the whole image, and trailer, each into its own buffer from
  `IOUSBHostInterface::CreateIOBuffer` (never bounced). The image arrives in a single transfer
  straight into the shared frame buffer. Three frames are kept in flight.
* **Don't use sub-descriptors for USB I/O.** Transfers into `CreateSubMemoryDescriptor` windows
  (with or without the `AsyncIOBundled` ring) kernel-panicked iPadOS 27.0 on stream start:
  "A kext releasing a(n) AppleUSBHostClientBufferMemoryDescriptor has corrupted the registry".
* **No system calls per frame on the app side.** Frame hand-off goes through a shared control
  page using atomics (`Shared/U3VShared.h`). The driver publishes `latest = seq<<8 | index`. On
  each vsync the display loop claims that buffer with a compare-and-swap and frees it when the
  GPU finishes. If the app falls behind, the driver reclaims older frames it hasn't read yet and
  never blocks the bus.

## Layout

| Path | What |
|---|---|
| `Driver/U3VDriver.*` | DriverKit service: matches the U3V control interface, opens the sibling streaming interface, handles GenCP register access, configures the SIRM, runs the frame ring |
| `Driver/U3VUserClient.*` | App connection: read/write memory, start/stop stream, memory mapping |
| `Driver/U3VProtocol.h` | USB3 Vision wire formats and bootstrap registers |
| `Shared/U3VShared.h` | Selectors and the shared control-page layout (used by the driver and Swift) |
| `App/DriverConnection.swift` | IOKit: device arrival/removal, method calls, memory mapping |
| `App/GenICam.swift` | Downloads and unzips the camera's GenICam XML. A small GenApi interpreter (registers, converters, SwissKnife formulas, enums) |
| `App/FrameRenderer.swift`, `App/Shaders.metal` | Zero-copy Metal presentation |
| `App/CameraController.swift`, `App/ContentView.swift` | Connection, acquisition, feature panel UI |

## Building

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
```

Then open `U3VCamera.xcodeproj`.

1. **Team.** Set `DEVELOPMENT_TEAM` in `project.yml` (or in Xcode for both targets) to a paid
   developer team; DriverKit needs one.
2. **Vendor ID.** The driver matches `idVendor` 3696 (0x0E70), confirmed on a BU505MCF (product ID
   0x0028). For a different camera, plug it into a Mac and check with:
   ```bash
   ioreg -p IOUSB -l -w0 | grep -E '"USB Product Name"|idVendor|idProduct'
   ```
   If it's different, update it in **both** `Driver/Info.plist` and `Driver/U3VDriver.entitlements`.
3. **Entitlements.** The driver needs `com.apple.developer.driverkit` and
   `com.apple.developer.driverkit.transport.usb` (for that vendor ID). The app needs
   `com.apple.developer.driverkit.communicates-with-drivers`. If automatic signing can't add the
   DriverKit ones to your profiles, request them from Apple for your team.
4. Run on an iPad with an M-series chip (DriverKit isn't available on A-series iPads).
5. On the iPad, turn on the app's driver in Settings, then reconnect the camera.

## Status and known risks

Confirmed working on an iPad Air (M4): the driver matches the camera and streams video to the screen. Things to watch:

* **Diagnostics.** The app writes `Documents/usb-devices.txt` (USB devices, which driver is attached,
  the driver's startup stage and error). With the camera in the iPad's only port, fetch it over Wi-Fi:
  `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.bitcount.u3v.camera --source Documents/usb-devices.txt --destination .`
* **GenICam coverage.** Teli's XML may use constructs this interpreter skips (selectors,
  `pIsLocked`, cached nodes). Streaming doesn't depend on GenICam, but feature controls do.
* **Pixel formats.** Packed formats (e.g. `BayerRG12p`) aren't decoded. Use 8-bit or unpacked
  16-bit formats.
* **Hubs and adapters.** The camera only works at USB 3 SuperSpeed. Through a USB-C multiport adapter
  that reported only a USB 2.0 hub, iPadOS didn't see it at all; connect it directly or via a USB 3 hub.
* **Power.** If the camera browns out on the iPad's port, use a powered USB‑C hub.

Logs from the driver: Console.app with the iPad selected, filter on `U3VDriver`.
