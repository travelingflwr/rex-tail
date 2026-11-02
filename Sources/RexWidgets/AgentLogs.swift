import Foundation

/// Token usage, split the way both Anthropic and OpenAI report it.
struct TokenUsage: Equatable {
    var input = 0       // fresh (uncached) input
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0

    var total: Int { input + cacheRead + cacheWrite + output }
}

/// Reads a growing JSON-lines log, handing over only lines it hasn't seen.
class IncrementalLog {
    let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()

    init(url: URL) { self.url = url }

    func update() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { // file was replaced or truncated; start over
            offset = 0
            partial = Data()
            reset()
        }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        let chunk = handle.readDataToEndOfFile()
        offset += UInt64(chunk.count)

        var buffer = partial + chunk
        if let lastNewline = buffer.lastIndex(of: 0x0A) {
            partial = buffer[buffer.index(after: lastNewline)...]
            buffer = buffer[..<lastNewline]
        } else {
            partial = buffer
            return
        }
        for line in buffer.split(separator: 0x0A) where !line.isEmpty {
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                consume(obj)
            }
        }
    }

    func reset() {}
    func consume(_ entry: [String: Any]) {}
}

/// A Claude Code transcript: ~/.claude/projects/<folder>/<session-id>.jsonl
final class ClaudeLog: IncrementalLog {
    private var usageByMessage: [String: TokenUsage] = [:]
    private(set) var turns = 0
    private(set) var contextTokens = 0
    private(set) var model: String?

    var usage: TokenUsage {
        usageByMessage.values.reduce(into: TokenUsage()) { sum, u in
            sum.input += u.input; sum.cacheRead += u.cacheRead
            sum.cacheWrite += u.cacheWrite; sum.output += u.output
        }
    }

    override func reset() {
        usageByMessage = [:]; turns = 0; contextTokens = 0; model = nil
    }

    override func consume(_ entry: [String: Any]) {
        let sidechain = entry["isSidechain"] as? Bool == true
        switch entry["type"] as? String {
        case "assistant":
            guard let message = entry["message"] as? [String: Any],
                  let u = message["usage"] as? [String: Any] else { return }
            let usage = TokenUsage(
                input: u["input_tokens"] as? Int ?? 0,
                cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                output: u["output_tokens"] as? Int ?? 0)
            // One response is logged once per content block; keep the last copy.
            let id = message["id"] as? String ?? UUID().uuidString
            usageByMessage[id] = usage
            if !sidechain {
                contextTokens = usage.total
                if let m = message["model"] as? String, m != "<synthetic>" { model = m }
            }
        case "user":
            guard !sidechain, entry["isMeta"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { return }
            if message["content"] is String {
                turns += 1
            } else if let parts = message["content"] as? [[String: Any]],
                      !parts.contains(where: { $0["type"] as? String == "tool_result" }) {
                turns += 1
            }
        default:
            break
        }
    }
}

/// A Codex rollout: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
final class CodexLog: IncrementalLog {
    private(set) var usage = TokenUsage()
    private var userMessages = 0
    private var tasksStarted = 0
    /// Newer Codex builds log no user_message events; each turn starts a task.
    var turns: Int { max(userMessages, tasksStarted) }
    private(set) var contextTokens = 0
    private(set) var contextWindow: Int?
    private(set) var model: String?
    private(set) var started: Date?
    private(set) var cwd: String?
    private(set) var busy = false

    override func reset() {
        usage = TokenUsage(); userMessages = 0; tasksStarted = 0; contextTokens = 0; contextWindow = nil
        model = nil; started = nil; cwd = nil; busy = false
    }

    override func consume(_ entry: [String: Any]) {
        guard let payload = entry["payload"] as? [String: Any] else { return }
        switch entry["type"] as? String {
        case "session_meta":
            if started == nil, let ts = payload["timestamp"] as? String { started = ISO8601.parse(ts) }
            cwd = payload["cwd"] as? String ?? cwd
        case "turn_context":
            model = payload["model"] as? String ?? model
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message": userMessages += 1
            case "task_started": busy = true; tasksStarted += 1
            case "task_complete", "turn_aborted": busy = false
            case "token_count":
                guard let info = payload["info"] as? [String: Any] else { return }
                if let t = info["total_token_usage"] as? [String: Any] {
                    let input = t["input_tokens"] as? Int ?? 0
                    let cached = t["cached_input_tokens"] as? Int ?? 0
                    usage = TokenUsage(input: max(input - cached, 0), cacheRead: cached,
                                       cacheWrite: t["cache_write_input_tokens"] as? Int ?? 0,
                                       output: t["output_tokens"] as? Int ?? 0)
                    if usage.total == 0, let total = t["total_tokens"] as? Int { usage.input = total }
                }
                if let last = info["last_token_usage"] as? [String: Any] {
                    contextTokens = last["total_tokens"] as? Int ?? contextTokens
                }
                contextWindow = info["model_context_window"] as? Int ?? contextWindow
            default: break
            }
        default:
            break
        }
    }

    /// Reads only the first line, to learn which folder a rollout belongs to.
    static func cwd(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 64 * 1024)
        guard let line = head.split(separator: 0x0A).first,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
}
