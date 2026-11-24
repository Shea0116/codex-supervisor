import Foundation
#if os(macOS)
import Darwin
#endif

package enum MuseQuotaReader {
    package enum Origin: String, Equatable, Sendable { case cli, manual }

    static func read(home: URL, files: any PlatformFileSystem, now: Date) async -> HarnessActivity {
        #if os(macOS)
        if let executable = executable(in: FileManager.default.homeDirectoryForCurrentUser),
           let text = await Task.detached(priority: .utility, operation: { usage(executable) }).value,
           let reading = parse(text, at: now) {
            return activity(reading, origin: .cli)
        }
        #endif
        let file = home.appendingPathComponent("muse-quota.json")
        if let metadata = files.metadata(file), metadata.isRegularFile, metadata.size <= 8192,
           let data = try? files.read(file, offset: 0, maximumBytes: 8192),
           let reading = manual(data, at: now) {
            return activity(reading, origin: .manual)
        }
        return .init(status: .unavailable)
    }

    private static func activity(_ reading: QuotaSnapshot, origin: Origin) -> HarnessActivity {
        var activity = HarnessActivity(status: .ready)
        activity.quota = reading
        activity.quotaSource = origin
        return activity
    }

    private static func iso(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: text) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func snapshot(_ windows: [QuotaWindow], at date: Date) -> QuotaSnapshot? {
        guard !windows.isEmpty else { return nil }
        return QuotaSnapshot(buckets: [.init(id: "muse", name: nil, plan: nil, windows: windows, credits: nil)],
                             capturedAt: date, accountScope: nil, resetCredits: nil)
    }

    static func manual(_ data: Data, at now: Date) -> QuotaSnapshot? {
        struct Input: Decodable {
            struct Window: Decodable { var remainingPercent: Double; var resetsAt: String? }
            var observedAt: String
            var fiveHour: Window?
            var weekly: Window?
        }
        guard let input = try? JSONDecoder().decode(Input.self, from: data),
              let observed = iso(input.observedAt), observed <= now.addingTimeInterval(60) else { return nil }
        let windows = [("primary", 300, input.fiveHour), ("secondary", 10_080, input.weekly)].compactMap { lane, duration, input -> QuotaWindow? in
            guard let input, input.remainingPercent.isFinite, (0...100).contains(input.remainingPercent) else { return nil }
            let reset = input.resetsAt.flatMap(iso)
            guard input.resetsAt == nil || reset.map({ $0 > observed }) == true else { return nil }
            return QuotaWindow(id: "muse/" + lane, usedPercent: 100 - input.remainingPercent, durationMinutes: duration, resetsAt: reset)
        }
        return snapshot(windows, at: observed)
    }

    package static func parse(_ output: String, at now: Date) -> QuotaSnapshot? {
        let plain = output.replacingOccurrences(of: "\u{001B}" + #"\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let period = #"(?i)^\s*[│|*•-]*\s*(weekly|week\b|7\s*-?\s*(?:days?|d)\b|(?:rolling\s+)?window\b|(?:5|five)\s*-?\s*(?:hours?|h)\b)"#
        let after = #"(?i)\b(\d{1,3}(?:\.\d+)?)\s*%\s*(?:of\s+allowance\s+)?(used|remaining|left)\b"#
        let before = #"(?i)\b(used|remaining|left)\s*[:=]?\s*(\d{1,3}(?:\.\d+)?)\s*%"#
        let resetPattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})"#
        guard let head = try? NSRegularExpression(pattern: period),
              let suffix = try? NSRegularExpression(pattern: after),
              let prefix = try? NSRegularExpression(pattern: before) else { return nil }
        var found: [Int: QuotaWindow] = [:]
        for raw in plain.split(whereSeparator: \.isNewline).prefix(200) {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            guard let labelMatch = head.firstMatch(in: line, range: range),
                  let labelRange = Range(labelMatch.range(at: 1), in: line) else { continue }
            let label = line[labelRange].lowercased()
            let weekly = label.hasPrefix("week") || label.hasPrefix("7")
            let forward = suffix.firstMatch(in: line, range: range)
            guard let match = forward ?? prefix.firstMatch(in: line, range: range),
                  let digits = Range(match.range(at: forward != nil ? 1 : 2), in: line),
                  let kind = Range(match.range(at: forward != nil ? 2 : 1), in: line),
                  let percent = Double(line[digits]), (0...100).contains(percent) else { continue }
            let used = line[kind].lowercased() == "used" ? percent : 100 - percent
            let reset = line.range(of: resetPattern, options: .regularExpression).flatMap { iso(String(line[$0])) }
            let minutes = weekly ? 10_080 : 300
            found[minutes] = QuotaWindow(id: weekly ? "muse/secondary" : "muse/primary", usedPercent: used,
                                         durationMinutes: minutes, resetsAt: reset)
        }
        return snapshot([300, 10_080].compactMap { found[$0] }, at: now)
    }

    package static func executable(in home: URL) -> URL? {
        let paths = [home.appendingPathComponent(".local/bin/muse").path, home.appendingPathComponent(".muse/bin/muse").path,
                     "/opt/homebrew/bin/muse", "/usr/local/bin/muse"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    #if os(macOS)
    private static func usage(_ executable: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["usage"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["MUSE_NO_AUTO_UPDATE"] = "1"
        environment.removeValue(forKey: "MUSE_LAUNCHER_INSTALL")
        environment["TERM"] = "dumb"
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment

        do { try process.run() } catch { return nil }
        try? output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        defer {
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < deadline, data.count < 64 << 10 {
            var watch = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&watch, 1, 100)
            if result < 0 { break }
            if result == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { break }
            else if errno != EAGAIN && errno != EINTR { break }
        }
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.025) }
        guard !process.isRunning, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    #endif
}
