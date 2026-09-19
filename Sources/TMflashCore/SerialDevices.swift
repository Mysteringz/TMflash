import Foundation
import IOKit
import IOKit.serial

/// A USB serial device that may be a TMsense board.
public struct SerialDevice: Identifiable, Hashable, Sendable {
    /// Callout path, e.g. /dev/cu.usbserial-0001.
    public let path: String
    public let vendorID: Int?
    public let productID: Int?
    public let product: String?
    public let vendor: String?
    public let serialNumber: String?
    /// USB location: one physical board, however many drivers expose it.
    public let locationID: Int?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent.replacingOccurrences(of: "cu.", with: "") }

    public init(path: String, vendorID: Int? = nil, productID: Int? = nil, product: String? = nil, vendor: String? = nil,
                serialNumber: String? = nil, locationID: Int? = nil) {
        self.path = path
        self.vendorID = vendorID
        self.productID = productID
        self.product = product
        self.vendor = vendor
        self.serialNumber = serialNumber
        self.locationID = locationID
    }

    /// The USB-to-UART bridges ESP32 boards carry. The Heltec V3 has a CP2102.
    public var bridge: String? {
        switch (vendorID, productID) {
        case (0x10C4?, _): return "Silicon Labs CP210x"
        case (0x1A86?, _): return "WCH CH34x"
        case (0x303A?, _): return "Espressif native USB"
        case (0x0403?, _): return "FTDI"
        default: return nil
        }
    }

    /// True for boards that look like an ESP32 (and so possibly a TMsense).
    public var looksLikeESP32: Bool { bridge != nil }

    public var summary: String {
        [bridge ?? product ?? vendor ?? "USB serial", serialNumber.map { "S/N \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

public enum SerialDevices {
    /// USB serial ports, one per physical board. Bluetooth and the debug
    /// console are not USB and are left out.
    public static func list() -> [SerialDevice] {
        dedupe(scan())
    }

    /// Some bridges show up twice (Apple's driver as cu.usbserial-*, the
    /// vendor's as cu.SLAB_USBtoUART). Flashing "both" would open one board
    /// twice, so keep one path per USB location, preferring Apple's.
    static func dedupe(_ all: [SerialDevice]) -> [SerialDevice] {
        var byLocation: [Int: SerialDevice] = [:]
        var loose: [SerialDevice] = []
        for d in all {
            guard let loc = d.locationID else { loose.append(d); continue }
            if let have = byLocation[loc] {
                if rank(d) < rank(have) { byLocation[loc] = d }
            } else {
                byLocation[loc] = d
            }
        }
        return (Array(byLocation.values) + loose).sorted { $0.path < $1.path }
    }

    private static func rank(_ d: SerialDevice) -> Int {
        if d.name.hasPrefix("usbserial") || d.name.hasPrefix("usbmodem") { return 0 }
        if d.name.hasPrefix("wchusbserial") { return 1 }
        return 2
    }

    private static func scan() -> [SerialDevice] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else { return [] }
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [SerialDevice] = []
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            func find(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard let vid = find("idVendor") as? Int else { continue }   // not USB
            out.append(SerialDevice(
                path: path,
                vendorID: vid,
                productID: find("idProduct") as? Int,
                product: (find("USB Product Name") ?? find("kUSBProductString")) as? String,
                vendor: (find("USB Vendor Name") ?? find("kUSBVendorString")) as? String,
                serialNumber: (find("USB Serial Number") ?? find("kUSBSerialNumberString")) as? String,
                locationID: find("locationID") as? Int))
        }
        return out
    }
}
