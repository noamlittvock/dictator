import Darwin
import Foundation

/// One `sysctl(KERN_PROC_ALL)` snapshot of the process table — a few
/// milliseconds, no subprocess, no permission prompt. Enough to find which
/// terminal session the user is typing into and what runs in its
/// foreground, for any terminal app (Terminal, iTerm, Ghostty, Warp, kitty,
/// an editor's built-in terminal…).
struct ProcessTable {
    struct Entry: Equatable {
        let pid: pid_t
        let ppid: pid_t
        let pgid: pid_t
        /// Controlling terminal device, or nil.
        let tty: dev_t?
        /// Foreground process group of that terminal.
        let ttyForegroundGroup: pid_t
        let uid: uid_t
        /// `p_comm` — the executable name, truncated to 16 characters.
        let command: String
    }

    let entries: [Entry]
    private let byPID: [pid_t: Entry]
    private let children: [pid_t: [pid_t]]

    init(entries: [Entry]) {
        self.entries = entries
        var byPID: [pid_t: Entry] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for entry in entries {
            byPID[entry.pid] = entry
            children[entry.ppid, default: []].append(entry.pid)
        }
        self.byPID = byPID
        self.children = children
    }

    static func snapshot() -> ProcessTable {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            return ProcessTable(entries: [])
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        var count = size / stride + 32
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * stride
        let result = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 4, raw.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return ProcessTable(entries: []) }
        count = size / stride

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            let info = buffer[index]
            let tdev = info.kp_eproc.e_tdev
            let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                return String(cString: bytes.baseAddress!)
            }
            entries.append(Entry(
                pid: info.kp_proc.p_pid,
                ppid: info.kp_eproc.e_ppid,
                pgid: info.kp_eproc.e_pgid,
                tty: tdev == -1 || tdev == 0 ? nil : tdev,
                ttyForegroundGroup: info.kp_eproc.e_tpgid,
                uid: info.kp_eproc.e_ucred.cr_uid,
                command: command
            ))
        }
        return ProcessTable(entries: entries)
    }

    func entry(_ pid: pid_t) -> Entry? { byPID[pid] }

    func descendants(of root: pid_t) -> [Entry] {
        var result: [Entry] = []
        var queue = children[root] ?? []
        var seen = Set<pid_t>()
        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted, let entry = byPID[pid] else { continue }
            result.append(entry)
            queue.append(contentsOf: children[pid] ?? [])
        }
        return result
    }

    func ancestors(of pid: pid_t) -> [Entry] {
        var result: [Entry] = []
        var current = byPID[pid]?.ppid
        var guardCount = 0
        while let pid = current, pid > 1, let entry = byPID[pid], guardCount < 64 {
            result.append(entry)
            current = entry.ppid
            guardCount += 1
        }
        return result
    }

    func processes(onTTY tty: dev_t) -> [Entry] {
        entries.filter { $0.tty == tty }
    }

    /// The foreground job on a terminal, deepest process last.
    func foreground(onTTY tty: dev_t) -> [Entry] {
        let onTTY = processes(onTTY: tty)
        guard let group = onTTY.first?.ttyForegroundGroup, group > 0 else { return [] }
        let foreground = onTTY.filter { $0.pgid == group }
        let pids = Set(foreground.map(\.pid))
        // Parents first, leaves last: a process whose parent is also in the
        // job sorts after it.
        return foreground.sorted { lhs, rhs in
            let lhsDepth = ancestors(of: lhs.pid).filter { pids.contains($0.pid) }.count
            let rhsDepth = ancestors(of: rhs.pid).filter { pids.contains($0.pid) }.count
            return lhsDepth < rhsDepth
        }
    }

    // MARK: - Per-process details

    /// Executable path and argv (`KERN_PROCARGS2`). Only readable for the
    /// user's own processes, which is all this ever needs.
    static func arguments(of pid: pid_t) -> (executable: String, argv: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        size = min(size, 256 * 1_024)
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let string = String(decoding: buffer[start..<index], as: UTF8.self)
            return string
        }
        guard let executable = readString() else { return nil }
        while index < size, buffer[index] == 0 { index += 1 }
        var argv: [String] = []
        for _ in 0..<max(0, Int(argc)) {
            guard let arg = readString() else { break }
            argv.append(arg)
            index += 1
        }
        return (executable, argv)
    }

    static func ttyName(_ device: dev_t) -> String? {
        guard let name = devname(device, S_IFCHR) else { return nil }
        let string = String(cString: name)
        return string.isEmpty || string == "??" ? nil : string
    }

    /// Last time a program read input from this terminal — the same signal
    /// `w` uses for idle time. The session the user is typing into right now
    /// is the one with the newest value.
    static func lastInputTime(ttyName: String) -> Date? {
        var info = stat()
        guard stat("/dev/\(ttyName)", &info) == 0 else { return nil }
        let spec = info.st_atimespec
        return Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1e9)
    }

    /// True while the terminal is in canonical mode with echo off — a
    /// password or passphrase prompt (sudo, ssh, gpg). Full-screen programs
    /// (editors, agent TUIs) turn canonical mode off too, so they don't match.
    static func isPasswordPrompt(ttyName: String) -> Bool {
        let fd = open("/dev/\(ttyName)", O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var attributes = termios()
        guard tcgetattr(fd, &attributes) == 0 else { return false }
        let flags = attributes.c_lflag
        return flags & tcflag_t(ICANON) != 0 && flags & tcflag_t(ECHO) == 0
    }
}
