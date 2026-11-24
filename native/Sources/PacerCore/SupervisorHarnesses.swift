import Foundation

/// The Supervisor modules reuse the host's existing registration, settings
/// and lifecycle path. Their local readers never install hooks.
enum SupervisorHarnesses {
    static let definitions: [LocalHarnessDefinition] = [
        definition(.cursor, symbol: "cursorarrow.rays", home: ".cursor", data: "projects",
                   apps: ["Cursor"], ids: ["com.todesktop.230313mzl4w4u92"],
                   website: "https://cursor.com/"),
        definition(.grokBot, symbol: "bolt.horizontal", home: "Library/Application Support/Grok Bot", data: "dune-reliability/sessions",
                   apps: ["Grok Bot"], ids: ["com.anysphere.sand"], website: "https://grok.com/"),
        definition(.antigravity, symbol: "arrow.up.right.circle", home: ".gemini/antigravity", data: "conversations",
                   apps: ["Antigravity", "Antigravity IDE"], ids: ["com.google.antigravity", "com.google.antigravity-ide"],
                   website: "https://antigravity.google/"),
        definition(.muse, symbol: "sparkle", home: ".config/codex-supervisor", data: "muse-quota.json",
                   apps: ["Muse"], ids: ["com.meta.endo"], website: "https://dev.meta.ai/docs/muse-code",
                   balance: .quotaWindows)
    ]

    private static func definition(
        _ provider: AgentProvider, symbol: String, home: String, data: String, apps: [String],
        ids: Set<String>, website: String, balance: HarnessBalanceKind? = nil
    ) -> LocalHarnessDefinition {
        LocalHarnessDefinition(
            descriptor: .init(id: provider, name: apps[0], symbol: symbol, website: URL(string: website), balance: balance),
            platforms: [.macOS], home: home, dataFile: data, windowsExecutables: [],
            macApplicationNames: apps, macBundleIdentifiers: ids,
            makeMonitor: { SupervisorHarnessMonitor(provider: provider, io: $0) }
        )
    }
}

private actor SupervisorHarnessMonitor: LocalHarnessMonitor {
    typealias Sink = @Sendable (HarnessActivity) async -> Void
    let provider: AgentProvider
    let io: LocalHarnessIO
    var home: URL?
    var publish: Sink?
    var loop: Task<Void, Never>?
    var generation = 0
    var last: HarnessActivity?
    var reading = false

    init(provider: AgentProvider, io: LocalHarnessIO) {
        self.provider = provider
        self.io = io
    }

    func start(home: URL, policy: ActivityRefreshPolicy, publish: @escaping Sink) async {
        stop()
        self.home = home
        self.publish = publish
        let interval: UInt64 = provider == .muse ? 300 : 5
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    func updatePolicy(_ policy: ActivityRefreshPolicy) async {}

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        home = nil
        publish = nil
        last = nil
        reading = false
    }

    func refresh() async {
        guard let home, let publish, !reading else { return }
        let generation = generation
        let now = io.now()
        reading = true
        var snapshot: HarnessActivity
        switch provider {
        case .cursor:
            snapshot = SupervisorLocalEvidence.cursor(root: home, files: io.files, now: now)
        case .grokBot:
            snapshot = SupervisorLocalEvidence.grok(root: home, files: io.files, now: now)
        case .antigravity:
            snapshot = SupervisorLocalEvidence.antigravity(root: home, files: io.files, now: now)
        case .muse:
            snapshot = await MuseQuotaReader.read(home: home, files: io.files, now: now)
        default:
            snapshot = .init(status: .missing)
        }
        guard generation == self.generation else { return }
        reading = false
        // Keep a known reading visible as stale if a later CLI call fails.
        if provider == .muse, snapshot.status == .unavailable, snapshot.quota == nil {
            snapshot.quota = last?.quota
            snapshot.quotaSource = last?.quotaSource
        }
        guard snapshot != last else { return }
        last = snapshot
        await publish(snapshot)
    }
}

enum SupervisorLocalEvidence {
    private static let day: TimeInterval = 86_400
    private static let maxTail = 320 * 1024

