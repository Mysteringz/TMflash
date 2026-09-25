# TMflash

A Mac app for flashing **TMsense** thermal nodes (Heltec WiFi LoRa 32 V3 with
an MLX90640) and setting them up in one click, in the style of Raspberry Pi
Imager. Plug in a board, type its node ID and network details, and press
**Flash**. TMflash then:

1. **builds** the TMsense firmware from source with PlatformIO (`pio run -e
   tmflash`),
2. **writes** it with esptool,
3. **sets the node up** over USB serial: node ID, Wi-Fi or LoRa mode, SSID,
   password, gateway IP and signing key,
4. **checks** it: reads the settings back and verifies them, then restarts
   the node and waits until it joins the Wi-Fi.

**Batch mode** does the same for up to 10 boards at once, in parallel. You
give a starting and an ending node ID, and the boards get consecutive IDs in
the order they're listed.

```
┌ TMflash ─────────────────────────────────────── [Single node | Batch (up to 10)] ┐
│ Device                │ NODE IDENTITY   Node ID [ 3 ]                             │
│ (•) usbserial-0001    │ UPLINK          Mode  Wi-Fi (  ) LoRa                     │
│     Silicon Labs CP210x│                 SSID [EsanHouse]  Password [••••]         │
│     ✔ TMsense #3 · 30:ed:a0:… · tmsense-1.1                                       │
│                       │                 TMWAccess IP [192.168.0.43]               │
│                       │ SECURITY        Signing key [••••]  ☑ remember in Keychain│
│                       │ FIRMWARE        tmsense-1.1  ~/Desktop/IOT/TMsense        │
│                       │                                          [   Flash   ]    │
└───────────────────────┴──────────────────────────────────────────────────────────┘
```

## Install

You need:

- macOS 14 or later.
- Xcode or the Command Line Tools, to build the app (`swift --version`).
- PlatformIO: `brew install platformio`, or the VS Code extension, which
  puts `pio` in `~/.platformio/penv/bin`. The first build downloads the
  ESP32-S3 toolchain, about 1 GB.
- The `TMsense` folder next to `TMflash` (`../TMsense`), or anywhere you
  point the app to with **Change…**.

```sh
scripts/build-app.sh            # → build/TMflash.app
scripts/build-app.sh install    # …and copy it to /Applications
open build/TMflash.app
```

The app is ad-hoc signed for this Mac. On another Mac, run the script there,
or right-click → Open the first time.

The Heltec V3's USB bridge is a CP2102. macOS 14+ has a driver built in and
the board appears as `/dev/cu.usbserial-XXXX`. If Silicon Labs' own driver is
also installed, the same board appears a second time as
`cu.SLAB_USBtoUART`. TMflash shows it once.

## Use

**Single node**

1. Plug in the board. It appears under **Device** and TMflash asks it what it
   runs (e.g. *TMsense #3 · 30:ed:a0:cb:f5:f8 · tmsense-1.1*). Opening a
   serial port restarts an ESP32, so identifying a board restarts it.
2. Enter the **Node ID** (1–65535). Write the same number on the enclosure.
3. Choose **Wi-Fi** or **LoRa**:
   - Wi-Fi: the SSID (2.4 GHz), the password, and the **TMWAccess IP**.
     That's the Wi-Fi gateway's LAN address, e.g. `192.168.0.43` at
     EsanHouse.
   - LoRa: the **TMLAccess IP**. *The firmware has no LoRa uplink yet.* A
     node in LoRa mode stores the setting and says so on its console, but it
     sends nothing until LoRa support ships. TMflash warns about this.
4. Enter the **signing key**: TMedge's `TM_KEY`, the same on every node.
5. Press **Flash**.

**Batch (up to 10)**

Tick the boards, then enter **Node IDs from … to …**. The range must hold
exactly as many IDs as there are ticked boards. Each board shows its ID badge
before you start. They're flashed and checked in parallel, and a failure on
one board never stops the others.

**Results**

Each node ends up in one of three states:

- ✔ Green: the settings were verified and the node joined Wi-Fi. Its IP is
  shown.
- ✔ Orange: set up as asked, but with something to check. For example, it
  didn't join Wi-Fi within 30 s (wrong password or out of range), or it has
  no signing key, which means TMedge will reject its packets.
- ✖ Red: it failed, and the reason is shown. If esptool can't connect,
  hold **PRG**, tap **RST**, and try again.

Every result is appended to the **manifest**,
`~/Library/Application Support/TMflash/manifest.csv`, with columns node ID,
MAC, mode, gateway, SSID, firmware, port, IP and result. TMedge identifies
nodes by MAC in `config/nodes.json`, so this ID ↔ MAC list is what you need
to register new nodes. **Show manifest** opens it.

**Handy details**

- **Blank fields keep what the node already has.** Re-flashing firmware
  doesn't make you re-type a password.
- **Write firmware** off: TMflash only updates the settings on a board that
  already runs TMsense 1.1 or newer.
- The Wi-Fi password and key can be remembered in the login **Keychain**.
  Nothing secret is written to disk, shown in the log or put in the
  manifest.

## How it works

```
TMflash.app (SwiftUI)          tmflash-cli
        └──────────┬───────────────┘
              TMflashCore
   ┌───────────────┼──────────────────┬───────────────────┐
SerialDevices   FirmwareProject      Flasher           NodeConsole
(IOKit: USB     (pio run -e tmflash; (esptool.py from   (TMsense serial console:
 serial ports,   pio project metadata  PlatformIO,        show / set / save /
 one per board)  → images + offsets)   parallel, per port) reboot, then verify)
```

- **One image, no per-node compile.** The same binary goes on every node.
  Everything that differs between nodes is written afterwards through the
  firmware's serial console (`set id 3`, `set mode wifi`, `set ssid …`,
  `set pass …`, `set edges …`, `set key …`, `save`), the same commands a
  person could type. The node stores them in NVS.
