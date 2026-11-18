import Foundation

/// Asks a question in Rex's command palette with `rex.ui.pick`, through the
/// `rex_tail_pick` action (rex/rex_tail.lua). Rex shows it in every connected
/// Rex app that can show prompts (the Mac, an iPad, a phone, Rex Linux), and
/// the first answer wins.
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
    ///
    /// Rex shows prompts only from actions the server's init.lua defines,
    /// not from scripts sent with `rex do -e`, so this calls the
    /// `rex_tail_pick` action from rex/rex_tail.lua. Without it installed,
    /// `rex do` fails and the caller asks on this Mac instead.
    static func pick(title: String, placeholder: String? = nil, items: [Item],
                     timeout: Int = 300) -> Answer {
        var args = ["do", "--timeout", "\(timeout + 15)s", "rex_tail_pick",
                    "title=\(title)", "items=\(itemsJSON(items))", "timeout=\(timeout)"]
        if let p = placeholder { args.append("placeholder=\(p)") }
        let r = RexCLI.runLong(args)
        guard r.ok,
              let data = r.output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .unavailable(r.ok ? "unreadable answer" : "rex do failed (exit \(r.status)): \(r.error)")
        }
        if let id = obj["answer"] as? String { return .picked(id) }
        let why = obj["why"] as? String ?? "failed"
        return why == "cancelled" || why == "timeout" ? .cancelled : .unavailable(why)
    }

    static func itemsJSON(_ items: [Item]) -> String {
        let list: [[String: String]] = items.map { it in
            var d = ["id": it.id, "title": it.title]
            if let s = it.subtitle { d["subtitle"] = s }
            if let s = it.icon { d["icon"] = s }
            if let s = it.detail { d["detail"] = s }
            return d
        }
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
