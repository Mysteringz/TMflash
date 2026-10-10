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
            Picker("Devices to configure", selection: $model.mode) {
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
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SetupNavigation().padding(18)
                Divider()
                DevicePanel()
            }
            .frame(width: 260)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    SettingsForm().padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(model.setupStep)
                Divider()
                if model.setupStep == .review {
                    FlashBar().padding(18)
                } else {
                    SetupBar().padding(18)
                }
            }
        }
    }
}

private struct SetupNavigation: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("DEVICE SETUP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 7)
            ForEach(Array(model.setupSteps.enumerated()), id: \.element) { index, step in
                Button { model.setupStep = step } label: {
                    HStack(spacing: 9) {
                        Text("\(index + 1)").font(.caption.weight(.semibold))
                            .frame(width: 23, height: 23)
                            .background(Circle().fill(model.setupStep == step ? Color.accentColor : Color.secondary.opacity(0.12)))
                            .foregroundStyle(model.setupStep == step ? Color.white : Color.secondary)
                        Text(step.title).font(.callout.weight(model.setupStep == step ? .semibold : .regular))
                            .foregroundStyle(model.setupStep == step ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(model.setupStep == step ? Color.accentColor.opacity(0.10) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(index + 1): \(step.title)")
                .accessibilityAddTraits(model.setupStep == step ? .isSelected : [])
            }
        }
    }
}

private struct SetupBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if model.setupStep != .connection {
                Button("Back") { model.moveSetup(by: -1) }
            }
            if let problem = model.setupProblems.first {
                Label(problem, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(model.setupStep == .device ? "Review setup" : "Continue") { model.moveSetup(by: 1) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.setupProblems.isEmpty)
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
                    Text("\(model.orderedBatchPorts.count)/\(model.devices.count)").font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .help("Selected boards / detected USB boards")
                }
                Spacer()
                Button { model.probes = [:]; model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Rescan USB devices and read their firmware details.")
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
                        Button("Select all", action: model.selectAllBatch)
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
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Reading device details…") }
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
            VStack(alignment: .leading, spacing: 7) {
                Text("Step \((model.setupSteps.firstIndex(of: model.setupStep) ?? 0) + 1) of \(model.setupSteps.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.setupStep.title).font(.system(size: 24, weight: .semibold))
                Text(model.setupStep.explanation).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch model.setupStep {
            case .connection: connection
            case .route: route
            case .network: network
            case .security: security
            case .device: device
            case .review: review
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connection: some View {
        VStack(spacing: 12) {
            ChoiceCard("Wi-Fi", detail: "Use a 2.4 GHz network or phone hotspot.", icon: "wifi",
                       selected: model.settings.mode == .wifi) { model.setUplink(.wifi) }
            ChoiceCard("LoRa", detail: "Setup only — wireless transmission is not available in the current firmware.",
                       icon: "antenna.radiowaves.left.and.right", selected: model.settings.mode == .lora) { model.setUplink(.lora) }
            if model.settings.mode == .lora { loraNotice }
        }
    }

    private var route: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChoiceCard("Wi-Fi directly to TMedge", detail: "Device → Wi-Fi → TMedge in the cloud. No local gateway needed.",
                       icon: "icloud", selected: model.settings.transport == .wss) { model.settings.transport = .wss }
            ChoiceCard("Wi-Fi through a gateway", detail: "Device → Wi-Fi → TMWAccess gateway → TMedge.",
                       icon: "network", selected: model.settings.transport == .udp) { model.settings.transport = .udp }
            Text("Both options use your Wi-Fi network. Direct means sending straight to the server; it does not create a device hotspot.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.settings.mode == .wifi {
                FormSection("Wi-Fi credentials") {
                    Field("Wi-Fi network", hint: "Choose a 2.4 GHz network, or enter its name manually.") {
                        WiFiSelection(ssid: $model.settings.ssid, discovery: model.wifi)
                    }
                    Field("Wi-Fi password", hint: "Blank keeps the password already saved on the device.") {
                        HStack {
                            Group {
                                if showPassword { TextField("Keep saved password", text: $model.settings.password) }
                                else { SecureField("Keep saved password", text: $model.settings.password) }
                            }
                            RevealButton(on: $showPassword)
                        }
                    }
                }
                FormSection(model.settings.transport == .wss ? "Direct server connection" : "Local gateway connection") {
                    if model.settings.transport == .wss {
                        Field("TMedge device endpoint", hint: "The secure WebSocket endpoint provided by your server administrator.") {
                            TextField("wss://your-server/tmnode", text: $model.settings.cloudURL)
                        }
                    } else {
                        Field("TMWAccess gateway IP", hint: "The gateway’s IPv4 address on the same local network as the device.") {
                            TextField("e.g. 192.0.2.10", text: $model.settings.gateway)
                        }
                    }
                }
                Text("Blank network fields reuse this device’s saved settings. For a new device, enter its network, password and destination.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                loraNotice
                FormSection("LoRa gateway") {
                    Field("TMLAccess gateway IP", hint: "Stored for future LoRa support; this mode currently sends no readings.") {
                        TextField("e.g. 192.0.2.10", text: $model.settings.gateway)
                    }
                }
            }
        }
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormSection("Device authentication") {
                Field("Telemetry signing key", hint: "Must match the signing key configured for this device on TMedge. Blank keeps its saved key.") {
                    HStack {
                        Group {
                            if showKey { TextField("Keep saved key", text: $model.settings.key) }
                            else { SecureField("Keep saved key", text: $model.settings.key) }
                        }
                        RevealButton(on: $showKey)
                    }
                }
                Toggle("Remember password and signing key in this Mac’s Keychain", isOn: $model.rememberSecrets)
                    .font(.callout)
            }
            FormSection("Server verification & adoption") {
                Toggle("Adopt a new device with my algo account", isOn: $model.registerWithEdge)
                if model.registerWithEdge {
                    Field("Algo console URL", hint: "Account access is checked before any device is written.") {
                        TextField("https://algo.hkumyseat.com", text: $model.edgeURL)
                    }
                    Field("Algo account") {
                        HStack {
                            if let session = model.edgeSession, AccountClient.matches(session, url: model.edgeURL) {
                                Label(session.user, systemImage: "person.crop.circle.badge.checkmark")
                                Button("Sign out") { model.signOutAccount() }.controlSize(.small)
                            } else {
                                Button(model.signingIn ? "Signing in…" : "Sign in with algo") { model.signInAccount() }
                                    .disabled(model.signingIn)
                            }
                            Spacer(minLength: 0)
                            Button(model.edgeChecking ? "Checking…" : "Check access") { model.checkEdge() }
                                .disabled(model.edgeChecking || model.signingIn || model.edgeServer == nil)
                        }
                    }
                    if let note = model.edgeCheck {
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Sign in in the browser, then return to TMflash automatically. After setup, match the UID and request code in algo’s Adoption tab to approve the device.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("For devices already approved in TMedge. USB settings are checked, but setup does not request new server approval.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.settings.mode == .wifi && model.settings.transport == .wss {
                Notice(icon: "checkmark.shield", color: .blue,
                       text: "Direct Wi-Fi setup also waits for a fresh report accepted by TMedge. Joining Wi-Fi alone does not pass verification.")
            }
        }
    }

    private var device: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormSection("Polling speed") {
                Field("Thermal frame rate", hint: "Complete thermal frames per second. Keep current leaves the device’s saved rate unchanged.") {
                    Picker("Thermal frame rate", selection: $model.settings.frameRate) {
                        Text("Keep current").tag(Optional<FrameRate>.none)
                        ForEach(FrameRate.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                Text("Changing the rate needs TMsense 1.6 or later. Older devices must be flashed with a firmware source that supports frame-rate selection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            FormSection("Device identity") {
                if model.mode == .single {
                    Field("Device ID", hint: "1–65535. Write this ID on the enclosure; the physical UID stays unchanged.") {
                        TextField("e.g. 3", text: $model.nodeIDText).frame(width: 120)
                    }
                } else {
                    Field("Device ID range", hint: batchHint) {
                        HStack(spacing: 8) {
                            TextField("From", text: $model.startIDText).frame(width: 100)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("To", text: $model.endIDText).frame(width: 100)
                        }
                    }
                }
                Text("Select the USB device\(model.mode == .batch ? "s" : "") on the left. These settings apply to every selected device.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormSection("Your setup") {
                ReviewRow("Connection", value: connectionSummary, step: .connection)
                if model.settings.mode == .wifi {
                    ReviewRow("Network", value: model.settings.ssid.isEmpty ? "Keep saved network" : model.settings.ssid, step: .network)
                    ReviewRow("Destination", value: destinationSummary, step: .network)
                    ReviewRow("Wi-Fi password", value: model.settings.password.isEmpty ? "Keep saved password" : "New password supplied", step: .network)
                } else {
                    ReviewRow("Gateway", value: model.settings.gateway.isEmpty ? "Keep saved gateway" : model.settings.gateway, step: .network)
                }
                ReviewRow("Signing key", value: model.settings.key.isEmpty ? "Keep saved key" : "New key supplied", step: .security)
                ReviewRow("Approval", value: model.registerWithEdge ? "Request adoption via algo account" : "Keep existing server approval", step: .security)
                ReviewRow("Frame rate", value: model.settings.frameRate?.title ?? "Keep current", step: .device)
                ReviewRow("Device IDs", value: deviceSummary, step: .device)
            }
            FormSection("What to write") {
                Picker("Write operation", selection: $model.flashFirmware) {
                    Text("Firmware + settings").tag(true)
                    Text("Settings only").tag(false)
                }.pickerStyle(.segmented).labelsHidden()
                if model.flashFirmware {
                    HStack {
                        Text(model.firmwareVersion ?? "No firmware source selected").font(.callout.monospaced())
                        Spacer()
                        Button("Choose firmware folder…") { model.chooseProject() }
                    }
                    if let path = model.projectDir {
                        DisclosureGroup("Firmware source location") {
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.font(.caption)
                    }
                } else {
                    Text("Update a device that already runs TMsense. Unsupported commands are refused before settings are written.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.settings.mode == .lora { loraNotice }
            if !model.blockers.isEmpty {
                Notice(icon: "info.circle", color: .orange, text: model.blockers.joined(separator: "\n"))
            }
            Text("Saved settings and the boot counter survive firmware flashing. Passwords and signing keys stay out of logs and the manifest.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loraNotice: some View {
        Notice(icon: "antenna.radiowaves.left.and.right", color: .orange,
               text: "LoRa transmission is not implemented in TMsense yet. This setup only stores the mode and gateway address; the device will send no readings. Choose Wi-Fi for a working connection.")
    }

    private var connectionSummary: String {
        model.settings.mode == .lora ? "LoRa — setup only" : model.settings.transport == .wss ? "Wi-Fi directly to TMedge" : "Wi-Fi through TMWAccess"
    }
    private var destinationSummary: String {
        let value = model.settings.transport == .wss ? model.settings.cloudURL : model.settings.gateway
        return value.isEmpty ? "Keep saved destination" : value
    }
    private var deviceSummary: String {
        if case .success(let jobs) = model.plan, let first = jobs.first, let last = jobs.last {
            return jobs.count == 1 ? "\(first.nodeID)" : "\(first.nodeID)–\(last.nodeID) (\(jobs.count) devices)"
        }
        return "Needs a device and valid ID\(model.mode == .batch ? " range" : "")"
    }
    private var batchHint: String {
        let n = model.orderedBatchPorts.count
        return n == 0 ? "Select devices on the left. IDs are assigned in list order." : "\(n) selected devices need exactly \(n) IDs, assigned in list order."
    }
}

private struct ChoiceCard: View {
    let title: String
    let detail: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    init(_ title: String, detail: String, icon: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.icon = icon; self.selected = selected; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 28).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ReviewRow: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let value: String
    let step: SetupStep
    init(_ label: String, value: String, step: SetupStep) { self.label = label; self.value = value; self.step = step }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Button("Edit") { model.setupStep = step }.buttonStyle(.link)
                .accessibilityLabel("Edit \(label)")
        }.font(.callout)
    }
}

private struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
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
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            content.textFieldStyle(.roundedBorder)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
            Button("Back") { model.moveSetup(by: -1) }
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
