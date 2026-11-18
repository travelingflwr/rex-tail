import Foundation

/// Asks a question in Rex's command palette with `rex.ui.pick`, through
/// `rex do`. Rex shows it in every connected Rex app that can show prompts
/// (the Mac, an iPad, a phone, Rex Linux) and the first answer wins.
///
/// When no app can show it (`unsupported`, `no_client`, `busy`, `failed`, or
/// `rex` itself fails), the caller falls back to asking on this Mac.
enum RexPrompt {
    struct Item {
        var id: String
        var title: String
        var subtitle: String? = nil
        var icon: String? = nil   // one of Rex's prompt icons: server, gear, terminal…
        var detail: String? = nil
    }

    enum Answer: Equatable {
        case picked(String)
        case cancelled           // closed without answering, or timed out
        case unavailable(String) // nobody could be asked; ask some other way
    }

    /// Blocks until there's an answer, so call it off the main thread.
    static func pick(title: String, placeholder: String? = nil, items: [Item],
                     timeout: Int = 300) -> Answer {
        let script = luaScript(title: title, placeholder: placeholder, items: items, timeout: timeout)
        // rex do waits for the person; give it a little longer than the prompt.
        let r = RexCLI.runLong(["do", "--timeout", "\(timeout + 15)s", "-e", script])
        guard r.ok,
              let data = r.output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .unavailable(r.ok ? "unreadable answer" : "rex do failed (exit \(r.status))")
        }
        if let id = obj["answer"] as? String { return .picked(id) }
        let why = obj["why"] as? String ?? "failed"
        return why == "cancelled" || why == "timeout" ? .cancelled : .unavailable(why)
    }

    static func luaScript(title: String, placeholder: String?, items: [Item], timeout: Int) -> String {
        var rows: [String] = []
        for it in items {
            var f = ["id = \(lua(it.id))", "title = \(lua(it.title))"]
            if let s = it.subtitle { f.append("subtitle = \(lua(s))") }
            if let s = it.icon { f.append("icon = \(lua(s))") }
            if let s = it.detail { f.append("detail = \(lua(s))") }
            rows.append("{ " + f.joined(separator: ", ") + " }")
        }
        var args = ["title = \(lua(title))", "timeout = \(timeout)", "items = { \(rows.joined(separator: ", ")) }"]
        if let p = placeholder { args.append("placeholder = \(lua(p))") }
        return """
        local answer, why = rex.ui.pick{ \(args.joined(separator: ", ")) }
        return { answer = answer, why = why }
        """
    }

    /// A Lua string literal for s. Host and session names come from other
    /// machines, so every character that could end the string is escaped.
    static func lua(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c.value {
            case 0x5c: out += "\\\\"
            case 0x22: out += "\\\""
            case 0x0a: out += "\\n"
            case 0..<0x20, 0x7f: out += String(format: "\\%03d", c.value)
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }
}
