import Foundation
import IOKit

/// Read-only transport observation. Never opens the USB device exclusively or
/// writes firmware/EDID. Unknown/ambiguous registry values remain unknown.
enum CaptureCardUSB {
    static func linkGbps(deviceName: String) -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var values: [Double] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let name = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard name == deviceName else { continue }
            guard let speed = IORegistryEntryCreateCFProperty(service, "UsbLinkSpeed" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                  speed.doubleValue > 0 else { continue }
            values.append(speed.doubleValue / 1_000_000_000)
        }
        return values.count == 1 ? values[0] : nil
    }
}
