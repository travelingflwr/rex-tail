import AppKit
import SwiftUI

enum AgentKind: String {
    case claude = "Claude Code"
    case codex = "Codex"

    /// Apps whose icon stands for this agent, best match first.
    private var iconBundleIDs: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The installed app's icon, read from macOS (nothing is bundled).
    var icon: NSImage? {
        if let cached = Self.iconCache[self] { return cached }
        let icon = iconBundleIDs.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            .first
        Self.iconCache[self] = icon
        return icon
    }

    private static var iconCache: [AgentKind: NSImage?] = [:]
}

enum AgentState: Int, Comparable {
    case waiting = 0, working, idle, unknown // sort order: needs you first

    static func < (a: AgentState, b: AgentState) -> Bool { a.rawValue < b.rawValue }

    init(rexState raw: String) {
        let s = raw.lowercased()
        if ["wait", "input", "attention", "permission", "approv", "ask", "blocked"].contains(where: s.contains) {
            self = .waiting
        } else if ["work", "busy", "run", "think", "generat"].contains(where: s.contains) {
            self = .working
        } else if ["idle", "done", "ready", "complete", "finish"].contains(where: s.contains) {
            self = .idle
        } else {
            self = .unknown
        }
    }

    var label: String {
        switch self {
        case .waiting: "Needs you"
        case .working: "Working"
        case .idle: "Idle"
        case .unknown: "Running"
        }
    }

    var color: Color {
        switch self {
        case .waiting: .orange
        case .working: .green
        case .idle: .secondary
        case .unknown: .blue
        }
    }
}

// MARK: Views

struct AgentsWidget: View {
    @ObservedObject var model: AgentsModel

    var body: some View {
        WidgetCard(title: "Agents", systemImage: "sparkles") {
            if let problem = model.problem {
                Text(problem).foregroundStyle(.secondary)
            } else if model.agents.isEmpty {
                Text("No Claude Code or Codex sessions running in Rex.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.agents) { agent in
                        AgentRow(agent: agent) { model.jump(to: agent) }
                    }
                }
            }
        }
    }
}

struct AgentRow: View {
    let agent: AgentInfo
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentIcon(kind: agent.kind, state: agent.state)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let host = agent.hostLabel {
                        Image(systemName: agent.hostIcon ?? "network")
                        Text(host).fontWeight(.medium)
                        Text("·")
                    }
                    Text("\(agent.sessionLabel) · \(agent.folder)")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                stats
                if agent.state == .waiting, let msg = agent.stateMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .help(tooltip)
    }

    private var stats: some View {
        HStack(spacing: 9) {
            if let started = agent.started {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    stat("clock", Format.duration(context.date.timeIntervalSince(started)))
                }
            }
            if agent.hasStats {
                stat("text.bubble", "\(agent.turns)")
                stat("square.stack.3d.up", contextText)
                stat("arrow.up.right", Format.tokens(agent.usage.output))
            } else if agent.hostLabel != nil {
                Text("Token use unavailable")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var contextText: String {
        if let window = agent.contextWindow, window > 0 {
            return "\(Int((Double(agent.contextTokens) / Double(window) * 100).rounded()))%"
        }
        return Format.tokens(agent.contextTokens)
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text).monospacedDigit()
        }
        .lineLimit(1)
    }

    private var tooltip: String {
        var lines = ["\(agent.kind.rawValue) · \(agent.state.label) — click to go to this pane"]
        lines.append("Machine: \(agent.hostLabel ?? "This Mac")")
        if !agent.hasStats {
            lines.append(agent.hostLabel == nil ? "No usage log found yet."
                         : "No usage numbers: SSH to \(agent.hostLabel!.lowercased()) didn't answer.")
            return lines.joined(separator: "\n")
        }
        if let model = agent.model { lines.append("Model: \(model)") }
        lines.append("Turns: \(agent.turns)")
        var ctx = "Context: \(Format.tokens(agent.contextTokens)) tokens"
        if let w = agent.contextWindow { ctx += " of \(Format.tokens(w))" }
        lines.append(ctx)
        let u = agent.usage
        lines.append("Output: \(Format.tokens(u.output))")
        lines.append("Input: \(Format.tokens(u.input)) new, \(Format.tokens(u.cacheRead)) cache read, \(Format.tokens(u.cacheWrite)) cache write")
        lines.append("Total processed: \(Format.tokens(u.total))")
        return lines.joined(separator: "\n")
    }
}

/// The agent's app icon with its status dot as a corner badge.
struct AgentIcon: View {
    let kind: AgentKind
    let state: AgentState

    var body: some View {
        Group {
            if let icon = kind.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: kind.fallbackSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(width: 26, height: 26)
        .overlay(alignment: .bottomTrailing) {
            StatusDot(state: state)
                .padding(1.5)
                .background(Circle().fill(.background))
                .offset(x: 3, y: 3)
        }
    }
}

struct StatusDot: View {
    let state: AgentState
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
            .opacity(state == .working && pulse ? 0.35 : 1)
            .animation(state == .working ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: pulse)
            .onAppear { pulse = true }
    }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: "\(n / 1000)k"
        case 1000...: String(format: "%.1fk", Double(n) / 1000)
        default: "\(n)"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds) / 60, 0)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
