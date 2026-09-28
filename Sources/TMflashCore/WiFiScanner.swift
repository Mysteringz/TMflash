import CoreWLAN
import Foundation

public enum WiFiBand: Sendable, Equatable {
    case twoGHz, fiveGHz, sixGHz, unknown

    public var usableByTMsense: Bool { self == .twoGHz }

    public var label: String {
        switch self {
        case .twoGHz: return "2.4 GHz"
        case .fiveGHz: return "5 GHz"
        case .sixGHz: return "6 GHz"
        case .unknown: return "band unknown"
        }
    }
}

public struct WiFiNetwork: Equatable, Identifiable, Sendable {
    public let ssid: String
    public let rssi: Int
    public let band: WiFiBand
    // SSIDs are bytes: canonically equivalent Unicode names can be different networks.
    public var id: Data { Data(ssid.utf8) }

    public init(ssid: String, rssi: Int, band: WiFiBand = .twoGHz) {
        self.ssid = ssid
        self.rssi = rssi
        self.band = band
    }
}

public struct WiFiAccessPoint: Sendable {
    public let ssid: Data?
    public let rssi: Int
    public let band: WiFiBand

    public init(ssid: Data?, rssi: Int, is2GHz: Bool) {
        self.init(ssid: ssid, rssi: rssi, band: is2GHz ? .twoGHz : .fiveGHz)
    }

    public init(ssid: Data?, rssi: Int, band: WiFiBand) {
        self.ssid = ssid
        self.rssi = rssi
        self.band = band
    }
}

public enum WiFiScanError: LocalizedError {
    case noInterface, poweredOff, namesUnavailable

    public var errorDescription: String? {
        switch self {
        case .noInterface: return "No Wi-Fi adapter found on this Mac. Enter the SSID manually."
        case .poweredOff: return "Turn on this Mac’s Wi-Fi and scan again, or enter the SSID manually."
        case .namesUnavailable:
            return "Network names are unavailable. Allow TMflash in System Settings → Privacy & Security → Location Services, then scan again."
        }
    }
}

public enum WiFiScanner {
    /// CoreWLAN's scan blocks for several seconds; callers must run it off the UI thread.
    public static func scan() throws -> [WiFiNetwork] {
        guard let interface = CWWiFiClient.shared().interface() else { throw WiFiScanError.noInterface }
        guard interface.powerOn() else { throw WiFiScanError.poweredOff }
        let networks = try interface.scanForNetworks(withSSID: nil)
        if !networks.isEmpty && networks.allSatisfy({ $0.ssidData == nil }) {
            throw WiFiScanError.namesUnavailable
        }
        return choices(from: networks.map {
            let band: WiFiBand
            switch $0.wlanChannel?.channelBand {
            case .band2GHz: band = .twoGHz
            case .band5GHz: band = .fiveGHz
            case .band6GHz: band = .sixGHz
            default: band = .unknown
            }
            return WiFiAccessPoint(ssid: $0.ssidData, rssi: $0.rssiValue, band: band)
        })
    }

    public static func choices(from accessPoints: [WiFiAccessPoint]) -> [WiFiNetwork] {
        var strongest: [Data: WiFiNetwork] = [:]
        // Prefer a 2.4 GHz AP even if its 5 GHz sibling is stronger. A 5 GHz-only
        // hotspot remains visible so the operator knows to change its band.
        for ap in accessPoints {
            guard let bytes = ap.ssid, !bytes.isEmpty,
                  let ssid = String(data: bytes, encoding: .utf8),
                  !ssid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  NodeSettings(ssid: ssid).problems().isEmpty else { continue }
            if let previous = strongest[bytes] {
                if previous.band.usableByTMsense && !ap.band.usableByTMsense { continue }
                if previous.band.usableByTMsense == ap.band.usableByTMsense && previous.rssi >= ap.rssi { continue }
            }
            strongest[bytes] = WiFiNetwork(ssid: ssid, rssi: ap.rssi, band: ap.band)
        }
        return strongest.values.sorted {
            if $0.band.usableByTMsense != $1.band.usableByTMsense { return $0.band.usableByTMsense }
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.id.lexicographicallyPrecedes($1.id)
        }
    }
}
