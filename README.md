# TMflash

TMflash is a macOS application and command-line tool for flashing and provisioning TMsense thermal nodes. It builds one release image, writes firmware to selected boards, saves per-node settings through USB serial, and checks the resulting configuration.

Single-node and batch workflows share the same core. Batch size follows the connected USB devices and host resources. Supported settings include local-gateway or direct-cloud transport, Wi-Fi credentials, and node identity.

## Interesting techniques

- **Shared application and CLI logic.** [TMflashCore](Sources/TMflashCore/) owns device discovery, builds, flashing, provisioning, and verification. The graphical application and CLI provide separate interfaces to that core.
- **Concurrent, independent board jobs.** The [pipeline](Sources/TMflashCore/Pipeline.swift) uses Swift task groups. Blocking serial work runs on dispatch queues, and one failed board does not stop the remaining jobs.
- **Firmware-derived flash layouts.** [Toolchain handling](Sources/TMflashCore/Toolchain.swift) reads PlatformIO metadata for image paths and offsets. Flashing preserves NVS settings and replay counters.
- **One entry per physical USB board.** [Device discovery](Sources/TMflashCore/SerialDevices.swift) deduplicates serial ports by USB location when multiple drivers expose the same device.
- **Capability checks before writes.** The [serial console adapter](Sources/TMflashCore/NodeConsole.swift) reads firmware capabilities before enabling direct-cloud transport. Unsupported requests fail before provisioning starts.
- **Verification through readback.** Saved identity, transport, and network settings are checked against the firmware's response. Direct-cloud verification also waits for an edge-accepted report.
- **Byte-aware Wi-Fi selection.** The [network scanner](Sources/TMflashCore/WiFiScanner.swift) preserves SSID identity by bytes, collapses duplicate access points, and prefers compatible 2.4 GHz networks.
- **Separate secret and result storage.** [Record handling](Sources/TMflashCore/Records.swift) stores remembered credentials in the macOS Keychain and writes operational results to a CSV manifest without password or key fields.
- **Hardware-free serial tests.** [Fake nodes](Tests/TMflashCoreTests/FakeNode.swift) speak the firmware console protocol over pseudo-terminals, allowing tests to exercise real serial communication.

## Technologies and libraries

- [SwiftUI](https://developer.apple.com/documentation/swiftui) provides the native interface.
- [IOKit](https://developer.apple.com/documentation/iokit) discovers USB serial devices.
- [CoreWLAN](https://developer.apple.com/documentation/corewlan) scans Wi-Fi networks. [Core Location](https://developer.apple.com/documentation/corelocation) handles the permission needed to reveal network names.
- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services) stores remembered secrets.
- [PlatformIO](https://docs.platformio.org/en/latest/) builds firmware, and [esptool](https://docs.espressif.com/projects/esptool/en/latest/esp32/) writes it to ESP32 boards.
- [Package.swift](Package.swift) defines the app, CLI, shared core, and test targets without third-party Swift package dependencies.

The interface uses native system typography. Icons and preview images are rendered by the application; no external font or image pack is required.

## Project structure

```text
TMflash/
├── .github/workflows/
├── Sources/
│   ├── TMflash/
│   ├── TMflashCore/
│   └── tmflash-cli/
├── Tests/
│   ├── TMflashAppTests/
│   └── TMflashCoreTests/
├── scripts/
├── Package.swift
└── README.md
```

- [Sources/TMflash/](Sources/TMflash/) contains the SwiftUI screens, app state, Wi-Fi permission handling, and snapshot rendering.
- [Sources/TMflashCore/](Sources/TMflashCore/) contains hardware communication and the shared provisioning pipeline.
- [Sources/tmflash-cli/](Sources/tmflash-cli/) exposes the same operations to scripts.
- [Tests/](Tests/) covers batch isolation, validation, serial behavior, capability negotiation, device deduplication, and Wi-Fi selection.
- [scripts/](scripts/) packages the application and CLI into a macOS app bundle.
