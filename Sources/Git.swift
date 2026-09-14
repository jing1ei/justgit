import Foundation
import Darwin

// MARK: - shell

struct RunResult {
    let code: Int32
    let out: String
    var err: String = ""
    var ok: Bool { code == 0 }
    var text: String { (out + err).trimmingCharacters(in: .whitespacesAndNewlines) }
    var value: String { ok ? out.trimmingCharacters(in: .newlines) : "" }
}

enum Shell {
    /// Drain both streams without letting prompts or inherited pipes block forever.
    static func run(_ exe: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 180,
                    environment: [String: String] = [:]) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var env = ProcessInfo.processInfo.environment
        // A JustGit opened from a shell must not inherit another repository's index
        // or work tree. Explicit test overrides are applied below.
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"] {
            env.removeValue(forKey: key)
        }
        env["GIT_TERMINAL_PROMPT"] = "0"          // never block on a login prompt
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"
        env["GIT_EDITOR"] = "/usr/bin/true"
        env["GIT_SEQUENCE_EDITOR"] = "/usr/bin/false"
        env["LC_ALL"] = "C"
        // Instrumented developer tools must not create profiling artifacts in
        // the repository merely because JustGit uses it as the working directory.
        env["LLVM_PROFILE_FILE"] = "/dev/null"
        if env["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15"
        }
        for (key, value) in environment { env[key] = value }
        p.environment = env

        let pipe = Pipe()
        let errors = Pipe()
        p.standardOutput = pipe
        p.standardError = errors
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch {
            return RunResult(code: 127, out: "cannot run \(exe): \(error.localizedDescription)\n")
        }

        pipe.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        let fd = pipe.fileHandleForReading.fileDescriptor
        let errorFD = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(errorFD, F_SETFL, O_NONBLOCK)
        defer {
            pipe.fileHandleForReading.closeFile()
            errors.fileHandleForReading.closeFile()
        }
        var data = Data()
        var errorData = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var eof = false
        var errorEOF = false
        while !eof || !errorEOF || p.isRunning {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { eof = true }
            let errorCount = read(errorFD, &buffer, buffer.count)
            if errorCount > 0 { errorData.append(contentsOf: buffer.prefix(errorCount)) }
            else if errorCount == 0 { errorEOF = true }
            else if errno != EAGAIN && errno != EINTR { errorEOF = true }
            if data.count + errorData.count > 8 * 1024 * 1024 {
                if p.isRunning { terminateTree(p.processIdentifier) }
                return RunResult(code: 125, out: String(decoding: data.prefix(32_000), as: UTF8.self)
                    + "\nOutput exceeded 8 MiB. Command stopped; inspect this repository in Terminal.\n")
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                // A hook or ssh child can inherit the pipe after its parent exits.
                // Never block on EOF, and stop descendants before the Git process.
                if p.isRunning {
                    if exe == "/bin/ps" { _ = Darwin.kill(p.processIdentifier, SIGKILL) }
                    else { terminateTree(p.processIdentifier) }
                }
                return RunResult(code: 124, out: String(decoding: data, as: UTF8.self)
                    + String(decoding: errorData, as: UTF8.self)
                    + "\nCommand timed out after \(timeout) seconds. Refresh before retrying.\n")
            }
            if count <= 0 && errorCount <= 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        p.waitUntilExit()
        return RunResult(code: p.terminationStatus, out: String(decoding: data, as: UTF8.self),
                         err: String(decoding: errorData, as: UTF8.self))
    }

    private static func terminateTree(_ pid: Int32) {
        let listing = run("/bin/ps", ["-axo", "pid=,ppid="], timeout: 2)
        let pairs = listing.out.split(separator: "\n").compactMap { line -> (Int32, Int32)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let child = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return (child, parent)
        }
        func stop(_ parent: Int32) {
            for (child, owner) in pairs where owner == parent { stop(child) }
            _ = Darwin.kill(parent, SIGKILL)
        }
        stop(pid)
    }
}

// MARK: - remote urls (ssh is the default everywhere)

enum RemoteURL {

    static func isSSH(_ s: String) -> Bool {
        sshTarget(s) != nil
    }

    static func isHTTP(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    /// https://host/org/repo(.git)  ->  git@host:org/repo.git
    /// host/org/repo               ->  git@host:org/repo.git
    /// already ssh / local path    ->  unchanged
    static func toSSH(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if s.lowercased().hasPrefix("ssh://") { return s }
        if sshTarget(s) != nil { return s }
        if s.hasPrefix("/") || s.hasPrefix(".") || s.hasPrefix("~") || s.hasPrefix("file://") { return s }
        let http = isHTTP(s)
        guard http || !s.contains("://"),
              let parts = URLComponents(string: http ? s : "https://" + s),
              let host = parts.host, !host.isEmpty,
              http || host.contains(".") else { return s }
        var path = String(parts.percentEncodedPath.dropFirst())
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return s }
        if host.contains(":") {
            let address = host.hasPrefix("[") ? host : "[\(host)]"
            return "ssh://git@\(address)/" + withGitSuffix(path)
        }
        return withGitSuffix("git@\(host):\(path)")
    }