    static func cursor(root: URL, files: any PlatformFileSystem, now: Date) -> HarnessActivity {
        let projects = root.appendingPathComponent("projects")
        guard let entries = try? files.entries(in: projects) else { return .init(status: .missing) }
        var candidates: [(URL, PlatformFileMetadata)] = []
        for project in entries.prefix(100) where files.metadata(project)?.isDirectory == true {
            let transcripts = project.appendingPathComponent("agent-transcripts")
            let children = (try? files.entries(in: transcripts)) ?? []
            for child in children.prefix(128) {
                let urls = files.metadata(child)?.isDirectory == true
                    ? Array(((try? files.entries(in: child)) ?? []).prefix(12)) : [child]
                for file in urls where file.pathExtension == "jsonl" {
                    if let md = files.metadata(file), md.isRegularFile,
                       (0...day).contains(now.timeIntervalSince(md.modified)) {
                        candidates.append((file, md))
                    }
                }
            }
        }
        let activities = candidates.sorted { $0.1.modified > $1.1.modified }.prefix(24).compactMap { url, metadata -> SessionActivity? in
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let bytes = try? files.read(url, offset: metadata.size > UInt64(maxTail) ? metadata.size - UInt64(maxTail) : 0,
                                              maximumBytes: maxTail) else { return nil }
            return cursorTurn(bytes, session: url.deletingPathExtension().lastPathComponent, identity: metadata.identity,
                              offset: metadata.size > UInt64(maxTail) ? metadata.size - UInt64(maxTail) : 0,
                              modified: metadata.modified, now: now)
        }
        return .init(activities: activities, status: .ready)
    }

    static func cursorTurn(_ bytes: Data, session: String, identity: String, offset: UInt64, modified: Date, now: Date) -> SessionActivity? {
        var turn: (id: String, outcome: SessionActivity.ObservedTurnState)?
        var index = offset
        for (lineNumber, line) in bytes.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
            let id = identity + "-" + String(index)
            index += UInt64(line.count) + 1
            guard offset == 0 || lineNumber > 0 else { continue }
            guard let fields = try? JSONFieldView.document(Data(line), maximumBytes: maxTail).fields(["type", "role", "status"]) else { continue }
            if fields["type"]?.matchesStringLiteral("turn_ended") == true {
                let status = fields["status"]?.string(limit: 32) ?? ""
                let outcome: SessionActivity.ObservedTurnState
                switch status {
                case "success": outcome = .finished
                case "error": outcome = .interrupted(failed: true)
                case "aborted", "canceled", "cancelled", "interrupted": outcome = .interrupted(failed: false)
                default: turn = nil; continue
                }
                turn = (turn?.id ?? id, outcome)
            } else if fields["role"]?.matchesStringLiteral("user") == true {
                turn = (id, .working(.working))
            }
        }
        guard let turn else { return nil }
        if case .working = turn.outcome, now.timeIntervalSince(modified) > 90 { return nil }
        var activity = SessionActivity.observedSession(provider: .cursor, session: session, stage: .working, at: modified)
        activity.applyObservedTurn(turn.outcome, id: turn.id, started: modified, at: modified, live: true)
        return activity
    }

    static func grok(root: URL, files: any PlatformFileSystem, now: Date) -> HarnessActivity {
        guard let folders = try? files.entries(in: root) else { return .init(status: .missing) }
        for folder in folders.prefix(100) where files.metadata(folder)?.isDirectory == true {
            let path = folder.appendingPathComponent("sessions")
            let entries = (try? files.entries(in: path)) ?? []
            for file in entries.prefix(16) where file.lastPathComponent.hasSuffix(".running.json") {
                guard let md = files.metadata(file), md.isRegularFile, md.size <= 16_384,
                      let data = try? files.read(file, offset: 0, maximumBytes: 16_384),
                      let fields = try? JSONFieldView.document(data, maximumBytes: 16_384).fields(["heartbeatAtMs", "quitRequestedAtMs"]),
                      let at = fields["heartbeatAtMs"]?.number(),
                      fields["quitRequestedAtMs"]?.number() == nil,
                      (-30...180).contains(now.timeIntervalSince1970 - at / 1000) else { continue }
                return .init(status: .ready)
            }
        }
        return .init(status: .unavailable)
    }

    static func antigravity(root: URL, files: any PlatformFileSystem, now: Date) -> HarnessActivity {
        guard let paths = try? files.entries(in: root.appendingPathComponent("conversations")) else { return .init(status: .missing) }
        let recent = paths.prefix(512).contains { file in
            let name = file.lastPathComponent
            let base = name.hasSuffix(".db-wal") ? String(name.dropLast(4)) : name
            guard base.hasSuffix(".db"), UUID(uuidString: String(base.dropLast(3))) != nil,
                  let md = files.metadata(file), md.isRegularFile else { return false }
            return (0...900).contains(now.timeIntervalSince(md.modified))
        }
        return .init(status: recent ? .ready : .unavailable)
    }
}
