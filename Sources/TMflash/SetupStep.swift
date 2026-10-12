import Foundation

enum SetupStep: String, CaseIterable, Identifiable {
    case connection, route, network, security, device, review
    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "Connection mode"
        case .route: return "Wi-Fi destination"
        case .network: return "Network settings"
        case .security: return "Security & verification"
        case .device: return "Speed & device ID"
        case .review: return "Review & flash"
        }
    }

    var explanation: String {
        switch self {
        case .connection: return "Choose how the device sends its readings."
        case .route: return "Send directly to TMedge, or through a gateway at your site."
        case .network: return "Enter the network details for the connection you selected."
        case .security: return "Set the device’s signing key and choose how it is approved in algo."
        case .device: return "Choose the thermal frame rate, then assign the device ID."
        case .review: return "Check your choices before writing to the selected USB devices."
        }
    }
}