    static func withGitSuffix(_ s: String) -> String {
        s.hasSuffix(".git") ? s : s + ".git"
    }

    static func redacted(_ s: String) -> String {
        guard s.contains("://"), var parts = URLComponents(string: s) else { return s }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? "(remote URL)"
    }

    /// host part, for `ssh -T git@host` connectivity tests
    static func host(_ s: String) -> String? {
        sshTarget(s)?.host ?? URLComponents(string: s)?.host
    }

    struct SSHTarget {
        let user: String
        let host: String
        let port: Int?
    }

    static func sshTarget(_ raw: String) -> SSHTarget? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("ssh://"),
           let parts = URLComponents(string: s), let host = parts.host, !host.isEmpty,
           parts.password == nil, parts.query == nil, parts.fragment == nil,
           !(parts.user?.isEmpty ?? false), !host.hasPrefix("-"),
           !host.contains(where: \.isWhitespace),
           parts.port == nil || (1...65535).contains(parts.port!) {
            return SSHTarget(user: parts.user ?? "git",
                             host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: parts.port)
        }
        guard !s.contains("://"), !s.hasPrefix("/"), !s.hasPrefix("."),
              let colon = s.firstIndex(of: ":") else { return nil }
        let authority = String(s[..<colon])
        let path = s[s.index(after: colon)...]
        guard !authority.isEmpty, !authority.contains("/"),
              !authority.hasPrefix("-"), !path.isEmpty, !path.hasPrefix(":"),
              !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !authority.contains(where: \.isWhitespace) else { return nil }
        let fields = authority.split(separator: "@", omittingEmptySubsequences: false)
        guard fields.count <= 2, fields.allSatisfy({ !$0.isEmpty }),
              let host = fields.last, !host.hasPrefix("-") else { return nil }
        return SSHTarget(user: fields.count == 2 ? String(fields[0]) : "git",
                         host: String(host), port: nil)
    }

    static func connectionTarget(_ raw: String) -> SSHTarget? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if s.contains("://") { return sshTarget(s) }
        // A bare host/user@host and optional numeric port is a test destination,
        // not a scp repository path.
        if !s.contains("/"), let target = sshTarget("ssh://" + s) { return target }
        return sshTarget(s)
    }
}

// MARK: - repo state

struct RepoStatus {
    var isRepo = false
    var top = ""
    var branch = "-"
    var detached = false
    var remote = ""
    var hasCommits = false
    var changed = 0
    var ahead = 0
    var behind = 0
    var shortStatus = ""
    var recentLog = ""
    var error = ""
    var operation = ""
    var conflicts = false

    var dirty: Bool { changed > 0 }
    var remoteIsSSH: Bool { RemoteURL.isSSH(remote) }
    var hasRemote: Bool { !remote.isEmpty }
}

final class Git {

    /// Immutable: `status()` runs on a background queue, and a mutable path
    /// would be a data race. When the toplevel turns out to be somewhere else,
    /// the controller swaps in a new Git rather than editing this one.
    let path: String
    let environment: [String: String]
    init(_ path: String, environment: [String: String] = [:]) {
        self.path = path
        self.environment = environment
    }

    @discardableResult
    func run(_ args: [String], timeout: TimeInterval = 180) -> RunResult {
        Shell.run("/usr/bin/git", args, cwd: path, timeout: timeout, environment: environment)
    }

    private func line(_ args: [String]) -> String { run(args).value }

    static var installed: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

    /// Does this ref resolve? Cheap, and the honest way to ask "is origin/x there".
    func hasRef(_ ref: String) -> Bool {
        run(["rev-parse", "--verify", "-q", ref + "^{commit}"]).ok
    }

