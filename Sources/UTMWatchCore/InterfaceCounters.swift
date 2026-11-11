import CSysShim
import Foundation

public struct InterfaceCounter: Equatable {
    public var name: String
    public var index: UInt32
    public var ibytes: UInt64
    public var obytes: UInt64
    public init(name: String, index: UInt32, ibytes: UInt64, obytes: UInt64) {
        self.name = name; self.index = index; self.ibytes = ibytes; self.obytes = obytes
    }
}

public enum InterfaceList {
    private final class Box { var items: [String: InterfaceCounter] = [:] }

    /// 64-bit byte counters for every interface (NET_RT_IFLIST2 / if_data64).
    public static func read() -> [String: InterfaceCounter] {
        let box = Box()
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        _ = shim_iflist2({ cName, index, ibytes, obytes, ctx in
            guard let cName, let ctx else { return }
            let name = String(cString: cName)
            Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().items[name] =
                InterfaceCounter(name: name, index: index, ibytes: ibytes, obytes: obytes)
        }, ctx)
        return box.items
    }
}

public struct InterfaceRate: Equatable {
    public var ibytesPerSecond: Double
    public var obytesPerSecond: Double
}

/// Rates from consecutive counter readings, dropping samples after a counter reset or interface rebuild.
public final class InterfaceRateTracker {
    private var previous: [String: (counter: InterfaceCounter, wall: UInt64)] = [:]

    public init() {}

    public static func rate(previous: InterfaceCounter, previousWall: UInt64,
                            current: InterfaceCounter, currentWall: UInt64) -> InterfaceRate? {
        guard current.index == previous.index,
              currentWall > previousWall,
              current.ibytes >= previous.ibytes, current.obytes >= previous.obytes else { return nil }
        let seconds = Double(currentWall - previousWall) / 1e9
        return InterfaceRate(ibytesPerSecond: Double(current.ibytes - previous.ibytes) / seconds,
                             obytesPerSecond: Double(current.obytes - previous.obytes) / seconds)
    }

    public func update(_ counters: [String: InterfaceCounter], now: UInt64) -> [String: InterfaceRate] {
        var rates: [String: InterfaceRate] = [:]
        for (name, cur) in counters {
            if let prev = previous[name],
               let r = Self.rate(previous: prev.counter, previousWall: prev.wall, current: cur, currentWall: now) {
                rates[name] = r
            }
            previous[name] = (cur, now)
        }
        for name in previous.keys where counters[name] == nil { previous[name] = nil }
        return rates
    }
}
