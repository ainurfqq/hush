import Foundation

public struct ShellResult { public var status: Int32; public var stdout: String; public var stderr: String }

public enum Shell {
    /// Directories searched for tools. GUI apps get a bare PATH, so common install dirs are listed explicitly.
    public static var searchDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let envPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return envPath + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local",
                          "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "/usr/bin", "/bin"]
    }

    public static func which(_ name: String, override: String = "") -> String? {
        let fm = FileManager.default
        if !override.isEmpty {
            let p = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        for d in searchDirs {
            let p = (d as NSString).appendingPathComponent(name)
            // Skip editor/terminal shims that only forward to a missing binary (e.g. cmux shims).
            if fm.isExecutableFile(atPath: p), !p.contains("cli-shims") { return p }
        }
        return nil
    }

    /// Runs a program, feeding `stdin`, with a timeout. Never goes through a shell, so arguments are not re-parsed.
    @discardableResult
    public static func run(_ exe: String, _ args: [String], stdin: String? = nil, timeout: TimeInterval = 600,
                           env: [String: String]? = nil, cwd: String? = nil) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = searchDirs.joined(separator: ":")
        if let env { for (k, v) in env { e[k] = v } }
        p.environment = e
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe; p.standardInput = inPipe
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        try p.run()
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); usleep(300_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        group.wait()
        if Date() >= deadline { throw HushError.engine("\((exe as NSString).lastPathComponent) timed out after \(Int(timeout)) s") }
        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }
}

extension Shell {
    private static var loginEnvCache: [String: String] = [:]
    private static let loginEnvLock = NSLock()

    /// Value of `name` in the user's login shell, or nil. Cached. Apps started from Finder do not see
    /// variables exported in ~/.zshrc, so this bridges e.g. CLAUDE_CONFIG_DIR.
    public static func loginShellVar(_ name: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        loginEnvLock.lock(); defer { loginEnvLock.unlock() }
        if let v = loginEnvCache[name] { return v.isEmpty ? nil : v }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__HUSH__"
        let r = try? Shell.run(shell, ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$\(name)\""], timeout: 8)
        var value = ""
        if let out = r?.stdout, let a = out.range(of: marker), let b = out.range(of: marker, range: a.upperBound..<out.endIndex) {
            value = String(out[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        loginEnvCache[name] = value
        return value.isEmpty ? nil : value
    }
}

public enum Log {
    private static let lock = NSLock()
    public static var echo = false
    public static func write(_ msg: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        let dir = Paths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hush.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}
