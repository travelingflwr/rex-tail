import AppKit
import SwiftUI

/// What one Rex server is running versus what's available for it.
struct HostVersionInfo: Identifiable, Equatable {
    enum Status: Equatable {
        case checking
        case upToDate
        case restartNeeded           // newer package installed, server still on the old one
        case updateAvailable         // newer package published
        case macUpdateAvailable(String)
        case unknown(String)
        case unreachable
        case working(String)
        case failed(String)
    }

    var id: String { label ?? "local" }
    var label: String?               // nil = this Mac
    var icon: String
    var platform: String?
    var running: String?
    var runningDate: Date?
    var installed: String?
    var latest: String?
    var latestDate: Date?
    var sessions: [String] = []
    var canUpgrade = false           // apt + passwordless sudo
    var canRestart = false           // rex-user.service exists and is what's running
    var restartBlocked: String?      // why Restart is unavailable, when it is
    var hasRexurrect = false
    var status: Status = .checking

    var name: String { label ?? "This Mac" }
}

/// Tracks Rex versions on this Mac and every Rex host, and runs upgrades.
final class HostsModel: ObservableObject {
    @Published private(set) var hosts: [HostVersionInfo] = []
    @Published private(set) var lastChecked: Date?

    private let queue = DispatchQueue(label: "io.github.travelingflwr.RexTail.hosts", qos: .utility)
    private var versionTimer: Timer?
    private var latestTimer: Timer?
    private var busy = false
    // Facts that change rarely, refreshed with the "latest" check (on `queue`).
    private var facts: [String: RemoteFacts] = [:]
    private var latestBySuiteArch: [String: String] = [:]
    private var latestMacBuild: String?

    private struct RemoteFacts {
        var installed: String?
        var suite: String?
        var arch: String?
        var hasUserUnit = false
        var unitActive = false
        var hasRexurrect = false
        var sudo = false
    }

