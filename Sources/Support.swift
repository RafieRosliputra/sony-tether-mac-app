import Foundation
import GPhoto2

/// Result helper: turn a libgphoto2 return code into a readable string.
func gpErrorText(_ code: Int32) -> String {
    if let c = gp_result_as_string(code) {
        return "\(String(cString: c)) (code \(code))"
    }
    return "unknown error (code \(code))"
}

/// Copy a fixed-size C char array (tuple) held in a struct into a Swift String.
func fixedCString<T>(_ value: inout T) -> String {
    withUnsafePointer(to: &value) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cstr in
            String(cString: cstr)
        }
    }
}

/// Read the C string starting at `offset` inside a struct field.
func fixedCString<T>(_ value: inout T, offset: Int) -> String {
    withUnsafePointer(to: &value) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cstr in
            String(cString: cstr.advanced(by: offset))
        }
    }
}

/// Generic helper for libgphoto2's `const char **` out-parameters.
func widgetString(_ get: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32) -> String? {
    var out: UnsafePointer<CChar>? = nil
    if get(&out) == 0, let out {
        let s = String(cString: out)
        return s.isEmpty ? nil : s
    }
    return nil
}

enum AppInfo {
    static let name = "sonyTether"
    static let version = "0.3.0"
    static let build = "1"
    static let bundleID = "com.johorstudio.sonytether"
    static let repoURL = "https://github.com/RafieRosliputra/sony-tether-mac-app"
}

enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func bytes(_ n: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(n)
        var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
    }

    static func ms(_ d: Double) -> String {
        d < 1000 ? String(format: "%.0f ms", d) : String(format: "%.2f s", d / 1000)
    }
}
