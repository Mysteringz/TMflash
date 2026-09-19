import SwiftUI
import TMflashCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider()
            Group {
                switch model.phase {
                case .setup: SetupView()
                case .building, .flashing, .finished: RunView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct Header: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            AppMark().frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("TMflash").font(.system(size: 22, weight: .semibold))
                Text("Flash and set up TMsense thermal nodes").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Mode", selection: $model.mode) {
                ForEach(AppModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .disabled(model.phase != .setup)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

/// The app's mark: a heat blob seen from above, as the sensor sees a person.
struct AppMark: View {
    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: d * 0.23, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.30), Color(red: 0.22, green: 0.10, blue: 0.42)],
                                         startPoint: .top, endPoint: .bottom))
                Circle()
                    .fill(RadialGradient(colors: [.white, .yellow, .orange, .red.opacity(0.0)], center: .center,
                                         startRadius: 0, endRadius: d * 0.38))
                    .frame(width: d * 0.72, height: d * 0.72)
                Image(systemName: "bolt.fill").font(.system(size: d * 0.27, weight: .bold)).foregroundStyle(.black.opacity(0.7))
            }
            .frame(width: d, height: d)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            DevicePanel()
                .frame(width: 330)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
            VStack(spacing: 0) {
                ScrollView { SettingsForm().padding(22) }
                Divider()
                FlashBar().padding(.horizontal, 22).padding(.vertical, 14)
            }
        }
    }
}

struct DevicePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.mode == .single ? "Device" : "Devices").font(.headline)
                if model.mode == .batch {
                    Text("\(model.batchPorts.count)/\(NodeSettings.maxBatch)").font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
                Button { model.probes = [:]; model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Rescan and re-identify boards. Opening a board's serial port restarts it.")
            }
            if model.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("No boards connected").font(.callout.weight(.medium))
                    Text("Plug a TMsense (Heltec V3) into USB. It appears here automatically.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.devices) { DeviceCard(device: $0) }
                    }
                }
                if model.mode == .batch {
                    HStack {
                        Button("Select all") {
                            for d in model.devices.prefix(NodeSettings.maxBatch) { model.batchPorts.insert(d.path) }
                        }
                        Button("None") { model.batchPorts = [] }
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }
}

struct DeviceCard: View {
    @EnvironmentObject var model: AppModel
    let device: SerialDevice

    private var selected: Bool {
        model.mode == .single ? model.selectedPort == device.path : model.batchPorts.contains(device.path)
    }

