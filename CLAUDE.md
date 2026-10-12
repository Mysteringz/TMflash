# TMflash — notes for AI coding sessions

macOS app (SwiftUI, SwiftPM) that builds, flashes and provisions TMsense nodes.
Pairs with `../TMsense` (firmware). Read README.md for the design.

## Map

```
Sources/TMflashCore/NodeSettings.swift   settings, validation, batch IDs, console commands
Sources/TMflashCore/NodeConsole.swift    TMsense serial console: show parsing, run, verify
Sources/TMflashCore/SerialPort.swift     POSIX termios port
Sources/TMflashCore/SerialDevices.swift  IOKit USB serial discovery, dedupe by USB location
Sources/TMflashCore/Toolchain.swift      pio build + metadata -> flash images; esptool args
Sources/TMflashCore/PortableFirmware.swift checked bundled GitHub release and partition layout
scripts/release_manifest.py              public DMG contract read by TMedge's download page
Sources/TMflashCore/Flasher.swift        esptool run + progress parsing
Sources/TMflashCore/Pipeline.swift       per-board flash -> provision -> verify, in parallel
Sources/TMflashCore/Records.swift        manifest CSV, Keychain, probe
Sources/TMflash/                         SwiftUI app (+ --snapshot / --icon modes)
Sources/tmflash-cli/                     CLI on the same core
Tests/TMflashCoreTests/FakeNode.swift    fake TMsense console on a pty
```

## Commands

```sh
swift test
swift build && .build/debug/TMflash --snapshot /tmp/s.png --scene batch [--dark]
scripts/build-app.sh [install]
python3 scripts/build-dmg.py             # self-contained Intel + Apple Silicon DMG
```

## Invariants

- **Never erase flash.** NVS holds the node's settings and its boot counter;
  a reset boot counter makes TMedge reject the node's packets as replays.
- **Portable builds use their included release and tools.** A damaged bundle
  fails before USB writes; it never falls back to a developer's source tree.
  Packaging uses the latest published TMsense GitHub release, checks its
  manifest, and pins the standalone esptool archives. Firmware, boot selector
  and partition layout checks must preserve NVS and all other data partitions.
- **Published app builds are immutable and identify clean source.** The
  master release workflow publishes the DMG and `tmflash-app.json` together.
  TMedge checks that manifest before hosting the file; change writer and
  reader together. An older master run cannot replace a newer latest build.
- **Never log, store or pass secrets on a command line.** Password and key go
  only to the node's serial port and the Keychain; the CLI takes them from env.
- **The console protocol is TMsense's** (`src/tm_settings.cpp`): `show` field
  names (`uid`, `fw`, `node_id`, `mode`, `lora_gw`, `ssid`, `password`,
  `edges`, `key`, then from 1.4 `transport`, `cloud_url`, `caps`, `uplink`,
  `report_ack`, then `boot`) and the `<name> updated` / `saved` replies.
  From 1.6, `fps` is also before `boot`; capability `fps1` enables `set fps`.
  Change both sides together.
- **Ask the firmware before using new commands.** `caps` containing `wss1`
  means it knows `transport`/`cloud_url`; without it nothing about transport
  is sent, and a request for direct cloud is refused before any write.
- **Wi-Fi joined is not success for direct cloud.** Only the node's
  "[cloud] report accepted by the edge" line (an ACK) is.
- **Asking is not being admitted.** `EdgeClient` queues a join request with
  TMedge; a person at the edge console allows it. Flashing is not finished
  until the node is admitted, and the "TMedge accepts its reports" check is
  skipped when it is not -- an edge that has never heard of a uid refuses its
  first packet, which would otherwise be reported as a broken node.
- **One image for every node** (`[env:tmflash]`, `TM_NO_NODE_CONFIG`); per-node
  values are provisioned, never compiled in.
- The product binaries are `TMflash` and `tmflash-cli` — not `tmflash`, which
  collides with `TMflash` on a case-insensitive disk.