    /// Porcelain v2 supplies branch and file state. Additional reads resolve the
    /// working tree, operation markers, origin counts and optional recent log.
    ///
    /// Does not mutate the receiver, so it is safe to call from a background
    /// queue; `top` comes back in the result for the caller to apply on main.
    func status(recentLog wantLog: Bool = true) -> RepoStatus {
        var s = RepoStatus()

        // `--show-toplevel` fails outside a work tree, so it doubles as the repo test
        let top = run(["rev-parse", "--show-toplevel"])
        s.top = top.value
        guard !s.top.isEmpty else {
            if !top.text.contains("not a git repository") { s.error = top.text }
            return s
        }
        s.isRepo = true

        let dir = s.top
        func git(_ args: [String]) -> RunResult {
            Shell.run("/usr/bin/git", args, cwd: dir, environment: environment)
        }

        // Safety checks must not inherit settings that hide files or submodules.
        let st = git(["-c", "core.quotePath=false", "status", "--porcelain=v2", "--branch",
                      "--untracked-files=all", "--ignore-submodules=none"])
        guard st.ok else { s.error = st.text; return s }
        var changes: [String] = []
        for raw in st.out.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(raw)
            guard l.hasPrefix("#") else {
                if ["1 ", "2 ", "u ", "? "].contains(where: l.hasPrefix) { changes.append(l) }
                continue
            }
            let f = l.split(separator: " ").map(String.init)
            guard f.count >= 3, f[0] == "#" else { continue }
            switch f[1] {
            case "branch.oid":
                s.hasCommits = f[2] != "(initial)"
            case "branch.head":
                s.detached = f[2] == "(detached)"
                s.branch = f[2]
            default: break
            }
        }
        s.changed = changes.count
        s.shortStatus = Git.shortForm(changes)
        s.conflicts = changes.contains { $0.hasPrefix("u ") }
        let gitDirResult = git(["rev-parse", "--absolute-git-dir"])
        guard gitDirResult.ok, !gitDirResult.value.isEmpty else {
            s.error = gitDirResult.text.isEmpty ? "Could not locate repository metadata." : gitDirResult.text
            return s
        }
        let gitDir = gitDirResult.value
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent(name))
        }
        if exists("rebase-apply/applying") { s.operation = "am" }
        else if exists("rebase-merge") || exists("rebase-apply") { s.operation = "rebase" }
        else if exists("MERGE_HEAD") { s.operation = "merge" }
        else if exists("CHERRY_PICK_HEAD") { s.operation = "cherry-pick" }
        else if exists("REVERT_HEAD") { s.operation = "revert" }
        else if exists("sequencer") {
            let todo = try? String(contentsOfFile: gitDir + "/sequencer/todo", encoding: .utf8)
            if todo?.hasPrefix("revert ") == true { s.operation = "revert" }
            else if todo?.hasPrefix("pick ") == true { s.operation = "cherry-pick" }
            else { s.error = "An unfinished Git sequence exists. Inspect git status in Terminal before proceeding." }
        }

        if s.detached {
            s.branch = "detached@" + (git(["rev-parse", "--short", "HEAD"]).value)
        }
        s.remote = git(["remote", "get-url", "origin"]).value
        // Counts must describe the same origin/current-branch destination as the
        // buttons, even if a repository had a different upstream configured.
        s.ahead = 0
        s.behind = 0
        if s.hasCommits && !s.detached {
            let counts = git(["rev-list", "--left-right", "--count",
                              "HEAD...refs/remotes/origin/\(s.branch)"]).value
                .split(whereSeparator: \.isWhitespace)
            if counts.count == 2 {
                s.ahead = Int(counts[0]) ?? 0
                s.behind = Int(counts[1]) ?? 0
            }
        }
        if wantLog && s.hasCommits {
            s.recentLog = git(["--no-pager", "log", "--oneline", "-n", "8", "--decorate"]).out
        }
        return s
    }

    /// porcelain v2 is machine-shaped; the log well wants the familiar
    /// `git status -s` look. Field counts differ per record type:
    ///   1 XY sub mH mI mW hH hI <path>                        → path at 8
    ///   2 XY sub mH mI mW hH hI <X><score> <path>TAB<orig>     → path at 9
    ///   u XY sub m1 m2 m3 mW h1 h2 h3 <path>                   → path at 10
    /// Splitting with maxSplits = index keeps the (unquoted, space-bearing)
    /// path intact as the final component.
    static func shortForm(_ lines: [String]) -> String {
        func tail(_ l: String, after n: Int) -> String? {
            let f = l.split(separator: " ", maxSplits: n, omittingEmptySubsequences: false)
            return f.count > n ? String(f[n]) : nil
        }
        var out: [String] = []
        for l in lines {
            let kind = l.prefix(1)
            let xy = l.dropFirst(2).prefix(2).replacingOccurrences(of: ".", with: " ")
            switch kind {
            case "1":
                if let p = tail(l, after: 8) { out.append("\(xy) \(p)") }
            case "2":
                // "new<TAB>old" — show the new name, that is what the user sees on disk
                if let p = tail(l, after: 9) {
                    out.append("\(xy) \(p.split(separator: "\t").first.map(String.init) ?? p)")
                }
            case "u":
                if let p = tail(l, after: 10) { out.append("\(xy) \(p)") }
            case "?":
                out.append("?? \(l.dropFirst(2))")
            case "!":
                break                                          // ignored files, never requested
            default:
                break
            }
        }
        return out.joined(separator: "\n")
    }

    var totalCommits: Int { Int(line(["rev-list", "--first-parent", "--count", "HEAD"])) ?? 0 }

    var identityOK: Bool {
        run(["var", "GIT_AUTHOR_IDENT"]).ok && run(["var", "GIT_COMMITTER_IDENT"]).ok
    }

    /// Keep mac junk and the usual build noise out of a brand-new repo.
    func writeIgnore() throws {
        let gi = (path as NSString).appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: gi) {
            let body = """
            .DS_Store
            ._*
            .Spotlight-V100
            .Trashes
            Thumbs.db

            node_modules/
            __pycache__/
            *.log
            *.tmp
            .env
            """
            try body.write(toFile: gi, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - global git config / ssh setup

enum GitEnv {

    static func globalConfig(_ key: String) -> String {
        Shell.run("/usr/bin/git", ["config", "--global", "--get", key]).value
    }

    static func setGlobal(_ key: String, _ value: String) -> RunResult {
        Shell.run("/usr/bin/git", ["config", "--global", key, value])
    }

    static var version: String {
        let v = Shell.run("/usr/bin/git", ["--version"]).text
        return v.isEmpty ? "not installed" : v
    }

    static var keyPath: String { (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519") }
    static var pubKeyPath: String { keyPath + ".pub" }
    static var hasKey: Bool { FileManager.default.fileExists(atPath: keyPath) }

    static var publicKey: String {
        (try? String(contentsOfFile: pubKeyPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @discardableResult
    static func createKey(comment: String) -> RunResult {
        if hasKey { return recoverPublicKey() }
        guard !FileManager.default.fileExists(atPath: pubKeyPath) else {
            return RunResult(code: 1, out: "A public key already exists without its private key. Preserve or move \(pubKeyPath), then retry; it will not be overwritten.")
        }
        let ssh = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        do {
            try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return RunResult(code: 1, out: error.localizedDescription) }
        let r = Shell.run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-C", comment, "-f", keyPath, "-N", ""], timeout: 60)
        if r.ok {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
                try writeSSHConfig()
            } catch {
                return RunResult(code: 1, out: "Key created, but SSH config could not be updated: \(error.localizedDescription). Copy the public key; inspect ~/.ssh/config in Terminal.")
            }
            let added = Shell.run("/usr/bin/ssh-add", ["--apple-use-keychain", keyPath], timeout: 30)
            if !added.ok {
                return RunResult(code: added.code, out: "Key created, but the agent could not load it:\n" + added.text
                    + "\nRetry in Terminal: ssh-add --apple-use-keychain " + GitWorkflow.quote(keyPath))
            }
        }
        return r
    }

    static func recoverPublicKey() -> RunResult {
        let result = Shell.run("/usr/bin/ssh-keygen", ["-y", "-P", "", "-f", keyPath], timeout: 20)
        guard result.ok else {
            return RunResult(code: result.code, out: result.text
                + "\nFor an encrypted key, recover it in Terminal:\nssh-keygen -y -f "
                + GitWorkflow.quote(keyPath) + " > " + GitWorkflow.quote(pubKeyPath))
        }
        do { try (result.value + "\n").write(toFile: pubKeyPath, atomically: true, encoding: .utf8) }
        catch { return RunResult(code: 1, out: error.localizedDescription) }
        return result
    }

    static func writeSSHConfig() throws {
        let cfg = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
        let block = """

        # --- JustGit ---
        Host *
          AddKeysToAgent yes
          UseKeychain yes
          IdentityFile "\(keyPath)"

        """
        let current = FileManager.default.fileExists(atPath: cfg)
            ? try String(contentsOfFile: cfg, encoding: .utf8) : ""
        if current.contains("# --- JustGit ---") { return }
        try (current + block).write(toFile: cfg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfg)
    }

    static func testConnection(host: String) -> RunResult {
        let target = RemoteURL.connectionTarget(host)
        guard let target = target, !target.host.isEmpty, !target.host.hasPrefix("-"),
              !target.host.contains(where: \.isWhitespace), !target.user.isEmpty else {
            return RunResult(code: 2, out: "Enter a hostname or an ssh://user@host:port/repo URL.")
        }
        var args = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=15", "-T"]
        if let port = target.port { args += ["-p", String(port)] }
        args += ["-l", target.user, target.host]
        return Shell.run("/usr/bin/ssh", args, timeout: 40)
    }

    static func connectionSucceeded(_ result: RunResult) -> Bool {
        if result.ok { return true }
        guard result.code == 1 else { return false }
        let out = result.text.lowercased()
        return out.contains("successfully authenticated") || out.contains("welcome to gitlab")
            || out.contains("authenticated via ssh key")
    }
}
