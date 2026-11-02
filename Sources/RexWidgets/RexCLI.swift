import Foundation

/// Runs Rex's own `rex` command-line tool, its public interface for scripts.
enum RexCLI {
    static let path: String? = {
        let bundled = NSHomeDirectory()
            + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
        let candidates = [bundled, NSHomeDirectory() + "/.local/bin/rex", "/opt/homebrew/bin/rex", "/usr/local/bin/rex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    @discardableResult
    static func run(_ args: [String]) -> Data? {
        guard let path else { return nil }
        return Shell.run(path, ["--timeout", "3s"] + args)
    }

    static func json(_ args: [String]) -> [String: Any]? {
        guard let data = run(args) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum Shell {
    /// Our environment minus Rex's pane variables. When Rex's Tail is launched from a
    /// Rex pane it inherits REX_SESSION/REX_BLOCK, which would scope every `rex` call
    /// to that one session and hide panes in all the others.
    static let environment: [String: String] = ProcessInfo.processInfo.environment
        .filter { !$0.key.hasPrefix("REX_") }

    struct Result {
        var status: Int32
        var output: String
        var error: String
        var ok: Bool { status == 0 }
    }

    /// Runs a program, optionally feeding it standard input, and captures everything.
    static func capture(_ path: String, _ args: [String], input: String? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = environment
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return Result(status: -1, output: "", error: error.localizedDescription) }
        if let input {
            inp.fileHandleForWriting.write(Data(input.utf8))
            try? inp.fileHandleForWriting.close()
        }
        // Read stderr on the side so a chatty program can't fill one pipe and stall.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      output: String(decoding: outData, as: UTF8.self),
                      error: String(decoding: errData, as: UTF8.self))
    }

    /// Runs a shell script on another machine over SSH (key-based, never prompts).
    static func ssh(_ host: String, script: String) -> Result {
        capture("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", host, "sh -s"], input: script)
    }

    /// Runs a program and returns its standard output, or nil if it failed.
    static func run(_ path: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
