import Foundation
import Darwin

// Public routing sysctl exposes if_data64. getifaddrs/if_data has only
// 32-bit byte counters, even when its fields are converted to UInt64.
enum InterfaceCounters {
    struct Counter: Codable, Hashable {
        var received: UInt64
        var sent: UInt64
    }

    struct Reading {
        var wifi: [String: Counter]
        var cellular: [String: Counter]
        var bits: Int
    }

    static func read() -> Reading? {
        if let wide = read64() { return wide }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var result = Reading(wifi: [:], cellular: [:], bits: 32)
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee
            defer { cursor = item.ifa_next }
            guard item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let raw = item.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            insert(name: String(cString: item.ifa_name),
                   counter: Counter(received: UInt64(data.ifi_ibytes), sent: UInt64(data.ifi_obytes)),
                   into: &result)
        }
        return result
    }

    private static func read64() -> Reading? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        let mibCount = u_int(mib.count)
        // Interfaces can change between the sizing call and the read.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, mibCount, nil, &size, nil, 0) == 0,
                  size > 0 else { return nil }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            defer { buffer.deallocate() }
            guard sysctl(&mib, mibCount, buffer, &size, nil, 0) == 0 else { continue }
            var result = Reading(wifi: [:], cellular: [:], bits: 64)
            var offset = 0
            var found = false
            while offset + 4 <= size {
                let message = buffer.advanced(by: offset)
                // Copy rather than assume message alignment.
                var length: UInt16 = 0
                memcpy(&length, message, 2)
                let count = Int(length)
                guard count >= 4, count <= size - offset else { return nil }
                let type = message.load(fromByteOffset: 3, as: UInt8.self)
                if type == UInt8(RTM_IFINFO2), count >= MemoryLayout<if_msghdr2>.size {
                    var header = if_msghdr2()
                    withUnsafeMutableBytes(of: &header) { target in
                        _ = memcpy(target.baseAddress!, message, target.count)
                    }
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(header.ifm_index), &name) != nil {
                        found = true
                        insert(name: String(cString: name),
                               counter: Counter(received: header.ifm_data.ifi_ibytes,
                                                sent: header.ifm_data.ifi_obytes), into: &result)
                    }
                }
                offset += count
            }
            return found ? result : nil
        }
        return nil
    }

    private static func insert(name: String, counter: Counter, into result: inout Reading) {
        if name == "en0" { result.wifi[name] = counter }
        else if name.hasPrefix("pdp_ip") { result.cellular[name] = counter }
        // utun is deliberately excluded: VPN traffic already crosses en0/pdp_ip.
    }

    static func bootTime() -> TimeInterval? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return nil }
        return Double(value.tv_sec)
    }

    static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    static func difference(current: UInt64, previous: UInt64, bits: Int) -> UInt64 {
        if current >= previous { return current - previous }
        // Only infer wrap near the end of a 32-bit counter. A small counter
        // regression is an interface reset; keep its post-reset bytes.
        if bits == 32, previous >= 3_750_000_000, current <= 536_870_912 {
            return (UInt64(UInt32.max) - previous) + 1 + current
        }
        return current
    }
}