- **A release image with no secrets in it.** The `[env:tmflash]` build of
  TMsense defines `TM_NO_NODE_CONFIG`, which ignores the bench defaults in
  `include/node_config.h`. A flashed binary never carries a Wi-Fi password
  or key.
- **Nothing is erased.** esptool writes the bootloader, partition table,
  boot_app0 and application at the offsets PlatformIO reports. It never
  runs `erase_flash`, so the node's NVS survives, including its **boot
  counter**. Resetting that counter would make the node's packets look like
  replays to TMedge.
- **Parallel.** Each board gets its own esptool process, then its own
  serial session on a background thread. Builds happen once per run.
- **Verification is by reading back.** After `save`, TMflash sends `show` and
  compares the node ID, mode, SSID and gateway. The firmware never prints
  secrets, so for the password and key it checks that they are *set*. It
  then sends `reboot` and watches for `[wifi] connected ip=…`.
- **Detection** uses IOKit to list USB serial ports with their vendor and
  product IDs, recognising CP210x, CH34x, FTDI and Espressif native USB.
  When two drivers expose the same board, it is collapsed to one entry by
  USB location.

### Command line

The same engine, for scripts. Secrets come only from environment variables,
never from arguments, which would end up in shell history and `ps`:

```sh
CLI=build/TMflash.app/Contents/MacOS/tmflash-cli      # or: swift run tmflash-cli
$CLI ports --probe
TMFLASH_PASSWORD=… TMFLASH_KEY=… $CLI flash --port /dev/cu.usbserial-0001 --id 3 \
    --ssid EsanHouse --gateway 192.168.0.43
TMFLASH_PASSWORD=… TMFLASH_KEY=… $CLI batch --ports /dev/cu.usbserial-0001,/dev/cu.usbserial-0002 \
    --start 11 --end 12 --ssid EsanHouse --gateway 192.168.0.43
```

## Tests

```sh
swift test
```

These tests check claims about behaviour. The pipeline tests run the real
serial code against **fake TMsense nodes on pseudo-terminals**, which speak
the firmware's console. They cover:

- ten boards at once, each getting its own ID;
- one bad board not stopping the others;
- a silent board failing instead of hanging;
- secrets never reaching the log;
- LoRa mode storing its gateway and warning that it can't send yet.

Other tests cover:

- ID ranges and validation;
- esptool progress and metadata parsing;
- that TMflash never erases flash;
- collapsing a board that appears under two drivers.

To check the UI without hardware:

```sh
swift build && .build/debug/TMflash --snapshot /tmp/s.png --scene batch --dark
# scenes: single, batch, lora, running, done, empty
```

## Continuous integration

CI runs the fake serial-node tests and release builds on macOS. It does not
connect to hardware or flash devices.

Default-branch changes go through a pull request with required checks.
GitHub Actions dependencies are pinned and updated through Dependabot PRs.