    func start() {
        refresh(full: true)
        // Running versions are cheap to ask for; new builds are checked every few hours.
        versionTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            self?.refresh(full: false)
        }
        latestTimer = Timer.scheduledTimer(withTimeInterval: 3 * 60 * 60, repeats: true) { [weak self] _ in
            self?.refresh(full: true)
        }
    }

    func refresh(full: Bool) {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.collect(full: full)
            DispatchQueue.main.async {
                // Keep in-progress upgrade rows as they are.
                let working = Dictionary(uniqueKeysWithValues: self.hosts.filter {
                    if case .working = $0.status { return true }; return false
                }.map { ($0.id, $0) })
                self.hosts = result.map { working[$0.id] ?? $0 }
                if full { self.lastChecked = Date() }
                self.busy = false
            }
        }
    }

    // MARK: Collecting

    private func collect(full: Bool) -> [HostVersionInfo] {
        let listed = (RexCLI.json(["api", "call", "hosts.list"])?["hosts"] as? [[String: Any]] ?? [])
            .compactMap { h -> (String, String)? in
                guard let label = h["label"] as? String else { return nil }
                return (label, h["icon"] as? String ?? "server.rack")
            }

        if full {
            latestMacBuild = Self.latestMacBuild()
            var newFacts: [String: RemoteFacts] = [:]
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: listed.count) { i in
                let label = listed[i].0
                if let f = Self.remoteFacts(ssh: label.lowercased()) {
                    lock.lock(); newFacts[label] = f; lock.unlock()
                }
            }
            facts = newFacts
            latestBySuiteArch = [:]
            for f in newFacts.values {
                guard let suite = f.suite, let arch = f.arch else { continue }
                let key = "\(suite)/\(arch)"
                if latestBySuiteArch[key] == nil, let v = Self.latestAptVersion(suite: suite, arch: arch) {
                    latestBySuiteArch[key] = v
                }
            }
        }

        var rows = [macRow()]
        var remote = [HostVersionInfo?](repeating: nil, count: listed.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: listed.count) { i in
            let row = remoteRow(label: listed[i].0, icon: listed[i].1)
            lock.lock(); remote[i] = row; lock.unlock()
        }
        rows += remote.compactMap { $0 }
        return rows
    }

    private func macRow() -> HostVersionInfo {
        var row = HostVersionInfo(label: nil, icon: "desktopcomputer")
        let server = RexCLI.json(["api", "call", "server.version"])
        row.platform = (server?["platform"] as? String).map(Self.prettyPlatform)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RexTracker.bundleID),
              let bundle = Bundle(url: appURL) else {
            row.status = .unknown("Rex app not found")
            return row
        }
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        row.running = "\(short) (\(build))"
        row.runningDate = (server?["built_at"] as? String).flatMap(ISO8601.parse)
        if let latest = latestMacBuild {
            row.latest = latest
            row.status = Versions.compare(build, latest) == .orderedAscending ? .macUpdateAvailable(latest) : .upToDate
        } else {
            row.status = .unknown("Couldn't check for updates")
        }
        return row
    }

    private func remoteRow(label: String, icon: String) -> HostVersionInfo {
        var row = HostVersionInfo(label: label, icon: icon)
        guard let server = RexCLI.json(["-S", label, "api", "call", "server.version"]) else {
            row.status = .unreachable
            return row
        }
        row.running = server["rex_version"] as? String
        row.platform = (server["platform"] as? String).map(Self.prettyPlatform)
        row.runningDate = row.running.flatMap(Versions.date) ?? (server["built_at"] as? String).flatMap(ISO8601.parse)
        row.sessions = (RexCLI.json(["-S", label, "api", "call", "session.list"])?["sessions"] as? [[String: Any]] ?? [])
            .compactMap { $0["label"] as? String }

        guard let f = facts[label] else {
            row.status = .unknown("No SSH access")
            return row
        }
        row.installed = f.installed
        row.canUpgrade = f.sudo && f.suite != nil
        // Only restart through systemd when systemd is what runs the server;
        // otherwise a second server would start beside the one already running.
        row.canRestart = f.hasUserUnit && f.unitActive
        if !f.hasUserUnit {
            row.restartBlocked = "This host has no rex-user.service to restart."
        } else if !f.unitActive {
            row.restartBlocked = "Rex here isn't running under rex-user.service (it was started another way), so restarting the service would start a second server. Restart it by hand."
        }
        row.hasRexurrect = f.hasRexurrect
        if let suite = f.suite, let arch = f.arch { row.latest = latestBySuiteArch["\(suite)/\(arch)"] }
        row.latestDate = row.latest.flatMap(Versions.date)

        guard let running = row.running else {
            row.status = .unknown("Unknown version")
            return row
        }
        let newest = [row.latest, row.installed].compactMap { $0 }
            .max { Versions.compare($0, $1) == .orderedAscending }
        if let latest = row.latest, let installed = row.installed,
           Versions.compare(installed, latest) == .orderedAscending {
            row.status = .updateAvailable
        } else if let installed = row.installed, Versions.compare(running, installed) == .orderedAscending {
            row.status = .restartNeeded
        } else if row.installed == nil, let latest = row.latest, Versions.compare(running, latest) == .orderedAscending {
            row.status = .updateAvailable
        } else if newest == nil {
            row.status = .unknown("Couldn't check for updates")
        } else {
            row.status = .upToDate
        }
        return row
    }

    private static func remoteFacts(ssh host: String) -> RemoteFacts? {
        let script = #"""
        printf 'installed=%s\n' "$(dpkg-query -W -f='${Version}' rex 2>/dev/null)"
        printf 'suite=%s\n' "$(sed -n 's/^Suites: *//p' /etc/apt/sources.list.d/rex.sources 2>/dev/null | head -1)"
        printf 'arch=%s\n' "$(dpkg --print-architecture 2>/dev/null)"
        systemctl --user cat rex-user.service >/dev/null 2>&1 && echo unit=yes
        systemctl --user is-active --quiet rex-user.service && echo active=yes
        systemctl --user cat rexurrect-autosave.service >/dev/null 2>&1 && echo rexurrect=yes
        sudo -n true 2>/dev/null && echo sudo=yes
        exit 0
        """#
        let r = Shell.ssh(host, script: script)
        guard r.ok else { return nil }
        var f = RemoteFacts()
        for line in r.output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            switch parts[0] {
            case "installed": f.installed = parts[1]
            case "suite": f.suite = parts[1]
            case "arch": f.arch = parts[1]
            case "unit": f.hasUserUnit = true
            case "active": f.unitActive = true
            case "rexurrect": f.hasRexurrect = true
            case "sudo": f.sudo = true
            default: break
            }
        }
        return f
    }

    /// The newest `rex` in Superlogical's apt repository for a channel and CPU.
    private static func latestAptVersion(suite: String, arch: String) -> String? {
        guard let url = URL(string: "https://pkgs.superlogical.com/rex/apt/dists/\(suite)/main/binary-\(arch)/Packages"),
              let data = try? Data(contentsOf: url) else { return nil }
        var inRex = false
        var versions: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Package: ") { inRex = line == "Package: rex" }
            else if inRex, line.hasPrefix("Version: ") { versions.append(String(line.dropFirst(9))) }
        }
        return versions.max { Versions.compare($0, $1) == .orderedAscending }
    }

    /// The newest build in the update feed the installed Rex app uses.
    private static func latestMacBuild() -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RexTracker.bundleID),
              let feed = Bundle(url: appURL)?.infoDictionary?["SUFeedURL"] as? String,
              let url = URL(string: feed), let data = try? Data(contentsOf: url) else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        let regex = try! NSRegularExpression(pattern: #"<sparkle:version>([^<]+)</sparkle:version>|sparkle:version="([^"]+)""#)
        let builds = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { m -> String? in
            for i in 1...2 where m.range(at: i).location != NSNotFound {
                return Range(m.range(at: i), in: xml).map { String(xml[$0]) }
            }
            return nil
        }
        return builds.max { Versions.compare($0, $1) == .orderedAscending }
    }

    private static func prettyPlatform(_ p: String) -> String {
        p.replacingOccurrences(of: "darwin", with: "macOS").replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Upgrading

    /// Asks first, then upgrades (or restarts) Rex on a remote host over SSH.
    func confirmAndUpgrade(_ host: HostVersionInfo) {
        guard let label = host.label else { return }
        let upgrading = host.status == .updateAvailable
        let alert = NSAlert()
        alert.messageText = upgrading ? "Upgrade Rex on \(label)?" : "Restart Rex on \(label)?"

        var info: [String] = []
        let target = upgrading ? host.latest : host.installed
        info.append("Running: \(Versions.describe(host.running))\nNew: \(Versions.describe(target))")
        var steps: [String] = []
        if upgrading { steps.append("• install the newer rex package with apt (sudo)") }
        if host.hasRexurrect { steps.append("• save your sessions with rexurrect") }
        steps.append("• restart rex-user.service, the Rex server your Mac connects to")
        info.append("Over SSH to \(label.lowercased()), this will:\n" + steps.joined(separator: "\n"))
        if !host.sessions.isEmpty {
            let names = host.sessions.joined(separator: ", ")
            info.append("Open sessions on \(label): \(names). They may close when the server restarts"
                        + (host.hasRexurrect ? "; rexurrect will have saved them first." : ", and this host has no rexurrect to save them."))
        }
        alert.informativeText = info.joined(separator: "\n\n")
        alert.addButton(withTitle: upgrading ? "Upgrade" : "Restart")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = host.sessions.isEmpty ? .informational : .warning

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(host, upgrading: upgrading, target: target)
    }

    private func run(_ host: HostVersionInfo, upgrading: Bool, target: String?) {
        guard let label = host.label else { return }
        setStatus(host.id, .working(upgrading ? "Upgrading…" : "Restarting…"))
        queue.async { [weak self] in
            var script = "set -e\n"
            if upgrading {
                script += """
                echo '==> apt-get update'
                sudo -n apt-get update -qq
                echo '==> apt-get install rex'
                sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade rex

                """
            }
            if host.hasRexurrect {
                script += "echo '==> saving sessions'\nsystemctl --user start rexurrect-autosave.service || true\n"
            }
            script += "echo '==> restarting rex-user.service'\nsystemctl --user restart rex-user.service\n"

            let r = Shell.ssh(label.lowercased(), script: script)
            guard r.ok else {
                let reason = (r.error.split(separator: "\n").last.map(String.init) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                self?.finish(host.id, .failed(reason.isEmpty ? "Failed (exit \(r.status))" : reason))
                return
            }
            // Wait for the server to come back on the tailnet with the new version.
            self?.setStatus(host.id, .working("Waiting for \(label)…"))
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 2)
                if let v = RexCLI.json(["-S", label, "api", "call", "server.version"])?["rex_version"] as? String,
                   target == nil || Versions.compare(v, target!) != .orderedAscending {
                    self?.finish(host.id, nil)
                    return
                }
            }
            self?.finish(host.id, .failed("\(label) didn't come back on the new version"))
        }
    }

    private func setStatus(_ id: String, _ status: HostVersionInfo.Status) {
        DispatchQueue.main.async {
            guard let i = self.hosts.firstIndex(where: { $0.id == id }) else { return }
            self.hosts[i].status = status
        }
    }

    /// Ends an upgrade: shows a failure, or re-checks everything on success.
    private func finish(_ id: String, _ failure: HostVersionInfo.Status?) {
        if let failure {
            setStatus(id, failure)
        } else {
            setStatus(id, .checking)
            DispatchQueue.main.async { self.refresh(full: true) }
        }
    }
}

/// Debian-style version comparison, enough for Rex's version strings.
enum Versions {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let ta = tokens(a), tb = tokens(b)
        for i in 0..<max(ta.count, tb.count) {
            let x = i < ta.count ? ta[i] : nil
            let y = i < tb.count ? tb[i] : nil
            if x == y { continue }
            guard let x else { return y == "~" ? .orderedDescending : .orderedAscending }
            guard let y else { return x == "~" ? .orderedAscending : .orderedDescending }
            if x == "~" { return .orderedAscending }
            if y == "~" { return .orderedDescending }
            if let nx = Int(x), let ny = Int(y) { return nx < ny ? .orderedAscending : .orderedDescending }
            return x < y ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var digits: Bool?
        for ch in s {
            if ch == "~" {
                if !current.isEmpty { out.append(current) }
                out.append("~"); current = ""; digits = nil
                continue
            }
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { out.append(current) }
                current = ""; digits = nil
                continue
            }
            let isDigit = ch.isNumber
            if digits != nil && digits != isDigit { out.append(current); current = "" }
            current.append(ch); digits = isDigit
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Snapshot builds are numbered by their Unix build time: 0.0.<seconds>-g<commit>.
    static func date(_ version: String) -> Date? {
        let parts = version.split(separator: ".")
        guard parts.count >= 3, parts[0] == "0", parts[1] == "0",
              let seconds = Double(parts[2].prefix { $0.isNumber }), seconds > 1_600_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func describe(_ version: String?) -> String {
        guard let version else { return "unknown" }
        if let d = date(version) { return "\(d.formatted(date: .abbreviated, time: .shortened)) build (\(version))" }
        return version
    }
}

// MARK: Views

struct HostsWidget: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        WidgetCard(title: "Rex Hosts", systemImage: "server.rack") {
            VStack(spacing: 4) {
                ForEach(model.hosts) { host in
                    HostRow(host: host) { model.confirmAndUpgrade(host) }
                }
                HStack {
                    if let checked = model.lastChecked {
                        Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                    }
                    Spacer()
                    Button {
                        model.refresh(full: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Check for new Rex builds now")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
        }
    }
}

struct HostRow: View {
    let host: HostVersionInfo
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: host.icon)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 4)
        .help(tooltip)
    }

    private var subtitle: String {
        var parts: [String] = []
        if host.label == nil, let running = host.running {
            parts.append("Rex \(running)")
        } else if let d = host.runningDate {
            parts.append("\(d.formatted(.dateTime.month(.abbreviated).day())) build")
        }
        if let p = host.platform { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        switch host.status {
        case .checking:
            ProgressView().controlSize(.mini)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        case .restartNeeded:
            actionButton("Restart", enabled: host.canRestart)
        case .updateAvailable:
            VStack(alignment: .trailing, spacing: 2) {
                actionButton("Upgrade", enabled: host.canUpgrade && host.canRestart)
                if let behind = behindText { Text(behind).font(.system(size: 9.5)).foregroundStyle(.orange) }
            }
        case .macUpdateAvailable(let build):
            Text("Build \(build) available")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .unknown(let why):
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help(why)
        case .unreachable:
            Image(systemName: "wifi.slash").foregroundStyle(.secondary)
        case .working(let what):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(what).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .failed(let why):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                actionButton("Retry", enabled: true)
            }
            .help(why)
        }
    }

    private func actionButton(_ title: String, enabled: Bool) -> some View {
        Button(title, action: onAction)
            .controlSize(.small)
            .disabled(!enabled)
    }

    private var behindText: String? {
        guard let running = host.runningDate, let latest = host.latestDate else { return nil }
        let days = Int(latest.timeIntervalSince(running) / 86400)
        return days >= 1 ? "\(days)d behind" : "behind"
    }

    private var tooltip: String {
        var lines = ["Running: \(Versions.describe(host.running))"]
        if host.label != nil {
            lines.append("Installed: \(Versions.describe(host.installed))")
            lines.append("Latest: \(Versions.describe(host.latest))")
            if !host.sessions.isEmpty { lines.append("Sessions: \(host.sessions.joined(separator: ", "))") }
        } else if let latest = host.latest {
            lines.append("Latest build: \(latest). Rex updates itself on the Mac.")
        }
        switch host.status {
        case .restartNeeded: lines.append("A newer Rex is installed but the server hasn't restarted onto it.")
        case .restartNeeded where !host.canRestart:
            lines.append(host.restartBlocked ?? "Restart isn't available on this host.")
        case .updateAvailable where !(host.canUpgrade && host.canRestart):
            lines.append(host.restartBlocked ?? "Upgrade needs apt with passwordless sudo and rex-user.service on this host.")
        case .failed(let why): lines.append("Last attempt failed: \(why)")
        case .unknown(let why): lines.append(why)
        case .unreachable: lines.append("Rex on this host isn't answering.")
        default: break
        }
        return lines.joined(separator: "\n")
    }
}
