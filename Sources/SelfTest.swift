import AppKit

/// Isolated parsing, process, repository-workflow and native-layout checks.
/// Exits nonzero on failure so the installer cannot publish a failing build.
enum SelfTest {

    /// True when the app was launched to run tests, not to be used by a human.
    /// The main window must not pop dialogs at a script.
    static let headless = CommandLine.arguments.contains("--selftest")

    private static var failures = 0
    private static var checks = 0

    private static let u = "git@"

    private static func eq(_ what: String, _ got: String, _ want: String) {
        checks += 1
        let pass = got == want
        if !pass { failures += 1 }
        print("  \(pass ? "ok  " : "FAIL") \(what)")
        if !pass { print("       got  \(got)\n       want \(want)") }
    }

    private static func eq(_ what: String, _ got: Double, _ want: Double) {
        eq(what, String(format: "%g", got), String(format: "%g", want))
    }

    private static func yes(_ what: String, _ condition: Bool) {
        checks += 1
        if !condition { failures += 1 }
        print("  \(condition ? "ok  " : "FAIL") \(what)")
    }

    /// Runs every check and terminates with a meaningful exit code.
    static func run() -> Never {
        setbuf(stdout, nil)
        print("remote urls → ssh")
        eq("https with .git",
           RemoteURL.toSSH("https://github.com/org/repo.git"), u + "github.com:org/repo.git")
        eq("https without .git",
           RemoteURL.toSSH("https://github.com/org/repo"), u + "github.com:org/repo.git")
        eq("credentials stripped, nested path kept",
           RemoteURL.toSSH("http://user:token@gitlab.example.com/team/sub/repo"),
           u + "gitlab.example.com:team/sub/repo.git")
        eq("port and trailing slash dropped",
           RemoteURL.toSSH("https://code.example.com:443/org/repo/"), u + "code.example.com:org/repo.git")
        eq("bare host/org/repo",
           RemoteURL.toSSH("github.com/org/repo"), u + "github.com:org/repo.git")
        eq("scp-style stays byte-for-byte unchanged",
           RemoteURL.toSSH(u + "host.com:org/repo"), u + "host.com:org/repo")
        eq("ssh:// untouched",
           RemoteURL.toSSH("ssh://" + u + "host.com:2222/org/repo.git"),
           "ssh://" + u + "host.com:2222/org/repo.git")
        eq("local path untouched",
           RemoteURL.toSSH("/tmp/local/bare.git"), "/tmp/local/bare.git")
        eq("a single word is not a url", RemoteURL.toSSH("repo"), "repo")
        eq("empty stays empty", RemoteURL.toSSH(""), "")
        eq("host of scp-style", RemoteURL.host(u + "github.com:o/r.git") ?? "-", "github.com")
        eq("host of ssh://", RemoteURL.host("ssh://" + u + "host.com:22/o/r") ?? "-", "host.com")
        eq("custom scp user and namespace preserved",
           RemoteURL.toSSH("testuser@example.invalid:org/repo"), "testuser@example.invalid:org/repo")
        eq("HTTP query and fragment discarded",
           RemoteURL.toSSH("https://host.com/org/repo?tab=readme#top"), u + "host.com:org/repo.git")
        eq("HTTP host alias converted", RemoteURL.toSSH("https://gitserver/team/repo"), u + "gitserver:team/repo.git")
        eq("custom SSH user", RemoteURL.sshTarget("ssh://testuser@host:2222/repo")?.user ?? "", "testuser")
        eq("custom SSH port", Double(RemoteURL.sshTarget("ssh://testuser@host:2222/repo")?.port ?? 0), 2222)
        eq("bare SSH test user", RemoteURL.connectionTarget("testuser@host")?.user ?? "", "testuser")
        eq("bare SSH test port", Double(RemoteURL.connectionTarget("host:2222")?.port ?? 0), 2222)
        yes("SSH remote helpers rejected", !RemoteURL.isSSH("ext::command"))
        yes("empty SSH user rejected", !RemoteURL.isSSH("@host:repo"))
        yes("empty SSH repository rejected", !RemoteURL.isSSH("git@host:"))
        yes("SSH password rejected", !RemoteURL.isSSH("ssh://user:password@host/repo"))
        yes("invalid SSH port rejected", !RemoteURL.isSSH("ssh://git@host:99999/repo"))
        eq("IPv6 HTTP conversion", RemoteURL.toSSH("https://[::1]/org/repo"), "ssh://git@[::1]/org/repo.git")
        eq("IPv6 SSH target", RemoteURL.sshTarget("ssh://git@[::1]:2222/repo")?.host ?? "", "::1")
        yes("local path is not SSH", !RemoteURL.isSSH("./folder:name/repo"))
        yes("DNS failure is not success", !GitEnv.connectionSucceeded(RunResult(code: 255, out: "Could not resolve hostname")))
        yes("timeout is not success", !GitEnv.connectionSucceeded(RunResult(code: 124, out: "")))
        yes("GitHub's exit-one greeting is success",
            GitEnv.connectionSucceeded(RunResult(code: 1, out: "You've successfully authenticated, but GitHub does not provide shell access.")))

        print("\nskin files")
        let base = Theme.atelier

        yes("our own file round-trips unchanged", Theme.parse(base.json, base: base).theme == base)
        yes("our own file raises no complaints", Theme.parse(base.json, base: base).problems.isEmpty)

        let fenced = Theme.parse("""
        Sure! Here's a moodier take:

        ```json
        { "name": "Dusk", "accent": "#7A4B9C" }
        ```
        Hope you like it!
        """, base: base)
        eq("code fence and chatter stripped", fenced.theme.accent, "#7A4B9C")
        eq("unmentioned keys keep their value", fenced.theme.canvas, base.canvas)

        let partial = Theme.parse("{\"ink\": \"#000000\", \"sizeUI\": 15}", base: base)
        eq("a two-key file is legal", partial.theme.ink, "#000000")
        eq("…and leaves the rest alone", partial.theme.rule, base.rule)
        yes("a real skin is flagged as JSON", partial.isJSON)

        let short = Theme.parse("{\"accent\": \"#f0a\", \"rule\": \"cccccc\"}", base: base)
        eq("#rgb shorthand expands", short.theme.accent, "#FF00AA")
        eq("a missing # is forgiven", short.theme.rule, "#CCCCCC")

        let bad = Theme.parse("{\"accent\": \"burnt sienna\"}", base: base)
        eq("a nonsense colour keeps the old one", bad.theme.accent, base.accent)
        yes("…and says so", !bad.problems.isEmpty)

        eq("an uninstalled font falls back to the system one",
           Theme.parse("{\"fontUI\": \"__JustGitMissingFont__\"}", base: base).theme.fontUI, "system")

        let sizes = Theme.parse("{\"sizeUI\": 96, \"sizeMono\": 2}", base: base)
        eq("an absurd size is clamped down", sizes.theme.sizeUI, 17)
        eq("an absurd size is clamped up", sizes.theme.sizeMono, 9)
        for value in ["nan", "inf", "-inf"] {
            let result = Theme.parse("{\"sizeUI\":\"\(value)\"}", base: base)
            eq("nonfinite \(value) is rejected", result.theme.sizeUI, base.sizeUI)
            yes("nonfinite value remains serializable", Theme.parse(result.theme.json).isJSON)
        }
        eq("huge finite size clamps without integer overflow",
           Theme.parse("{\"sizeUI\":1e100}", base: base).theme.sizeUI, 17)
        eq("boolean is not a font size", Theme.parse("{\"sizeUI\":true}", base: base).theme.sizeUI, base.sizeUI)
        yes("non-ASCII hex digits are rejected", Hex.normalise("#１２３") == nil)

        let invented = Theme.parse("{\"padding\": 40, \"cornerRadius\": 18, \"ink\": \"#111111\"}", base: base)
        eq("layout keys are ignored, not obeyed", invented.theme.ink, "#111111")
        yes("…and reported", invented.problems.contains { $0.contains("unknown key") })

        let prose = Theme.parse("Not a JSON object.", base: base)
        yes("prose changes nothing", prose.theme == base)
        yes("prose is flagged as not-JSON", !prose.isJSON)

        yes("an unreadable skin still applies, with a warning",
            !Theme.parse("{\"ink\": \"#F4F1EA\", \"canvas\": \"#F2EEE6\"}", base: base).problems.isEmpty)

        // A name full of JSON metacharacters has to survive a write/read cycle,
        // or the app writes a file it can no longer read back.
        let awkward = Theme.parse("{\"name\": \"He said \\\"hi\\\"\\\\then left\"}", base: base)
        let reread = Theme.parse(awkward.theme.json, base: base)
        yes("an awkward name still produces valid JSON", reread.isJSON)
        eq("…and survives the round trip", reread.theme.name, awkward.theme.name)
        yes("a newline in a name is flattened", !awkward.theme.name.contains("\n"))
        let backticks = Theme.parse("{\"name\":\"literal ``` braces {}\"}", base: base)
        eq("backticks inside JSON remain literal", backticks.theme.name, "literal ``` braces {}")
        yes("skin with backticks round-trips", Theme.parse(backticks.theme.json, base: base).theme == backticks.theme)
        yes("JSON arrays are not accepted as skin objects", !Theme.parse("[{\"name\":\"invalid\"}]", base: base).isJSON)

        print("\nbuilt-in skins are legible")
        for p in Theme.presets { yes(p.name, p.legibilityWarnings().isEmpty) }

        print("\nporcelain v2 → the familiar short form")
        // real records, copied from `git status --porcelain=v2`
        eq("modified file",
           Git.shortForm(["1 .M N... 100644 100644 100644 abc123 abc123 notes.txt"]), " M notes.txt")
        eq("staged add",
           Git.shortForm(["1 A. N... 000000 100644 100644 000000 def456 new.txt"]), "A  new.txt")
        eq("a space in the path survives",
           Git.shortForm(["1 .M N... 100644 100644 100644 a a My Great File.txt"]), " M My Great File.txt")
        eq("rename shows the new name",
           Git.shortForm(["2 R. N... 100644 100644 100644 a b R100 new name.txt\told name.txt"]),
           "R  new name.txt")
        eq("conflict", Git.shortForm(["u UU N... 100644 100644 100644 100644 a b c both.txt"]), "UU both.txt")
        eq("untracked", Git.shortForm(["? junk.log"]), "?? junk.log")
        eq("ignored lines are dropped", Git.shortForm(["! build/"]), "")

        print("\ngit talks to a real repo")
        repoChecks()
        workflowChecks()
        print("\nprocess deadlines")
        let start = ProcessInfo.processInfo.systemUptime
        let timed = Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 10"], timeout: 0.15)
        eq("TERM-resistant process times out", Double(timed.code), 124)
        yes("timeout is bounded", ProcessInfo.processInfo.systemUptime - start < 4)
        let pipeStart = ProcessInfo.processInfo.systemUptime
        let inherited = Shell.run("/bin/sh", ["-c", "sleep 1 & exit 0"], timeout: 0.1)
        eq("inherited pipe times out", Double(inherited.code), 124)
        yes("inherited pipe cannot block forever", ProcessInfo.processInfo.systemUptime - pipeStart < 2)
        let streams = Shell.run("/bin/sh", ["-c", "printf value; printf warning >&2"])
        eq("stderr cannot contaminate parsed stdout", streams.value, "value")
        yes("stderr remains visible in diagnostics", streams.text.contains("warning"))
        layoutChecks()

        print("\n\(checks - failures)/\(checks) passed\(failures > 0 ? "  —  \(failures) FAILED" : "")")
        exit(failures == 0 ? 0 : 1)
    }

