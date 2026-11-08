import Darwin
import Foundation
import Network

/// A network interface name paired with one of its IPv4 addresses.
struct InterfaceAddress: Equatable {
    var name: String
    var ipv4: String
}

/// Finds this Mac's tailnet address by enumerating network interfaces.
///
/// Tailscale.app doesn't always come with the `tailscale` CLI, so there may
/// be no `tailscale ip` to shell out to. Tailscale still assigns the device
/// an address in its CGNAT range on a `utun*` interface, so we read it from
/// `getifaddrs` directly.
enum TailscaleInterface {
    /// A MagicDNS name such as "studio.tail1234.ts.net". Letters, digits,
    /// hyphens and dots only: this text becomes a URL's authority, where a
    /// "/" or "?" would leave ".ts.net" in the path and the host anywhere.
    static func isTailnetName(_ host: String) -> Bool {
        let name = host.lowercased()
        guard name.hasSuffix(".ts.net"), name.count > ".ts.net".count, name.utf8.count < 254 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    /// Whether `ipv4` falls inside 100.64.0.0/10, the CGNAT range Tailscale
    /// uses for tailnet addresses.
    static func isTailscaleAddress(_ ipv4: String) -> Bool {
        let octets = ipv4.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }

        var bytes = [UInt8]()
        bytes.reserveCapacity(4)
        for octet in octets {
            guard let value = UInt8(octet) else { return false }
            bytes.append(value)
        }

        // 100.64.0.0/10 spans second octets 64...127.
        return bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    /// Picks the tailnet address out of a list of candidate interfaces.
    ///
    /// Only 100.64.0.0/10 addresses qualify. Among those, interfaces named
    /// `utun*` are preferred (that's how Tailscale's userspace network
    /// extension presents itself); if none qualify, or several tie, the
    /// lowest interface name wins so the result is deterministic. Returns
    /// nil when nothing in the list is in range.
    static func select(from interfaces: [InterfaceAddress]) -> String? {
        let candidates = interfaces.filter { isTailscaleAddress($0.ipv4) }
        guard !candidates.isEmpty else { return nil }

        let utunCandidates = candidates.filter { $0.name.hasPrefix("utun") }
        let pool = utunCandidates.isEmpty ? candidates : utunCandidates

        return pool.min { $0.name < $1.name }?.ipv4
    }

    /// Live IPv4 interface enumeration via `getifaddrs`.
    static func currentInterfaces() -> [InterfaceAddress] {
        var result = [InterfaceAddress]()

        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let first = firstAddress else {
            return result
        }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            guard let addr = interface.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var addrIn = UnsafeRawPointer(addr).load(as: sockaddr_in.self)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let presentation = withUnsafePointer(to: &addrIn.sin_addr) { addrPointer in
                inet_ntop(AF_INET, addrPointer, &buffer, socklen_t(buffer.count))
            }
            guard presentation != nil else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            let ipv4 = String(cString: buffer)
            result.append(InterfaceAddress(name: name, ipv4: ipv4))
        }

        return result
    }

    /// The tailnet address for this Mac, or nil if it can't be found.
    static func currentAddress() -> String? {
        select(from: currentInterfaces())
    }
}

/// Notices when this Mac's tailnet address appears, changes or goes away, so
/// a main Mac that started before Tailscale was up can begin listening as
/// soon as it is. Event-driven: a network path monitor reports interface
/// changes. While a retry is still needed (`needsRetry`), a timer with a
/// bounded back-off covers a monitor update that never comes. It only reads
/// the address; binding stays with whoever handles `onChange`, which must use
/// the address it is given (or `TailscaleInterface.currentAddress()`) and
/// nothing else.
@MainActor
final class TailscaleAddressWatcher {
    /// Seconds between retries while one is needed; stays at the last value.
    static let retryDelays: [TimeInterval] = [5, 10, 20, 30]

    static func retryDelay(attempt: Int) -> TimeInterval {
        retryDelays[max(0, min(attempt, retryDelays.count - 1))]
    }

    private let addressProvider: () -> String?
    private let needsRetry: () -> Bool
    private let onChange: (String?) -> Void
    private var monitor: NWPathMonitor?
    private var retryItem: DispatchWorkItem?
    private var retryAttempt = 0
    private(set) var lastAddress: String?

    /// `onChange` runs when the address differs from the last one seen, and
    /// on each retry tick while `needsRetry()` is true and an address exists.
    init(
        addressProvider: @escaping () -> String? = { TailscaleInterface.currentAddress() },
        needsRetry: @escaping () -> Bool,
        onChange: @escaping (String?) -> Void
    ) {
        self.addressProvider = addressProvider
        self.needsRetry = needsRetry
        self.onChange = onChange
    }

    func start() {
        guard monitor == nil else { return }
        lastAddress = addressProvider()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.evaluate() } }
        }
        monitor.start(queue: DispatchQueue(label: "dev.noamlitt.dictator.tailscale-watch"))
        self.monitor = monitor
        scheduleRetryIfNeeded()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        retryItem?.cancel()
        retryItem = nil
        retryAttempt = 0
    }

    /// Re-reads the address and reports it if it changed, or if a retry is
    /// still needed and there is an address to try.
    func evaluate() {
        let address = addressProvider()
        let changed = address != lastAddress
        lastAddress = address
        if changed || (address != nil && needsRetry()) {
            onChange(address)
        }
        scheduleRetryIfNeeded()
    }

    /// True while a retry is waiting on its timer.
    var isRetryScheduled: Bool { retryItem != nil }

    /// Starts the retry timer again after a failure that `needsRetry` now reports.
    func rearm() {
        scheduleRetryIfNeeded()
    }

    private func scheduleRetryIfNeeded() {
        retryItem?.cancel()
        retryItem = nil
        guard needsRetry() else {
            retryAttempt = 0
            return
        }
        let delay = Self.retryDelay(attempt: retryAttempt)
        retryAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        retryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