    var body: some View {
        Button {
            if model.mode == .single { model.selectedPort = device.path } else { model.toggleBatch(device.path) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.mode == .single ? (selected ? "largecircle.fill.circle" : "circle")
                                                        : (selected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(device.name).font(.system(.body, design: .monospaced).weight(.medium)).lineLimit(1)
                        Spacer()
                        if model.mode == .batch, selected, let id = model.assignedID(for: device.path) {
                            Text("ID \(id)").font(.caption.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                    }
                    Text(device.summary).font(.caption).foregroundStyle(.secondary)
                    ProbeLine(state: model.probes[device.path], esp: device.looksLikeESP32)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProbeLine: View {
    let state: AppModel.ProbeState?
    let esp: Bool

    var body: some View {
        switch state {
        case .checking:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Identifying… (the board restarts)") }
                .font(.caption).foregroundStyle(.secondary)
        case .tmsense(let info):
            Label {
                Text("TMsense \(info.nodeID.map { "#\($0)" } ?? "(no ID)") · \(info.uid ?? "?") · \(info.firmware ?? "?")")
            } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
            .font(.caption)
        case .noAnswer:
            Label("No TMsense firmware answered — new board?", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case nil:
            if !esp { Label("Not a known ESP32 USB bridge", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        }
    }
}

// MARK: - Settings

struct SettingsForm: View {
    @EnvironmentObject var model: AppModel
    @State private var showPassword = false
    @State private var showKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormSection("Node identity") {
                if model.mode == .single {
                    Field("Node ID", hint: "1–65535, written on the enclosure") {
                        TextField("e.g. 3", text: $model.nodeIDText).frame(width: 120)
                    }
                } else {
                    Field("Node IDs", hint: batchHint) {
                        HStack(spacing: 8) {
                            TextField("from", text: $model.startIDText).frame(width: 90)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("to", text: $model.endIDText).frame(width: 90)
                        }
                    }
                }
            }

            FormSection("Uplink") {
                Field("Mode", hint: model.settings.mode == .wifi ? "Node → TMWAccess over the site's Wi-Fi"
                                                                  : "Node → TMLAccess over LoRa") {
                    HStack(spacing: 10) {
                        Text("Wi-Fi").foregroundStyle(model.settings.mode == .wifi ? .primary : .secondary)
                        Toggle("", isOn: Binding(get: { model.settings.mode == .lora },
                                                 set: { model.setUplink($0 ? .lora : .wifi) }))
                            .toggleStyle(.switch).labelsHidden()
                        Text("LoRa").foregroundStyle(model.settings.mode == .lora ? .primary : .secondary)
                    }
                }
                if model.settings.mode == .wifi {
                    Field("Wi-Fi SSID", hint: "2.4 GHz network") {
                        TextField("keep node's current", text: $model.settings.ssid).frame(width: 260)
                    }
                    Field("Wi-Fi password") {
                        HStack {
                            Group {
                                if showPassword { TextField("keep node's current", text: $model.settings.password) }
                                else { SecureField("keep node's current", text: $model.settings.password) }
                            }.frame(width: 260)
                            RevealButton(on: $showPassword)
                        }
                    }
                    Field("TMWAccess IP", hint: "The Wi-Fi gateway's LAN address") {
                        TextField("e.g. 192.168.0.43", text: $model.settings.gateway).frame(width: 180)
                    }
                } else {
                    Field("TMLAccess IP", hint: "The LoRa gateway's address") {
                        TextField("e.g. 192.168.0.60", text: $model.settings.gateway).frame(width: 180)
                    }
                    Notice(icon: "antenna.radiowaves.left.and.right", color: .orange,
                           text: "The TMsense firmware does not have a LoRa uplink yet. The node stores this mode and address, but sends nothing until LoRa support ships. Switch to Wi-Fi for a working node today.")
                }
            }

            FormSection("Security") {
                Field("Signing key", hint: "TMedge's TM_KEY — the same on every node") {
                    HStack {
                        Group {
                            if showKey { TextField("keep node's current", text: $model.settings.key) }
                            else { SecureField("keep node's current", text: $model.settings.key) }
                        }.frame(width: 260)
                        RevealButton(on: $showKey)
                    }
                }
                Field("") {
                    Toggle("Remember password and key in the Keychain", isOn: $model.rememberSecrets)
                }
            }

            FormSection("Firmware") {
                Field("Source", hint: model.projectDir.map { abbreviate($0) } ?? "Not found") {
                    HStack {
                        Text(model.firmwareVersion ?? "—").font(.system(.body, design: .monospaced))
                        Button("Change…") { model.chooseProject() }.controlSize(.small)
                    }
                }
                Field("") {
                    Toggle("Write firmware (off: only update the settings)", isOn: $model.flashFirmware)
                }
            }

            Text("Blank fields keep what the node already has. The node's saved settings and boot counter survive flashing; nothing is erased.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var batchHint: String {
        let n = model.orderedBatchPorts.count
        switch model.plan {
        case .success(let jobs): return "\(jobs.count) board\(jobs.count == 1 ? "" : "s") → IDs \(jobs.map { String($0.nodeID) }.joined(separator: ", "))"
        case .failure: return n == 0 ? "Tick boards on the left; IDs go in list order" : "\(n) board\(n == 1 ? "" : "s") ticked: the range must hold \(n) ID\(n == 1 ? "" : "s")"
        }
    }

    private func abbreviate(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

private struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
        }
    }
}

private struct Field<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let content: Content
    init(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label; self.hint = hint; self.content = content()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).frame(width: 120, alignment: .trailing).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                content.textFieldStyle(.roundedBorder)
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct RevealButton: View {
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: { Image(systemName: on ? "eye.slash" : "eye") }
            .buttonStyle(.borderless)
            .help(on ? "Hide" : "Show")
    }
}

struct Notice: View {
    let icon: String
    let color: Color
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }
}

struct FlashBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            if let first = model.blockers.first {
                Label(first, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Label(readyText, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(action: model.start) {
                Text(buttonTitle).font(.headline).frame(minWidth: 150).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.blockers.isEmpty)
        }
    }

    private var count: Int { (try? model.plan.get().count) ?? (model.mode == .single ? 1 : max(1, model.batchPorts.count)) }
    private var buttonTitle: String {
        let verb = model.flashFirmware ? "Flash" : "Configure"
        return model.mode == .single ? verb : "\(verb) \(count) node\(count == 1 ? "" : "s")"
    }
    private var readyText: String {
        model.flashFirmware ? "Builds the firmware, writes it, then sets up and checks each node"
                            : "Writes the settings and checks each node"
    }
}
