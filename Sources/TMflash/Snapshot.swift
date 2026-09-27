import AppKit
import SwiftUI
import TMflashCore

/// Renders a screen with sample data into a PNG (real AppKit controls, not an
/// approximation), for checking the UI in light and dark without hardware.
@MainActor
enum Snapshot {
    static func render(scene: String, dark: Bool, to path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model: AppModel
        if scene == "live" {
            // The real model: real USB detection and identification (which
            // restarts the boards). Settings from a scratch defaults suite.
            model = AppModel(live: true, defaults: UserDefaults(suiteName: "TMflash.snapshot.live") ?? .standard)
            let until = Date().addingTimeInterval(8)
            while Date() < until && (model.devices.isEmpty || model.probes.values.contains(.checking)) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        } else {
            model = AppModel(live: false, defaults: UserDefaults(suiteName: "TMflash.snapshot") ?? .standard)
            populate(model, scene: scene)
        }

        let view = NSHostingView(rootView: ContentView().environmentObject(model))
        let size = NSSize(width: 900, height: 800)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        // Let SwiftUI lay out and settle.
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); view.layoutSubtreeIfNeeded() }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func populate(_ m: AppModel, scene: String) {
        let boards = (1...4).map {
            SerialDevice(path: "/dev/cu.usbserial-000\(String($0))", vendorID: 0x10C4, productID: 0xEA60, product: "CP2102 USB to UART Bridge Controller",
                         serialNumber: "000\(String($0))", locationID: $0)
        }
        m.projectDir = NSHomeDirectory() + "/Desktop/IOT/TMsense"
        m.firmwareVersion = "tmsense-1.1"
        m.settings = NodeSettings(mode: .wifi, ssid: "EsanHouse", password: "password1", gateway: "192.168.0.43", key: "k")
        let info = NodeInfo(fields: ["uid": "30:ed:a0:cb:f5:f8", "fw": "tmsense-1.1", "node_id": "3", "mode": "wifi"])
        switch scene {
        case "empty":
            m.devices = []
        case "batch":
            m.mode = .batch
            m.devices = boards
            m.batchPorts = Set(boards.prefix(3).map(\.path))
            m.startIDText = "11"; m.endIDText = "13"
            m.probes = [boards[0].path: .tmsense(info), boards[1].path: .noAnswer, boards[2].path: .noAnswer, boards[3].path: .checking]
        case "lora":
            m.devices = [boards[0]]
            m.selectedPort = boards[0].path
            m.nodeIDText = "4"
            m.settings = NodeSettings(mode: .lora, gateway: "192.168.0.60", key: "k")
            m.probes = [boards[0].path: .tmsense(info)]
        case "cloud":
            m.devices = [boards[0]]
            m.selectedPort = boards[0].path
            m.nodeIDText = "3"
            m.firmwareVersion = "tmsense-1.4"
            m.settings = NodeSettings(mode: .wifi, ssid: "EsanHouse", password: "password1", gateway: "192.168.0.43", key: "k",
                                      transport: .wss, cloudURL: "wss://sense.example.com/tmnode")
            m.probes = [boards[0].path: .tmsense(NodeInfo(fields: ["uid": "30:ed:a0:cb:f5:f8", "fw": "tmsense-1.4", "node_id": "3", "mode": "wifi",
                                                                   "transport": "udp", "caps": "wss1,ota-https1"]))]
        case "cloud-done":
            m.phase = .finished
            m.devices = [boards[0], boards[1]]
            m.rows = [AppModel.Row(port: boards[0].path, nodeID: 3), AppModel.Row(port: boards[1].path, nodeID: 4)]
            var ok = JobResult(job: DeviceJob(port: boards[0].path, nodeID: 3), uid: "30:ed:a0:cb:f5:f8", firmware: "tmsense-1.4", wifiIP: "192.168.0.9")
            ok.edgeAccepted = true
            ok.transport = .wss
            var no = JobResult(job: DeviceJob(port: boards[1].path, nodeID: 4), uid: "30:ed:a0:12:34:56", firmware: "tmsense-1.4", wifiIP: "192.168.0.12",
                               warnings: ["joined Wi-Fi, but TMedge did not accept a report within 90 s (last error: upgrade refused (403)) — the node is not delivering occupancy yet"])
            no.edgeAccepted = false
            no.transport = .wss
            m.rows[0].result = ok
            m.rows[1].result = no
            m.rows[0].stage = .done
            m.rows[1].stage = .done
        case "running", "done":
            m.mode = .batch
            m.devices = boards
            m.phase = scene == "running" ? .flashing : .finished
            m.rows = boards.prefix(3).enumerated().map { i, b in AppModel.Row(port: b.path, nodeID: 11 + i) }
            if scene == "running" {
                m.rows[0].stage = .flashing(0.62)
                m.rows[1].stage = .provisioning
                m.rows[2].stage = .joiningWiFi
                m.rows[1].log = ["› set id 12", "› set mode wifi", "› set ssid EsanHouse", "› set pass ••••••"]
            } else {
                let jobs = m.rows.map { DeviceJob(port: $0.port, nodeID: $0.nodeID) }
                m.rows[0].result = JobResult(job: jobs[0], uid: "30:ed:a0:cb:f5:f8", firmware: "tmsense-1.1", wifiIP: "192.168.0.9")
                m.rows[1].result = JobResult(job: jobs[1], uid: "30:ed:a0:12:34:56", firmware: "tmsense-1.1", wifiIP: nil,
                                             warnings: ["did not join “EsanHouse” within 30 s — check the SSID, password and signal"])
                m.rows[2].result = JobResult(job: jobs[2], error: "Failed to connect to ESP32-S3: No serial data received. — hold the board's PRG/BOOT button, tap RST, and try again")
                for i in 0..<3 { m.rows[i].stage = m.rows[i].result?.ok == true ? .done : .failed }
            }
        default:
            m.devices = [boards[0]]
            m.selectedPort = boards[0].path
            m.nodeIDText = "3"
            m.probes = [boards[0].path: .tmsense(info)]
        }
    }
}
