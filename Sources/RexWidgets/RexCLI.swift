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
    /// Runs a program and returns its standard output, or nil if it failed.
    static func run(_ path: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
