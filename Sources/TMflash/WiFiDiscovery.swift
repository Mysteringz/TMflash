import CoreLocation
import Foundation
import SwiftUI
import TMflashCore

@MainActor
final class WiFiDiscovery: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle, requestingPermission, scanning, ready, failed(String)
    }

    @Published var networks: [WiFiNetwork] = []
    @Published var state: State = .idle

    private let live: Bool
    private let scanNetworks: @Sendable () throws -> [WiFiNetwork]
    private var requestedScan = false
    private var scanID: UUID?
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    init(live: Bool, scanNetworks: @escaping @Sendable () throws -> [WiFiNetwork] = { try WiFiScanner.scan() }) {
        self.live = live
        self.scanNetworks = scanNetworks
        super.init()
    }

    var isBusy: Bool { state == .scanning || state == .requestingPermission }

    var message: String {
        switch state {
        case .idle: return "Scan nearby Wi-Fi networks using this Mac."
        case .requestingPermission: return "Allow Location Services in the macOS prompt to see network names."
        case .scanning: return "Scanning for Wi-Fi networks…"
        case .ready:
            let usable = networks.filter { $0.band.usableByTMsense }.count
            let unavailable = networks.count - usable
            if usable == 0 && unavailable == 0 { return "No Wi-Fi networks found. For a phone hotspot, check its 2.4 GHz setting, rescan, or enter an SSID manually." }
            if usable == 0 { return "No usable 2.4 GHz networks; \(unavailable) other network\(unavailable == 1 ? " is" : "s are") shown but unavailable to TMsense." }
            if unavailable > 0 { return "\(usable) usable 2.4 GHz network\(usable == 1 ? "" : "s"); \(unavailable) other network\(unavailable == 1 ? "" : "s") shown but unavailable." }
            return "\(usable) nearby 2.4 GHz network\(usable == 1 ? "" : "s"), strongest first."
        case .failed(let reason): return reason
        }
    }

    func scanIfAuthorized() {
        guard live, state == .idle, hasUsageDescription else { return }
        if locationManager.authorizationStatus == .authorizedAlways {
            scan()
        }
    }

    func scan() {
        guard live, !isBusy else { return }
        guard hasUsageDescription else {
            state = .failed("Open the built TMflash.app to allow Wi-Fi scanning, or enter the SSID manually.")
            return
        }
        requestedScan = true
        if locationManager.authorizationStatus == .notDetermined {
            state = .requestingPermission
            locationManager.requestWhenInUseAuthorization()
        } else {
            updateAuthorization(locationManager.authorizationStatus)
        }
    }

    private var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self, requestedScan else { return }
            updateAuthorization(status)
        }
    }

    // Kept separate from the OS callback so permission changes during a scan can be tested.
    func updateAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            guard state != .scanning else { return }
            state = .scanning
            networks = []
            let id = UUID()
            scanID = id
            let scanNetworks = self.scanNetworks
            Task {
                let result = await Task.detached(priority: .userInitiated) { Result { try scanNetworks() } }.value
                // Revoking permission invalidates an in-flight result as well as the visible list.
                guard scanID == id else { return }
                switch result {
                case .success(let found):
                    networks = found
                    state = .ready
                case .failure(let error):
                    state = .failed(error.localizedDescription)
                }
            }
        case .denied, .restricted:
            scanID = nil
            networks = []
            state = .failed("Allow TMflash in System Settings → Privacy & Security → Location Services, then scan again. You can also enter the SSID manually.")
        case .notDetermined: break
        @unknown default:
            scanID = nil
            networks = []
            state = .failed("Wi-Fi scanning is unavailable. Enter the SSID manually.")
        }
    }
}
