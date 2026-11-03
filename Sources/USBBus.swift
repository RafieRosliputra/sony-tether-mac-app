import Foundation
import IOKit

/// USB device present on the Mac's bus, as far as IOKit is concerned.
struct USBDevice {
    let vendorID: Int
    let productID: Int
    let product: String

    var hexIDs: String { String(format: "%04x:%04x", vendorID, productID) }
}

/// Used only for diagnostics: distinguishes "nothing plugged in" from
/// "the body is on USB but libgphoto2 could not claim it".
enum USBBus {
    /// Sony's USB vendor id.
    static let sonyVendorID = 0x054C

    static func devices() -> [USBDevice] {
        var found: [USBDevice] = []
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return found }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return found
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            let vid = props["idVendor"] as? Int ?? 0
            let pid = props["idProduct"] as? Int ?? 0
            let name = (props["USB Product Name"] as? String)
                ?? (props["USB Vendor Name"] as? String)
                ?? ""
            found.append(USBDevice(vendorID: vid, productID: pid, product: name))
        }
        return found
    }

    static func sonyDevices() -> [USBDevice] {
        devices().filter { $0.vendorID == sonyVendorID }
    }
}
