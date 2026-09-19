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
```

## Invariants

- **Never erase flash.** NVS holds the node's settings and its boot counter;
  a reset boot counter makes TMedge reject the node's packets as replays.
- **Never log, store or pass secrets on a command line.** Password and key go
  only to the node's serial port and the Keychain; the CLI takes them from env.
- **The console protocol is TMsense's** (`src/tm_settings.cpp`): `show` field
  names (`uid`, `fw`, `node_id`, `mode`, `lora_gw`, `ssid`, `password`,
  `edges`, `key`, `boot`) and the `<name> updated` / `saved` replies. Change
  both sides together.
- **One image for every node** (`[env:tmflash]`, `TM_NO_NODE_CONFIG`); per-node
  values are provisioned, never compiled in.
- The product binaries are `TMflash` and `tmflash-cli` — not `tmflash`, which
  collides with `TMflash` on a case-insensitive disk.
