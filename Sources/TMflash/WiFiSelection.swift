import SwiftUI
import TMflashCore

struct WiFiSelection: View {
    @Binding var ssid: String
    @ObservedObject var discovery: WiFiDiscovery
    @State private var manualEntry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    Button("Keep node’s current network") { ssid = ""; manualEntry = false }
                    if !discovery.networks.isEmpty { Divider() }
                    ForEach(discovery.networks) { network in
                        Button("\(network.ssid)  (\(network.rssi) dBm)") {
                            ssid = network.ssid
                            manualEntry = false
                        }
                    }
                    Divider()
                    Button("Other / hidden network…") { manualEntry = true }
                } label: {
                    Text(ssid.isEmpty ? "Keep node’s current" : ssid)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(ssid.isEmpty ? "Choose a scanned network or keep the node’s saved SSID" : ssid)
                .accessibilityLabel("Wi-Fi network")
                Button(discovery.state == .idle ? "Scan" : "Rescan") { discovery.scan() }
                    .disabled(discovery.isBusy)
            }
            if manualEntry {
                TextField("SSID (blank keeps node’s current)", text: $ssid)
                    .accessibilityLabel("Manual Wi-Fi SSID")
            } else {
                Button("Enter SSID manually…") { manualEntry = true }
                    .buttonStyle(.link).font(.caption)
            }
            HStack(alignment: .top, spacing: 6) {
                if discovery.isBusy { ProgressView().controlSize(.small) }
                Text(discovery.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 260, alignment: .leading)
        .onAppear { discovery.scanIfAuthorized() }
    }
}
