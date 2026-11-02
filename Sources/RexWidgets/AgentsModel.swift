import AppKit
import Foundation

/// A Rex server: this Mac, or one of the hosts listed by `rex hosts`.
struct RexHost: Hashable {
    let label: String?   // nil for this Mac
    let icon: String?    // SF Symbol name Rex stores for the host

    var isLocal: Bool { label == nil }
    var rexArgs: [String] { label.map { ["-S", $0] } ?? [] }
    /// The SSH alias, which matches the Rex label in lowercase (for example, "Studio" becomes "studio").
    var sshAlias: String? { label?.lowercased() }
}

struct AgentInfo: Identifiable, Equatable {
    var id: String { "\(hostLabel ?? "local")/\(blockID)" }
    var blockID: String
    var hostLabel: String?
    var hostIcon: String?
    var sessionID: String
    var sessionLabel: String
    var windowID: String
    var kind: AgentKind
    var title: String
    var folder: String
    var state: AgentState
    var stateMessage: String?
    var started: Date?
    var hasStats = false
    var turns = 0
    var contextTokens = 0
    var contextWindow: Int?
    var usage = TokenUsage()
    var model: String?
}

/// Finds Claude Code and Codex running in Rex panes, on this Mac and on every
/// Rex host, and reads their usage.
final class AgentsModel: ObservableObject {
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var problem: String?

    private let queue = DispatchQueue(label: "io.github.travelingflwr.RexTail.agents", qos: .utility)
    private var timer: Timer?
    private var refreshing = false

    // Local log readers (touched only on `queue`).
    private var claudeLogs: [String: ClaudeLog] = [:]
    private var codexLogs: [String: CodexLog] = [:]
    private var codexFileForPID: [Int32: String] = [:]

    // Remote state (touched only on `queue`, one host per worker).
    private var hosts: [RexHost] = []
    private var hostsCheckedAt = Date.distantPast
    private var bridges: [String: RemoteBridge] = [:]
    private var hostDownUntil: [String: Date] = [:]
    private let hostLock = NSLock()

