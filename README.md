# TMflash

TMflash is a macOS application and command-line tool for flashing and provisioning TMsense thermal nodes. The portable application carries a published firmware image and native flashing tools, writes firmware to selected boards, saves per-node settings through USB serial, and checks the resulting configuration. Developer builds can also compile firmware with PlatformIO.

Single-node and batch workflows share the same core. Batch size follows the connected USB devices and host resources. Supported settings include local-gateway or direct-cloud transport, Wi-Fi credentials, node identity, and 1/2/4 fps selection. LoRa stores settings only; the firmware's LoRa uplink is not implemented.

The application guides setup through **connection mode → Wi-Fi destination → network settings → security & verification → speed & device ID → review & flash**. LoRa skips the Wi-Fi destination step. The sidebar keeps setup steps and USB selection visible; Back, Continue and review-page Edit links let users revisit their choices. The final step offers Firmware + settings or Settings only, and hides passwords and signing keys from the summary.

## Install the portable application

Open the DMG, drag **TMflash.app** onto **Applications**, then eject the image and open the installed app. It supports **Intel and Apple Silicon Macs running macOS 14 or later** and keeps the black tile with its white lightning bolt.

The DMG includes the TMsense release that was latest when the image was packaged, the standard boot selector, and Espressif's standalone esptool 4.11.0 for both architectures. Recipients do not need Python, Homebrew, Xcode, PlatformIO or a firmware source folder. Firmware flashing works offline; browser account sign-in and cloud adoption need internet access. Updating the included firmware means building a new DMG.

The firmware's manifest, image sizes, SHA-256 hashes, chip, partition-table checksum and flash layout are checked before use. Damaged bundles fail before USB writes. NVS and replay counters survive flashing. Settings only remains available without firmware.

An ad-hoc signed build can show an unidentified-developer warning. For a build from a trusted source, follow [Apple's opening instructions](https://support.apple.com/en-us/102445). Public distribution with normal Gatekeeper verification requires a Developer ID Application certificate and Apple notarization; the packaging script supports both, but does not obtain credentials or disable Gatekeeper.

## Build a DMG

Packaging needs Xcode/Command Line Tools, Python 3 and the GitHub CLI authenticated for release downloads. These are developer requirements, not recipient requirements.

```sh
swift test
python3 scripts/build-dmg.py
# → build/TMflash-1.5.0-universal.dmg and its SHA-256 file
```

The script downloads the latest published release from `Mysteringz/TMsense`, verifies it, pins and checks the official esptool archives, builds both app/CLI architectures, removes the developer's firmware-folder hint, signs the app and verifies the DMG. The app contains third-party license information and esptool source. The DMG has an Applications shortcut and installation instructions. Downloads are cached under `build/portable-assets/`.

With an installed Developer ID certificate and an existing `notarytool` Keychain profile:

```sh
python3 scripts/build-dmg.py \
  --sign-identity 'Developer ID Application: Example Organisation (TEAMID)' \
  --notary-profile tmflash-notary
```

This signs the app and its executables, submits the app to Apple, staples its accepted ticket, then builds, signs, submits and staples the DMG. A rejected submission fails packaging. No developer certificate is needed for the default ad-hoc build. The notarization path requires actual Apple credentials and cannot be exercised without them.

The bundled CLI can check an installed app without opening a board:

```sh
/Applications/TMflash.app/Contents/MacOS/tmflash-cli firmware
```

`scripts/build-app.sh` still makes a source-based developer build; `scripts/build-app.sh universal` builds both Mac architectures. A developer CLI `--project DIR` override or its `build` command requires PlatformIO.

## Automatic published builds

Every update merged to `master` runs **Publish portable DMG**: Swift and manifest tests, a self-contained universal build, signature/DMG checks, then a GitHub release named `build-<full source commit>`. It attaches the DMG, checksum and `tmflash-app.json` and marks the release latest. A build superseded by newer master code is not published; an existing commit's release is never replaced. The workflow can also be started manually on master.

The algo portal's separate **TMflash download** page checks this latest published manifest every minute, verifies and caches the installer on its server, and offers it with installation instructions. Native app updates need no repeated TMedge PR or DMG upload. The manifest identifies the app, source commit, platform requirements, bundled firmware, size and SHA-256. Only clean builds are accepted by the portal. Builds made from an edited working tree are still available locally but are marked as modified in the manifest.

The initial workflow uses ad-hoc signing. It does not claim notarization or contain Apple credentials. Developer ID signing/notarization must be configured before releases can avoid macOS's unidentified-developer warning.

## Interesting techniques

- **Shared application and CLI logic.** [TMflashCore](Sources/TMflashCore/) owns device discovery, builds, flashing, provisioning, and verification. The graphical application and CLI provide separate interfaces to that core.
- **Guided setup with scoped settings.** [Setup steps](Sources/TMflash/SetupStep.swift) and the [app model](Sources/TMflash/AppModel.swift) show and validate fields for the selected connection. Hidden route settings are retained for editing but excluded from device writes; direct Wi-Fi leaves the saved local gateway untouched.
- **Concurrent, independent board jobs.** The [pipeline](Sources/TMflashCore/Pipeline.swift) uses Swift task groups. Blocking serial work runs on dispatch queues, and one failed board does not stop the remaining jobs.
- **Firmware-derived flash layouts.** [Portable firmware](Sources/TMflashCore/PortableFirmware.swift) verifies the included release and derives its flash layout from the checked partition table. [Toolchain handling](Sources/TMflashCore/Toolchain.swift) reads PlatformIO metadata for source builds. Both preserve NVS settings and replay counters.
- **One entry per physical USB board.** [Device discovery](Sources/TMflashCore/SerialDevices.swift) deduplicates serial ports by USB location when multiple drivers expose the same device.
- **Capability checks before writes.** The [serial console adapter](Sources/TMflashCore/NodeConsole.swift) reads firmware capabilities before enabling direct-cloud transport or 1/2/4 fps selection. Unsupported requests fail before provisioning starts; omitting a rate keeps the node's current setting.
- **Verification through readback.** Saved identity, transport, and network settings are checked against the firmware's response. Direct-cloud verification also waits for an edge-accepted report.
- **Account-bound adoption.** [Account sign-in](Sources/TMflashCore/AccountLogin.swift) uses the browser and PKCE, with an expiring 24-hour session held in Keychain. When adopting a board, the [edge client](Sources/TMflashCore/EdgeClient.swift) checks account access before device writes. A person compares its physical UID and request code in the console before approving admission; direct-cloud success still requires a fresh report ACK from the rebooted board.
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
- [Tests/](Tests/) covers guided setup, route-specific writes, account sign-in, batch isolation, validation, serial behavior, capability negotiation, device deduplication, and Wi-Fi selection.
- [scripts/](scripts/) packages the application and CLI into a macOS app bundle.
