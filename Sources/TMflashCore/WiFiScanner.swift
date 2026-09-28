import CoreWLAN
import Foundation

public struct WiFiNetwork: Equatable, Identifiable, Sendable {
    public let ssid: String
    public let rssi: Int
    // SSIDs are bytes: canonically equivalent Unicode names can be different networks.
    public var id: Data { Data(ssid.utf8) }

    public init(ssid: String, rssi: Int) {
        self.ssid = ssid
        self.rssi = rssi
    }
}

public struct WiFiAccessPoint: Sendable {
    public let ssid: Data?
    public let rssi: Int
    public let is2GHz: Bool

    public init(ssid: Data?, rssi: Int, is2GHz: Bool) {
        self.ssid = ssid
        self.rssi = rssi
        self.is2GHz = is2GHz
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
            WiFiAccessPoint(ssid: $0.ssidData, rssi: $0.rssiValue, is2GHz: $0.wlanChannel?.channelBand == .band2GHz)
        })
    }

    public static func choices(from accessPoints: [WiFiAccessPoint]) -> [WiFiNetwork] {
        var strongest: [Data: WiFiNetwork] = [:]
        // Filter before deduplicating: a stronger 5 GHz AP must not hide its 2.4 GHz sibling.
        for ap in accessPoints where ap.is2GHz {
            guard let bytes = ap.ssid, !bytes.isEmpty,
                  let ssid = String(data: bytes, encoding: .utf8),
                  !ssid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  NodeSettings(ssid: ssid).problems().isEmpty else { continue }
            if let previous = strongest[bytes], previous.rssi >= ap.rssi { continue }
            strongest[bytes] = WiFiNetwork(ssid: ssid, rssi: ap.rssi)
        }
        return strongest.values.sorted {
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.id.lexicographicallyPrecedes($1.id)
        }
    }
}
