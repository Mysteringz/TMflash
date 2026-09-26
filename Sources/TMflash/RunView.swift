import SwiftUI
import TMflashCore

struct RunView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Summary()
                    if model.phase == .building || model.buildError != nil { BuildCard() }
                    ForEach(model.rows) { JobCard(row: $0) }
                }
                .padding(22)
            }
            Divider()
            HStack {
                if model.phase == .finished {
                    Button("Show manifest") { model.revealManifest() }
                        .help("CSV of every node flashed: ID, MAC, gateway — for TMedge's nodes.json")
                    Spacer()
                    Button { model.backToSetup() } label: { Text("Flash more").frame(minWidth: 120).padding(.vertical, 4) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                } else {
                    Text("Keep the boards plugged in until they are done.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancel() }.controlSize(.large)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
    }
}

private struct Summary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            icon.font(.system(size: 28))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .finished where model.buildError != nil || model.failed > 0:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .finished where model.rows.contains { $0.result?.edgeAccepted == false }:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default: ProgressView().controlSize(.regular)
        }
    }

    private var title: String {
        switch model.phase {
        case .building: return "Building firmware…"
        case .flashing: return model.rows.count == 1 ? "Setting up node #\(model.rows[0].nodeID)…" : "Setting up \(model.rows.count) nodes…"
        case .finished:
            if model.buildError != nil { return "Firmware build failed" }
            // A direct-cloud node TMedge has not heard from is set up, not ready:
            // it is delivering no occupancy, and the headline must not say otherwise.
            let unheard = model.rows.filter { $0.result?.edgeAccepted == false }.count
            if model.failed == 0 && unheard > 0 {
                return model.rows.count == 1 ? "Node #\(model.rows[0].nodeID) is set up, but TMedge has not heard from it"
                                             : "\(model.rows.count) nodes set up, \(unheard) not yet heard by TMedge"
            }
            if model.failed == 0 { return model.rows.count == 1 ? "Node #\(model.rows[0].nodeID) is ready" : "All \(model.rows.count) nodes are ready" }
            return "\(model.succeeded) of \(model.rows.count) ready, \(model.failed) failed"
        case .setup: return ""
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .building: return "PlatformIO is compiling TMsense \(model.firmwareVersion ?? "") — the first build downloads the ESP32 toolchain."
        case .flashing: return "Writing firmware, then settings, then checking each node joins its network."
        case .finished:
            if model.buildError != nil { return "Nothing was written to any board." }
            return "Each result was added to the manifest."
        case .setup: return ""
        }
    }
}

private struct BuildCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = model.buildError {
                Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            }
            LogBox(lines: model.buildLog, height: 160)
        }
        .card()
    }
}

private struct JobCard: View {
    let row: AppModel.Row
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                statusIcon.font(.system(size: 20)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Node #\(row.nodeID)").font(.headline)
                        Text(row.name).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Text(row.result.map { $0.ok ? "Done" : "Failed" } ?? row.stage.label)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(row.result?.ok == false ? .red : .secondary)
            }
            if row.result == nil {
                if case .flashing(let p) = row.stage {
                    ProgressView(value: p)
                } else if row.stage != .queued {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if let r = row.result {
                if let e = r.error { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                ForEach(r.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            DisclosureGroup(isExpanded: $expanded) {
                LogBox(lines: row.log, height: 140)
            } label: {
                Text("Log").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var detail: String {
        var parts: [String] = []
        if let uid = row.result?.uid { parts.append(uid) }
        if let fw = row.result?.firmware { parts.append(fw) }
        if let ip = row.result?.wifiIP { parts.append("on Wi-Fi as \(ip)") }
        // Separate facts: a Wi-Fi lease says nothing about TMedge.
        if let accepted = row.result?.edgeAccepted { parts.append(accepted ? "TMedge accepted its reports" : "TMedge has not accepted a report") }
        if parts.isEmpty { return row.result == nil ? "In progress" : "Not set up" }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusIcon: some View {
        if let r = row.result {
            if !r.ok { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            else if !r.warnings.isEmpty { Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange) }
            else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        } else if row.stage == .queued {
            Image(systemName: "clock").foregroundStyle(.secondary)
        } else {
            Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(Color.accentColor)
        }
    }
}

struct LogBox: View {
    let lines: [String]
    let height: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .onChange(of: lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
    }
}

extension View {
    func card() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
    }
}
