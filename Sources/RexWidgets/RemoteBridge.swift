import Foundation

/// A long-lived SSH connection to another machine that runs agent_reader.py
/// there and answers "how are these agents doing?" one JSON line at a time.
/// The script only reads Claude Code and Codex logs; nothing is installed.
final class RemoteBridge {
    let sshHost: String

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var lines: [String] = []
    private let lock = NSLock()
    private let lineReady = DispatchSemaphore(value: 0)
    private var retryAfter: Date?

    init(sshHost: String) { self.sshHost = sshHost }

    deinit { stop() }

    /// Sends one request and waits for the reply. Returns nil if the machine
    /// can't be reached; it then waits a minute before trying again.
    func query(_ agents: [[String: Any]]) -> [String: [String: Any]]? {
        guard !agents.isEmpty else { return [:] }
        if process?.isRunning != true {
            guard start() else { return nil }
        }
        lock.lock(); lines.removeAll(); lock.unlock()
        while lineReady.wait(timeout: .now()) == .success {} // drop stale signals

        guard let body = try? JSONSerialization.data(withJSONObject: ["agents": agents]),
              let input else { return nil }
        do {
            try input.write(contentsOf: body + Data([0x0A]))
        } catch {
            fail()
            return nil
        }
        guard lineReady.wait(timeout: .now() + 10) == .success else {
            fail()
            return nil
        }
        lock.lock()
        let line = lines.isEmpty ? nil : lines.removeFirst()
        lock.unlock()
        guard let data = line?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
    }

    private func start() -> Bool {
        if let retryAfter, retryAfter > Date() { return false }
        guard let script = Self.script else { return false }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-T",
            "-o", "BatchMode=yes",          // never prompt; key-based only
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            sshHost,
            "python3 -u -c \"import base64;exec(base64.b64decode('\(script)'))\"",
        ]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(chunk)
            var complete = 0
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer[self.buffer.startIndex..<newline]
                self.buffer = Data(self.buffer[self.buffer.index(after: newline)...])
                if let line = String(data: lineData, encoding: .utf8) {
                    self.lines.append(line)
                    complete += 1
                }
            }
            self.lock.unlock()
            for _ in 0..<complete { self.lineReady.signal() }
        }
        do {
            try p.run()
        } catch {
            retryAfter = Date().addingTimeInterval(60)
            return false
        }
        process = p
        input = stdin.fileHandleForWriting
        lock.lock(); buffer = Data(); lock.unlock()
        return true
    }

    private func fail() {
        stop()
        retryAfter = Date().addingTimeInterval(60)
    }

    func stop() {
        if let p = process {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil
        input = nil
    }

    /// agent_reader.py from the app bundle, base64-encoded for the command line.
    private static let script: String? = {
        guard let url = Bundle.main.url(forResource: "agent_reader", withExtension: "py"),
              let data = try? Data(contentsOf: url) else { return nil }
        return data.base64EncodedString()
    }()
}