    /// Build a throwaway repo in /tmp and read it back, which is the only way
    /// to know that `status()` agrees with the git that is actually installed.
    private static func repoChecks() {
        guard Git.installed else { yes("git installed", false); return }
        let fm = FileManager.default
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("justgit-selftest-" + UUID().uuidString)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        let g = Git(dir, environment: testEnvironment(home: dir))
        yes("a plain folder is not a repo", !g.status().isRepo)

        _ = g.run(["init", "-b", "main"])
        _ = g.run(["config", "user.name", "JustGit Selftest"])
        _ = g.run(["config", "user.email", "selftest@example.com"])
        _ = g.run(["config", "status.showUntrackedFiles", "no"])
        var s = g.status()
        yes("after init it is a repo", s.isRepo)
        eq("on branch main", s.branch, "main")
        yes("no commits yet", !s.hasCommits)
        yes("no remote yet", !s.hasRemote)

        let file = (dir as NSString).appendingPathComponent("a file.txt")
        try? "hello\n".write(toFile: file, atomically: true, encoding: .utf8)
        s = g.status()
        eq("one untracked file", Double(s.changed), 1)
        yes("dirty", s.dirty)
        yes("…and named, spaces and all", s.shortStatus.contains("a file.txt"))
        yes("status overrides hidden untracked files", s.changed == 1)

        _ = g.run(["add", "-A"])
        _ = g.run(["commit", "-m", "first"])
        s = g.status()
        yes("clean after committing", !s.dirty)
        yes("has commits", s.hasCommits)
        eq("one commit", Double(g.totalCommits), 1)
        yes("HEAD resolves", g.hasRef("HEAD"))
        yes("a branch that does not exist does not resolve", !g.hasRef("origin/nope"))

        _ = g.run(["remote", "add", "origin", "https://example.com/o/r.git"])
        s = g.status()
        eq("remote is reported", s.remote, "https://example.com/o/r.git")
        yes("…and is not SSH yet", !s.remoteIsSSH)

        _ = g.run(["checkout", "--detach", "HEAD"])
        yes("detached HEAD is noticed", g.status().detached)
    }