    private let home = FileManager.default.homeDirectoryForCurrentUser

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        queue.async { [weak self] in
            guard let self else { return }
            let (found, problem) = self.collect()
            DispatchQueue.main.async {
                if self.agents != found { self.agents = found }
                if self.problem != problem { self.problem = problem }
                self.refreshing = false
            }
        }
    }

    /// Switches Rex to the agent's session and focuses its pane.
    func jump(to agent: AgentInfo) {
        NSRunningApplication.runningApplications(withBundleIdentifier: RexTracker.bundleID).first?.activate()
        let host = RexHost(label: agent.hostLabel, icon: nil)
        queue.async {
            if let client = Self.rexAppClient(on: host) {
                RexCLI.run(host.rexArgs + ["do", "-C", client, "session.select",
                                           "session_id=\(agent.sessionID)", "window_id=\(agent.windowID)"])
            }
            RexCLI.run(host.rexArgs + ["focus", "-s", agent.sessionID, agent.blockID])
        }
    }

    // MARK: Collecting (background)

    private func collect() -> ([AgentInfo], String?) {
        guard RexCLI.path != nil else { return ([], "Couldn't find the rex command.") }

        if Date().timeIntervalSince(hostsCheckedAt) > 60 {
            hostsCheckedAt = Date()
            let listed = (RexCLI.json(["api", "call", "hosts.list"])?["hosts"] as? [[String: Any]] ?? [])
                .compactMap { h -> RexHost? in
                    guard let label = h["label"] as? String else { return nil }
                    return RexHost(label: label, icon: h["icon"] as? String)
                }
            hosts = [RexHost(label: nil, icon: nil)] + listed
            for host in listed where bridges[host.label!] == nil {
                bridges[host.label!] = RemoteBridge(sshHost: host.sshAlias!)
            }
        }

        // Ask every host at once so a slow one doesn't hold up the rest.
        var results = [[AgentInfo]?](repeating: nil, count: hosts.count)
        let resultsLock = NSLock()
        let hostsNow = hosts
        DispatchQueue.concurrentPerform(iterations: hostsNow.count) { i in
            let found = collect(on: hostsNow[i])
            resultsLock.lock(); results[i] = found; resultsLock.unlock()
        }
        guard results.first.flatMap({ $0 }) != nil else { return ([], "Couldn't reach the Rex server.") }

        var all = results.compactMap { $0 }.flatMap { $0 }
        all.sort { a, b in
            if a.state != b.state { return a.state < b.state }
            if a.hostLabel != b.hostLabel { return (a.hostLabel ?? "") < (b.hostLabel ?? "") }
            return (a.started ?? .distantFuture) < (b.started ?? .distantFuture)
        }
        return (all, nil)
    }

    /// Lists the agents on one host. Returns nil if the host can't be reached.
    private func collect(on host: RexHost) -> [AgentInfo]? {
        let key = host.label ?? ""
        hostLock.lock(); let downUntil = hostDownUntil[key]; hostLock.unlock()
        if let downUntil, downUntil > Date() { return nil }

        guard let sessions = RexCLI.json(host.rexArgs + ["api", "call", "session.list"])?["sessions"] as? [[String: Any]] else {
            if !host.isLocal { hostLock.lock(); hostDownUntil[key] = Date().addingTimeInterval(60); hostLock.unlock() }
            return nil
        }

        var found: [(AgentInfo, Int32, String)] = [] // agent, pid, cwd
        for session in sessions {
            guard let sid = session["session_id"] as? String,
                  let view = RexCLI.json(host.rexArgs + ["api", "call", "-s", sid, "session.view"]) else { continue }
            let label = session["label"] as? String ?? "Session"
            for window in view["windows"] as? [[String: Any]] ?? [] {
                let wid = window["window_id"] as? String ?? ""
                let tabName = Self.customTabName(window["label"] as? String, windowID: wid)
                for layer in window["layers"] as? [[String: Any]] ?? [] {
                    for block in layer["blocks"] as? [[String: Any]] ?? [] {
                        guard let bid = block["block_id"] as? String,
                              (block["flavor"] as? String)?.hasSuffix(".terminal.shell") == true,
                              let hit = inspect(block: bid, host: host, session: sid, sessionLabel: label, window: wid,
                                            tabName: tabName)
                        else { continue }
                        found.append(hit)
                    }
                }
            }
        }

        if host.isLocal {
            return fillLocal(found)
        }
        return fillRemote(found, host: host)
    }

    /// A tab name the user set in Rex, or nil for Rex's default "Window <id>" label.
    /// Rex's sidebar shows the custom name in place of the pane title, so we do too.
    static func customTabName(_ label: String?, windowID: String) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
        let suffix = String(windowID.replacingOccurrences(of: "-", with: "").suffix(8))
        return label == "Window \(suffix)" ? nil : label
    }

    /// Reads a pane's foreground program and Rex status; returns it if it's an agent.
    private func inspect(block bid: String, host: RexHost, session sid: String, sessionLabel: String,
                         window wid: String, tabName: String?) -> (AgentInfo, Int32, String)? {
        guard let process = RexCLI.json(host.rexArgs + ["block", "call", "-b", bid, "process"]),
              let fg = process["foreground"] as? [String: Any],
              let pidNumber = fg["pid"] as? Int else { return nil }
        let names = ["argv0", "name", "path", "invoked_path"].compactMap { fg[$0] as? String }
            .map { ($0 as NSString).lastPathComponent.lowercased() }
        let paths = [fg["path"], fg["invoked_path"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()

        let statusRecord = (RexCLI.json(host.rexArgs + ["block", "call", "-b", bid, "program_status"])?["records"]
            as? [[String: Any]])?.first
        let statusApp = (statusRecord?["effective_app"] as? String ?? statusRecord?["app"] as? String ?? "").lowercased()

        let kind: AgentKind
        if names.contains("claude") || paths.contains("/claude/versions/") || statusApp.contains("claude") {
            kind = .claude
        } else if names.contains(where: { $0.hasPrefix("codex") }) || paths.contains("codex") || statusApp.contains("codex") {
            kind = .codex
        } else {
            return nil
        }

        let cwd = fg["cwd"] as? String ?? ""
        let title = tabName ?? (RexCLI.json(host.rexArgs + ["block", "call", "-b", bid, "title"])?["title"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? kind.rawValue
        var agent = AgentInfo(
            blockID: bid, hostLabel: host.label, hostIcon: host.icon, sessionID: sid, sessionLabel: sessionLabel,
            windowID: wid, kind: kind, title: Self.cleanTitle(title), folder: (cwd as NSString).lastPathComponent,
            state: .unknown)
        if let record = statusRecord, let raw = record["state"] as? String {
            agent.state = AgentState(rexState: raw)
            agent.stateMessage = record["msg"] as? String
        }
        return (agent, Int32(pidNumber), cwd)
    }

    // MARK: Remote

    private func fillRemote(_ found: [(AgentInfo, Int32, String)], host: RexHost) -> [AgentInfo] {
        let agents = found.map { $0.0 }
        guard !found.isEmpty, let bridge = bridges[host.label ?? ""] else { return agents }
        let request: [[String: Any]] = found.map { agent, pid, cwd in
            ["id": agent.blockID, "kind": agent.kind == .claude ? "claude" : "codex", "pid": Int(pid), "cwd": cwd]
        }
        guard let reply = bridge.query(request) else { return agents } // status only
        return agents.map { agent in
            guard let r = reply[agent.blockID], r["error"] == nil else { return agent }
            var a = agent
            if let started = r["started"] as? Double { a.started = Date(timeIntervalSince1970: started) }
            if a.started == nil, let iso = r["startedISO"] as? String { a.started = ISO8601.parse(iso) }
            if a.state == .unknown {
                if let status = r["status"] as? String { a.state = AgentState(rexState: status) }
                else if let busy = r["busy"] as? Bool { a.state = busy ? .working : .idle }
            }
            if let usage = r["usage"] as? [Int], usage.count == 4 {
                a.hasStats = true
                a.usage = TokenUsage(input: usage[0], cacheRead: usage[1], cacheWrite: usage[2], output: usage[3])
                a.turns = r["turns"] as? Int ?? 0
                a.contextTokens = r["context"] as? Int ?? 0
                a.contextWindow = r["window"] as? Int
                a.model = r["model"] as? String
            }
            return a
        }
    }

    // MARK: Local

    private func fillLocal(_ found: [(AgentInfo, Int32, String)]) -> [AgentInfo] {
        var liveClaude = Set<String>(), liveCodex = Set<String>(), livePIDs = Set<Int32>()
        let agents = found.map { agent, pid, cwd -> AgentInfo in
            var a = agent
            switch a.kind {
            case .claude:
                fillClaude(&a, pid: pid, cwd: cwd, live: &liveClaude)
            case .codex:
                livePIDs.insert(pid)
                fillCodex(&a, pid: pid, cwd: cwd, live: &liveCodex)
            }
            return a
        }
        claudeLogs = claudeLogs.filter { liveClaude.contains($0.key) }
        codexLogs = codexLogs.filter { liveCodex.contains($0.key) }
        codexFileForPID = codexFileForPID.filter { livePIDs.contains($0.key) }
        return agents
    }

    private func fillClaude(_ agent: inout AgentInfo, pid: Int32, cwd: String, live: inout Set<String>) {
        // Claude Code writes ~/.claude/sessions/<pid>.json with its session ID.
        let infoURL = home.appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: infoURL),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionID = info["sessionId"] as? String else { return }
        if let ms = info["startedAt"] as? Double { agent.started = Date(timeIntervalSince1970: ms / 1000) }
        if agent.state == .unknown, let status = info["status"] as? String { agent.state = AgentState(rexState: status) }

        guard let path = claudeTranscript(sessionID: sessionID, cwd: info["cwd"] as? String ?? cwd) else { return }
        live.insert(path)
        let log = claudeLogs[path] ?? ClaudeLog(url: URL(fileURLWithPath: path))
        claudeLogs[path] = log
        log.update()
        agent.hasStats = true
        agent.turns = log.turns
        agent.contextTokens = log.contextTokens
        agent.usage = log.usage
        agent.model = log.model
    }

    private func claudeTranscript(sessionID: String, cwd: String) -> String? {
        let projects = home.appendingPathComponent(".claude/projects")
        // Claude names the folder after the working directory, with every
        // character that isn't a letter or digit turned into "-".
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let direct = projects.appendingPathComponent(slug).appendingPathComponent("\(sessionID).jsonl").path
        if FileManager.default.fileExists(atPath: direct) { return direct }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        for folder in folders {
            let candidate = projects.appendingPathComponent(folder).appendingPathComponent("\(sessionID).jsonl").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func fillCodex(_ agent: inout AgentInfo, pid: Int32, cwd: String, live: inout Set<String>) {
        agent.started = Self.processStart(pid)
        let path = codexFileForPID[pid] ?? codexRollout(pid: pid, cwd: cwd)
        guard let path else { return }
        codexFileForPID[pid] = path
        live.insert(path)
        let log = codexLogs[path] ?? CodexLog(url: URL(fileURLWithPath: path))
        codexLogs[path] = log
        log.update()
        agent.hasStats = true
        agent.turns = log.turns
        agent.contextTokens = log.contextTokens
        agent.contextWindow = log.contextWindow
        agent.usage = log.usage
        agent.model = log.model
        if let started = log.started, agent.started == nil { agent.started = started }
        if agent.state == .unknown { agent.state = log.busy ? .working : .idle }
    }

    /// Finds the rollout file a Codex process is writing.
    private func codexRollout(pid: Int32, cwd: String) -> String? {
        // Best: the file the process (or its native child) has open.
        var pids = [pid]
        if let children = Shell.run("/usr/bin/pgrep", ["-P", String(pid)]),
           let text = String(data: children, encoding: .utf8) {
            pids += text.split(separator: "\n").compactMap { Int32($0) }
        }
        if let out = Shell.run("/usr/sbin/lsof", ["-Fn", "-p", pids.map(String.init).joined(separator: ",")]),
           let text = String(data: out, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("n") && $0.contains("/rollout-") && $0.hasSuffix(".jsonl") }) {
            return String(line.dropFirst())
        }
        // Fallback: the newest rollout for this folder written since the process started.
        let since = Self.processStart(pid)?.addingTimeInterval(-5) ?? Date().addingTimeInterval(-86400)
        let root = home.appendingPathComponent(".codex/sessions")
        let cal = Calendar.current
        var best: (path: String, date: Date)?
        for dayOffset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= since, modified > (best?.date ?? .distantPast),
                      CodexLog.cwd(of: file) == cwd else { continue }
                best = (file.path, modified)
            }
        }
        return best?.path
    }

    private static func processStart(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }

    // MARK: Helpers

    /// The Rex app on this Mac, as a client of the given host's server.
    private static func rexAppClient(on host: RexHost) -> String? {
        guard let clients = RexCLI.json(host.rexArgs + ["api", "call", "client.list"])?["clients"] as? [[String: Any]]
        else { return nil }
        let apps = clients.filter { ($0["info"] as? [String: Any])?["platform"] as? String == "macos" }
        let match: [String: Any]?
        if host.isLocal {
            let rexPID = NSRunningApplication.runningApplications(withBundleIdentifier: RexTracker.bundleID).first?.processIdentifier
            match = apps.first { (($0["principal"] as? [String: Any])?["pid"] as? Int).map(Int32.init) == rexPID }
        } else {
            // Over Tailscale, the server sees which machine each client is on.
            let me = (RexCLI.json(host.rexArgs + ["api", "call", "server.whoami"])?["principal"] as? [String: Any])?["node"] as? String
            match = apps.first { ($0["principal"] as? [String: Any])?["node"] as? String == me }
        }
        return (match ?? apps.first)?["client_id"] as? String
    }

    /// Drops the spinner/status glyphs agents put at the start of a terminal title.
    private static func cleanTitle(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.alphanumerics.union(.punctuationCharacters).inverted)
    }
}
