//
//  USBInventory.swift
//  Diagnostics: lists the USB devices and interfaces iPadOS has enumerated, so the camera's
//  vendor/product IDs can be read without a Mac (the iPad's only port is taken by the camera).
//  Also written to Documents/usb-devices.txt.
//

import Foundation

enum USBInventory {
    static func snapshot() -> [String] {
        var lines: [String] = []
        for className in ["IOUSBHostDevice", "IOUSBHostInterface"] {
            var iterator: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
            guard kr == KERN_SUCCESS else {
                lines.append(String(format: "%@: lookup failed 0x%08x", className, UInt32(bitPattern: kr)))
                continue
            }
            var count = 0
            while case let service = IOIteratorNext(iterator), service != 0 {
                count += 1
                lines.append(describe(service, isInterface: className == "IOUSBHostInterface"))
                IOObjectRelease(service)
            }
            IOObjectRelease(iterator)
            if count == 0 { lines.append("\(className): none visible") }
        }
        let driver = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("U3VDriver"))
        lines.append(driver != 0 ? "U3VDriver: running" : "U3VDriver: not running")
        if driver != 0 { IOObjectRelease(driver) }
        return lines
    }

    static func write(_ lines: [String]) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let text = "\(Date())\n" + lines.joined(separator: "\n") + "\n"
        try? text.write(to: docs.appendingPathComponent("usb-devices.txt"), atomically: true, encoding: .utf8)
    }

    private static func describe(_ service: io_service_t, isInterface: Bool) -> String {
        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }
        func string(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        }
        var name = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &name)
        let vid = number("idVendor").map { String(format: "0x%04X (%d)", $0, $0) } ?? "?"
        let pid = number("idProduct").map { String(format: "0x%04X", $0) } ?? "?"
        let prefix = isInterface ? "bInterface" : "bDevice"
        let cls = [number("\(prefix)Class"), number("\(prefix)SubClass"), number("\(prefix)Protocol")]
            .map { $0.map { String(format: "%02X", $0) } ?? "?" }.joined(separator: "/")
        let label = string("USB Product Name") ?? String(cString: name)
        let vendor = string("USB Vendor Name") ?? string("kUSBVendorString") ?? ""
        var all: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &all, kCFAllocatorDefault, 0)
        let keys = (all?.takeRetainedValue() as? [String: Any])?.keys.sorted().joined(separator: ",") ?? ""
        let props = kr == KERN_SUCCESS ? "props[\(keys)]" : String(format: "props denied 0x%08x", UInt32(bitPattern: kr))
        var children: [String] = []
        var childIterator: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(service, "IOService", &childIterator) == KERN_SUCCESS {
            while case let child = IOIteratorNext(childIterator), child != 0 {
                var childName = [CChar](repeating: 0, count: 128)
                var childClass = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(child, &childName)
                IOObjectGetClass(child, &childClass)
                children.append("\(String(cString: childName))<\(String(cString: childClass))>")
                IOObjectRelease(child)
            }
            IOObjectRelease(childIterator)
        }
        let attached = isInterface ? " attached[\(children.joined(separator: ","))]" : ""
        return "\(isInterface ? "  if" : "dev") \(label) \(vendor) vid \(vid) pid \(pid) class \(cls) \(props)\(attached)"
    }
}