    private static func testEnvironment(home: String) -> [String: String] {
        ["HOME": home, "XDG_CONFIG_HOME": home, "GIT_CONFIG_GLOBAL": "/dev/null",
         "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0",
         "GIT_AUTHOR_NAME": "JustGit Selftest", "GIT_AUTHOR_EMAIL": "selftest@example.com",
         "GIT_COMMITTER_NAME": "JustGit Selftest", "GIT_COMMITTER_EMAIL": "selftest@example.com"]
    }

    private static func layoutChecks() {
        print("\nnative window layout")
        _ = NSApplication.shared
        let controller = MainController(restoreLast: false)
        let setup = SetupWindow()
        setup.build()
        let skin = SkinWindow()
        skin.build()
        for window in [controller.window, setup.window, skin.window].compactMap({ $0 }) {
            window.setContentSize(window.contentMinSize)
            window.contentView?.layoutSubtreeIfNeeded()
            var clipped: [String] = []
            var panelActions: [Selector] = []
            func inspect(_ view: NSView) {
                if let button = view as? SkinButton, !button.isHidden,
                   button.frame.width + 1 < button.intrinsicContentSize.width {
                    clipped.append(button.title)
                }
                if let button = view as? NSButton, let action = button.action { panelActions.append(action) }
                for child in view.subviews { inspect(child) }
            }
            if let content = window.contentView { inspect(content) }
            yes("\(window.title) buttons fit at minimum size: \(clipped.joined(separator: ", "))", clipped.isEmpty)
            yes("\(window.title) minimum remains practical: \(window.contentMinSize)",
                window.contentMinSize.width <= 1100 && window.contentMinSize.height <= 850)
            if window === controller.window {
                yes("Setup is not a main-panel button", !panelActions.contains(#selector(MainController.openSetup)))
                yes("Skin is not a main-panel button", !panelActions.contains(#selector(MainController.openSkin)))
                // Advanced’s items used to run their handler directly, so Squash
                // opened its alerts from inside the menu’s own tracking session and
                // they stalled behind the panel. Every item must go through the
                // shim that waits for the menu to close.
                let deferred = controller.advancedMenuItems
                yes("Advanced items defer out of menu tracking",
                    !deferred.isEmpty && deferred.allSatisfy {
                        $0.action == #selector(MainController.advancedPicked(_:))
                            && $0.representedObject is Selector
                    })
                if let snapshot = ProcessInfo.processInfo.environment["JUSTGIT_UI_SNAPSHOT"],
                   let content = window.contentView {
                    window.setContentSize(NSSize(width: 860, height: 620))
                    content.layoutSubtreeIfNeeded()
                    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        do {
                            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshot))
                            print("UI snapshot: \(snapshot)")
                        } catch { yes("write UI snapshot: \(error)", false) }
                    }
                }
            }
            window.orderOut(nil)
        }
    }

    private static func workflowChecks() {
        print("\nworkflow safety and recovery")
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("justgit-workflows-" + UUID().uuidString)
        do { try fm.createDirectory(atPath: root, withIntermediateDirectories: true) }
        catch { yes("create test directory: \(error)", false); return }
        defer { try? fm.removeItem(atPath: root) }
        let env = testEnvironment(home: root)
        func repo(_ name: String, bare: Bool = false) -> Git {
            let path = (root as NSString).appendingPathComponent(name)
            do { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
            catch { yes("create \(name)", false) }
            let git = Git(path, environment: env)
            yes("init \(name)", git.run(bare ? ["init", "--bare", "-b", "main"] : ["init", "-b", "main"]).ok)
            return git
        }
        func write(_ git: Git, _ path: String, _ text: String) {
            do { try text.write(toFile: (git.path as NSString).appendingPathComponent(path), atomically: true, encoding: .utf8) }
            catch { yes("write \(path): \(error)", false) }
        }
        func head(_ git: Git) -> String { git.run(["rev-parse", "--verify", "HEAD"]).value }
        func read(_ git: Git, _ path: String) -> String {
            (try? String(contentsOfFile: (git.path as NSString).appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        let local = repo("local")
        let remote = repo("remote.git", bare: true)
        let peer = repo("peer")
        let work = GitWorkflow(local)
        write(local, "file.txt", "base\n")
        yes("initial workflow commit", work.commit(message: "base") == .committed)
        yes("no-op commit", work.commit(message: "nothing") == .nothingToDo)
        yes("test identity resolves without global config", local.identityOK)
        yes("set local origin", local.run(["remote", "add", "origin", remote.path]).ok)
        yes("first sync creates missing remote branch", work.sync(branch: "main", message: "noop").ok)
        yes("set peer origin", peer.run(["remote", "add", "origin", remote.path]).ok)
        yes("pull into empty clean branch", GitWorkflow(peer).pull(branch: "main").ok)
        var switchedDuringFetch = false
        let changing = GitWorkflow(local, output: { line in
            if line.hasPrefix("$ git 'fetch'"), !switchedDuringFetch {
                switchedDuringFetch = local.run(["switch", "-c", "during-fetch"]).ok
            }
        })
        yes("pull refuses branch changes during fetch", !changing.pull(branch: "main").ok)
        yes("branch-change fixture ran", switchedDuringFetch)
        eq("pull does not switch back or rebase another branch", local.status().branch, "during-fetch")
        yes("restore branch after fetch test", local.run(["switch", "main"]).ok)

        yes("add second origin URL", local.run(["config", "--add", "remote.origin.url", root + "/unused.git"]).ok)
        yes("multiple origin URLs are rejected before pushing", !work.push(branch: "main").ok)
        yes("add separate push URL", local.run(["config", "--add", "remote.origin.pushurl", root + "/push.git"]).ok)
        yes("repair multiple origin URLs", work.setOrigin(remote.path).ok)
        eq("origin has exactly one URL", local.run(["config", "--get-all", "remote.origin.url"]).value, remote.path)
        yes("push URL override removed", local.run(["config", "--get-all", "remote.origin.pushurl"]).code == 1)

        let originalHead = head(local)
        write(local, ".git/index.lock", "locked\n")
        write(local, "file.txt", "should not commit\n")
        yes("staging failure stops commit", work.commit(message: "must not commit") == .failed)
        var commands: [String] = []
        let logged = GitWorkflow(local, output: { commands.append($0) })
        yes("sync stops after failed staging", !logged.sync(branch: "main", message: "must not sync").ok)
        yes("failed commit never fetches or pushes", !commands.contains { $0.contains("'fetch'") || $0.contains("'push'") })
        eq("failed staging preserves HEAD", head(local), originalHead)
        try? fm.removeItem(atPath: local.path + "/.git/index.lock")
        yes("restore local fixture", local.run(["restore", "file.txt"]).ok)

        write(local, "local.txt", "local\n")
        yes("local extra commit", work.commit(message: "local") == .committed)
        let beforeFetchFailure = head(local)
        yes("break remote path", local.run(["remote", "set-url", "origin", root + "/missing.git"]).ok)
        commands.removeAll()
        yes("sync stops on failed fetch", !logged.sync(branch: "main", message: "noop").ok)
        yes("failed pull never pushes", !commands.contains { $0.contains("'push'") })
        write(local, "file.txt", "keep dirty content\n")
        yes("force pull refuses failed fetch with stale tracking ref", !work.forcePull(branch: "main").ok)
        eq("fetch failure preserves branch", head(local), beforeFetchFailure)
        eq("fetch failure preserves dirty file", read(local, "file.txt"), "keep dirty content\n")
        yes("force push cannot preview failed remote", work.previewForcePush(branch: "main") == nil)
        yes("restore origin", local.run(["remote", "set-url", "origin", remote.path]).ok)

        write(local, ".git/index.lock", "locked\n")
        yes("force pull refuses failed stash", !work.forcePull(branch: "main").ok)
        eq("stash failure preserves dirty file", read(local, "file.txt"), "keep dirty content\n")
        eq("stash failure preserves branch", head(local), beforeFetchFailure)
        try? fm.removeItem(atPath: local.path + "/.git/index.lock")
        write(local, ".git/info/exclude", "ignored.txt\n")
        write(local, "ignored.txt", "precious ignored data\n")
        write(local, "untracked.txt", "precious untracked data\n")
        yes("force pull succeeds with backup and all-file stash", work.forcePull(branch: "main").ok)
        eq("force pull reaches fetched commit", head(local), originalHead)
        let stash = local.run(["rev-parse", "refs/stash"]).value
        yes("stash ref exists", !stash.isEmpty)
        eq("ignored file saved in stash", local.run(["show", "\(stash)^3:ignored.txt"]).value, "precious ignored data")
        eq("untracked file saved in stash", local.run(["show", "\(stash)^3:untracked.txt"]).value, "precious untracked data")
        eq("tracked edit saved in stash", local.run(["show", "\(stash):file.txt"]).value, "keep dirty content")
        yes("backup branch exists", local.run(["branch", "--list", "backup-*"]).value.contains("backup-"))

        let preview = work.previewForcePush(branch: "main")
        yes("force push preview succeeds", preview != nil)
        write(peer, "peer.txt", "remote update\n")
        yes("peer commit", GitWorkflow(peer).commit(message: "peer") == .committed)
        yes("peer push", GitWorkflow(peer).push(branch: "main").ok)
        yes("simulate independent fetch during confirmation", local.run(["fetch", "origin"]).ok)
        if let preview = preview {
            yes("explicit lease rejects unseen remote update", !work.forcePush(preview, hard: false).ok)
            eq("rejected force push preserves remote", head(remote), head(peer))
        }
        let forceBranch = "force-test"
        yes("create force-push test branch", local.run(["switch", "-c", forceBranch]).ok)
        if let freshPreview = work.previewForcePush(branch: forceBranch) {
            yes("force push creates a new remote branch", work.forcePush(freshPreview, hard: false).ok)
            eq("force push sets actual branch upstream",
               local.run(["rev-parse", "--abbrev-ref", "@{upstream}"]).value, "origin/" + forceBranch)
        } else { yes("new branch force-push preview", false) }
        yes("return to main after force test", local.run(["switch", "main"]).ok)
        yes("set mismatched push URL", local.run(["config", "remote.origin.pushurl", root + "/other.git"]).ok)
        yes("force push refuses different push destination", work.previewForcePush(branch: "main") == nil)
        yes("remove push override", local.run(["config", "--unset-all", "remote.origin.pushurl"]).ok)

        let empty = repo("unborn")
        yes("unborn remote", empty.run(["remote", "add", "origin", remote.path]).ok)
        write(empty, "file.txt", "uncommitted initial work\n")
        yes("force pull refuses unstashable unborn work", !GitWorkflow(empty).forcePull(branch: "main").ok)
        eq("unborn work survives", read(empty, "file.txt"), "uncommitted initial work\n")

        let squash = repo("squash")
        let squasher = GitWorkflow(squash)
        for i in 1...3 {
            write(squash, "item.txt", "\(i)\n")
            yes("squash fixture commit \(i)", squasher.commit(message: "commit \(i)") == .committed)
        }
        let beforeSquash = head(squash)
        yes("preserve formerly hard-coded temporary branch", squash.run(["branch", "justgit-squash-tmp", "HEAD~1"]).ok)
        let oldTemp = squash.run(["rev-parse", "justgit-squash-tmp"]).value
        yes("invalid stale squash refused", !squasher.squash(count: 2, message: "bad", branch: "main", expectedHead: originalHead).ok)
        yes("squash last two", squasher.squash(count: 2, message: "combined", branch: "main", expectedHead: beforeSquash).ok)
        eq("squash count", Double(squash.totalCommits), 2)
        eq("squash preserves files", read(squash, "item.txt"), "3\n")
        yes("squash leaves clean index", !squash.status().dirty)
        eq("unrelated temporary branch survives", squash.run(["rev-parse", "justgit-squash-tmp"]).value, oldTemp)
        let beforeFailedSquash = head(squash)
        let branchLogs = squash.path + "/.git/logs/refs/heads"
        do {
            try fm.moveItem(atPath: branchLogs, toPath: branchLogs + ".saved")
            try "blocked".write(toFile: branchLogs, atomically: true, encoding: .utf8)
            yes("squash stops when backup cannot be created",
                !squasher.squash(count: 2, message: "fail backup", branch: "main", expectedHead: beforeFailedSquash).ok)
            eq("backup failure preserves HEAD", head(squash), beforeFailedSquash)
            try fm.removeItem(atPath: branchLogs)
            try fm.moveItem(atPath: branchLogs + ".saved", toPath: branchLogs)
        } catch { yes("backup failure fixture: \(error)", false) }
        yes("enable failing signer", squash.run(["config", "commit.gpgSign", "true"]).ok)
        yes("set failing signer", squash.run(["config", "gpg.program", "/usr/bin/false"]).ok)
        yes("failed squash signing does not move branch",
            !squasher.squash(count: 2, message: "fail", branch: "main", expectedHead: beforeFailedSquash).ok)
        eq("failed squash preserves HEAD", head(squash), beforeFailedSquash)
        yes("failed squash preserves index", !squash.status().dirty)
        yes("disable signing", squash.run(["config", "commit.gpgSign", "false"]).ok)
        yes("squash all", squasher.squash(count: 2, message: "root", branch: "main", expectedHead: head(squash)).ok)
        eq("squash all has one root", Double(squash.totalCommits), 1)
        eq("squash all preserves files", read(squash, "item.txt"), "3\n")
        let rootCommit = head(squash)
        yes("create merge side branch", squash.run(["switch", "-c", "side"]).ok)
        for i in 1...2 {
            write(squash, "side.txt", "\(i)\n")
            yes("side commit \(i)", squasher.commit(message: "side \(i)") == .committed)
        }
        yes("return to main", squash.run(["switch", "main"]).ok)
        write(squash, "main.txt", "main\n")
        yes("main merge fixture", squasher.commit(message: "main") == .committed)
        yes("create merge", squash.run(["merge", "--no-ff", "side", "-m", "merge side"]).ok)
        eq("squash count follows first parents", Double(squash.totalCommits), 3)
        yes("squash merge and prior first-parent commit",
            squasher.squash(count: 2, message: "merged", branch: "main", expectedHead: head(squash)).ok)
        eq("merge squash parent is correct", squash.run(["rev-parse", "HEAD^"]).value, rootCommit)
        eq("merge squash preserves side files", read(squash, "side.txt"), "2\n")
        let shallowPath = root + "/shallow"
        yes("create shallow clone", squash.run(["clone", "--depth=1", "--branch", "main",
                                               URL(fileURLWithPath: squash.path).absoluteString, shallowPath]).ok)
        let shallow = Git(shallowPath, environment: env)
        let shallowHead = head(shallow)
        yes("squash refuses incomplete shallow history",
            !GitWorkflow(shallow).squash(count: 1, message: "no rewrite", branch: "main", expectedHead: shallowHead).ok)
        eq("shallow history is unchanged", head(shallow), shallowHead)

        let conflicts = repo("literal-conflicts")
        let conflictWork = GitWorkflow(conflicts)
        for name in ["a[1].txt", "a1.txt"] { write(conflicts, name, "base\n") }
        yes("conflict fixture base", conflictWork.commit(message: "base") == .committed)
        yes("conflict fixture side", conflicts.run(["switch", "-c", "side"]).ok)
        for name in ["a[1].txt", "a1.txt"] { write(conflicts, name, "side\n") }
        yes("conflict side commit", conflictWork.commit(message: "side") == .committed)
        let patch = conflicts.run(["format-patch", "-1", "--stdout"]).out
        write(conflicts, ".git/change.patch", patch)
        yes("conflict fixture main", conflicts.run(["switch", "main"]).ok)
        for name in ["a[1].txt", "a1.txt"] { write(conflicts, name, "main\n") }
        yes("conflict main commit", conflictWork.commit(message: "main") == .committed)
        yes("create merge conflicts", !conflicts.run(["merge", "side", "-m", "merge"]).ok)
        write(conflicts, "a[1].txt", "resolved\n")
        yes("resolve literal wildcard filename", conflictWork.resolve(file: "a[1].txt").ok)
        eq("other wildcard-matching file remains unresolved",
           conflicts.run(["diff", "--name-only", "--diff-filter=U"]).value, "a1.txt")
        yes("reject stale resolved-file choice", !conflictWork.resolve(file: "a[1].txt").ok)
        yes("abort literal conflict fixture", conflictWork.recover(abort: true).ok)
        yes("create interrupted patch application", !conflicts.run(["am", ".git/change.patch"]).ok)
        eq("patch application detected as am, not rebase", conflicts.status().operation, "am")
        yes("abort patch application", conflictWork.recover(abort: true).ok)
        eq("patch operation cleared", conflicts.status().operation, "")

        yes("bring local up to remote", work.forcePull(branch: "main").ok)
        write(local, "file.txt", "local conflict\n")
        yes("local conflicting commit", work.commit(message: "local conflict") == .committed)
        write(peer, "file.txt", "remote conflict\n")
        yes("remote conflicting commit", GitWorkflow(peer).commit(message: "remote conflict") == .committed)
        yes("push conflict fixture", GitWorkflow(peer).push(branch: "main").ok)
        let beforeRebase = head(local)
        yes("pull reports rebase conflict", !work.pull(branch: "main").ok)
        let conflict = local.status()
        eq("detect active rebase", conflict.operation, "rebase")
        yes("detect unmerged files", conflict.conflicts)
        yes("normal commit blocked during rebase", work.commit(message: "bad") == .failed)
        yes("abort rebase in app workflow", work.recover(abort: true).ok)
        eq("abort restores branch tip", head(local), beforeRebase)
        yes("rebase conflict reproducible", !work.pull(branch: "main").ok)
        write(local, "file.txt", "resolved\n")
        yes("stage resolved conflict", local.run(["add", "--", "file.txt"]).ok)
        yes("continue rebase without invisible editor", work.recover(abort: false).ok)
        eq("operation cleared", local.status().operation, "")

        eq("stale recents removed and paths deduplicated",
           Paths.validRecents([root + "/missing", local.path, local.path + "/.", local.path + "/file.txt"]).joined(separator: "\n"),
           URL(fileURLWithPath: local.path).resolvingSymlinksInPath().path)
    }
}
