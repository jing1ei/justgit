import Foundation

/// Git workflows shared by the window and real-repository regression tests.
final class GitWorkflow {
    let git: Git
    private let output: (String) -> Void

    init(_ git: Git, output: @escaping (String) -> Void = { _ in }) {
        self.git = git
        self.output = output
    }

    @discardableResult
    func run(_ args: [String]) -> RunResult {
        output("$ git " + args.map(Self.quote).joined(separator: " "))
        let result = git.run(args)
        if !result.text.isEmpty { output(result.text) }
        return result
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func fail(_ message: String) -> RunResult {
        output(message)
        return RunResult(code: 1, out: message)
    }

    private func usable(_ status: RepoStatus, branch: String? = nil) -> Bool {
        guard status.isRepo, status.error.isEmpty else {
            output(status.error.isEmpty ? "Open a working-tree repository first." : status.error)
            return false
        }
        guard status.operation.isEmpty, !status.conflicts else {
            output("Finish or abort the current operation using Continue / Abort before trying again.")
            return false
        }
        if let branch = branch, status.detached || status.branch != branch {
            output("The checked-out branch changed. Refresh and retry.")
            return false
        }
        return true
    }

    enum CommitOutcome { case committed, nothingToDo, failed }

    func commit(message: String) -> CommitOutcome {
        guard usable(git.status(recentLog: false)), run(["add", "-A"]).ok else { return .failed }
        let diff = git.run(["diff", "--cached", "--quiet", "--exit-code"])
        if diff.code == 0 { output("Nothing to commit."); return .nothingToDo }
        guard diff.code == 1 else { output(diff.text); return .failed }
        return run(["commit", "-m", message]).ok ? .committed : .failed
    }

    @discardableResult
    func push(branch: String) -> RunResult {
        let status = git.status(recentLog: false)
        guard usable(status, branch: branch) else { return RunResult(code: 1, out: "") }
        guard status.hasRemote else { return fail("No origin. Set it with Remote first.") }
        guard status.hasCommits else { return fail("No commits to push. Add a file and commit first.") }
        guard matchingOriginEndpoints() else { return RunResult(code: 1, out: "") }
        // The window displays origin and this branch, never an unrelated configured upstream.
        return run(["-c", "remote.origin.mirror=false", "push", "--no-follow-tags", "--set-upstream",
                    "origin", "refs/heads/\(branch):refs/heads/\(branch)"])
    }

    @discardableResult
    func pull(branch: String) -> RunResult {
        let status = git.status(recentLog: false)
        guard usable(status, branch: branch) else { return RunResult(code: 1, out: "") }
        guard status.hasRemote else { return fail("No origin. Set it with Remote first.") }
        let head = git.run(["rev-parse", "--verify", "HEAD"]).value
        let fetched = run(["fetch", "--no-tags", "origin",
                           "+refs/heads/\(branch):refs/remotes/origin/\(branch)"])
        guard fetched.ok else {
            return fail("Fetch failed. If this is a new remote branch, Push creates it; otherwise check Remote and Setup.")
        }
        let target = git.run(["rev-parse", "--verify", "refs/remotes/origin/\(branch)"]).value
        guard !target.isEmpty else { return fail("Fetched branch could not be resolved. Refresh and retry.") }
        let fresh = git.status(recentLog: false)
        guard usable(fresh, branch: branch), git.run(["rev-parse", "--verify", "HEAD"]).value == head else {
            return fail("Local branch changed during fetch. Nothing was rebased; refresh and retry.")
        }
        if !fresh.hasCommits {
            guard !fresh.dirty else {
                return fail("Commit or move your local files before pulling into an empty branch.")
            }
            return run(["merge", "--ff-only", target])
        }
        let result = run(["rebase", "--autostash", target])
        guard result.ok else { return result }
        // Applying an autostash can report success while leaving conflicts.
        let after = git.status(recentLog: false)
        guard after.error.isEmpty, !after.conflicts, after.operation.isEmpty else {
            return fail("Pull left conflicts. Resolve files, then Continue if an operation is active, otherwise Commit. Git retains the conflicting autostash.")
        }
        return result
    }

    @discardableResult
    func sync(branch: String, message: String) -> RunResult {
        let status = git.status(recentLog: false)
        guard usable(status, branch: branch), status.hasRemote, matchingOriginEndpoints() else {
            return fail("Sync stopped. Check repository state and configure Remote first.")
        }
        guard commit(message: message) != .failed else { return fail("Sync stopped: commit failed.") }
        let remote = run(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"])
        guard remote.ok else { return fail("Sync stopped: could not inspect the remote. Nothing was pushed.") }
        if remote.value.isEmpty { return push(branch: branch) }
        guard pull(branch: branch).ok else { return fail("Sync stopped: pull failed. Nothing was pushed.") }
        return push(branch: branch)
    }

    private func backup(_ head: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "backup-" + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8)
        guard run(["branch", name, head]).ok else {
            output("Backup failed. No history was changed.")
            return nil
        }
        output("Recovery branch: \(name)\nUndo after preserving any newer work: git reset --hard \(Self.quote(name))")
        return name
    }

    @discardableResult
    func squash(count: Int, message: String, branch: String, expectedHead: String) -> RunResult {
        let status = git.status(recentLog: false)
        guard usable(status, branch: branch), !status.dirty else {
            return fail("Squash requires a clean working tree and no unfinished operation.")
        }
        let head = git.run(["rev-parse", "--verify", "HEAD"]).value
        let total = git.totalCommits
        guard !head.isEmpty, head == expectedHead, count >= 1, count <= total else {
            return fail("History changed or the count is invalid. Refresh and retry.")
        }
        let shallow = git.run(["rev-parse", "--is-shallow-repository"])
        guard shallow.ok, shallow.value == "false" else {
            return fail("Squash requires complete history. In Terminal, fetch the full history with git fetch --unshallow, then refresh.")
        }
        guard backup(head) != nil else { return RunResult(code: 1, out: "") }
        if count == 1 { return run(["commit", "--amend", "-m", message]) }

        var args = ["commit-tree", head + "^{tree}"]
        if count < total {
            let parent = git.run(["rev-parse", "--verify", "\(head)~\(count)"]).value
            guard !parent.isEmpty else { return fail("Could not resolve squash parent. History is unchanged.") }
            args += ["-p", parent]
        }
        if git.run(["config", "--bool", "commit.gpgSign"]).value == "true" { args.append("-S") }
        args += ["-m", message]
        let created = run(args)
        guard created.ok else { return created }
        let fresh = git.status(recentLog: false)
        guard usable(fresh, branch: branch), !fresh.dirty else {
            return fail("Working tree changed during squash. History is unchanged; refresh and retry.")
        }
        // Build the object first, then atomically replace the branch only if HEAD
        // still matches the version the user approved. Index and files never move.
        return run(["update-ref", "-m", "JustGit squash", "refs/heads/\(branch)", created.value, head])
    }

    private func matchingOriginEndpoints() -> Bool {
        let fetch = git.run(["remote", "get-url", "--all", "origin"])
        let push = git.run(["remote", "get-url", "--push", "--all", "origin"])
        guard fetch.ok, push.ok, !fetch.value.isEmpty,
              !fetch.value.contains("\n"), !push.value.contains("\n"),
              fetch.value == push.value else {
            output("Origin has different or multiple push URLs. Use Remote to choose one URL for both directions before pushing or resetting.")
            return false
        }
        return true
    }

    @discardableResult
    func setOrigin(_ url: String) -> RunResult {
        let status = git.status(recentLog: false)
        guard usable(status) else { return RunResult(code: 1, out: "") }
        let remotes = git.run(["remote"])
        guard remotes.ok else { return remotes }
        if remotes.value.split(separator: "\n").contains("origin") {
            guard run(["config", "--local", "--replace-all", "remote.origin.url", url]).ok else {
                return fail("Could not update origin. Check repository config permissions.")
            }
        } else {
            let added = run(["remote", "add", "origin", url])
            guard added.ok else { return added }
        }
        let pushURLs = git.run(["config", "--local", "--unset-all", "remote.origin.pushurl"])
        guard pushURLs.ok || pushURLs.code == 5 else {
            return fail("Origin changed, but its separate push URLs could not be removed:\n" + pushURLs.text)
        }
        // Explicit fetch refspecs still populate this namespace; repair the usual
        // mapping so upstream resolution works after an origin with no fetch config.
        let mapped = run(["config", "--local", "--replace-all", "remote.origin.fetch",
                          "+refs/heads/*:refs/remotes/origin/*"])
        guard mapped.ok else { return mapped }
        return matchingOriginEndpoints() ? RunResult(code: 0, out: "")
            : fail("Inherited Git URL rewrite settings still change this destination. Inspect git config --show-origin in Terminal.")
    }

    struct PushPreview {
        let branch: String
        let localHead: String
        let remoteHead: String
        let remoteURL: String
        let lost: String
    }

    func previewForcePush(branch: String) -> PushPreview? {
        let status = git.status(recentLog: false)
        guard usable(status, branch: branch), status.hasCommits, matchingOriginEndpoints() else { return nil }
        let remoteURL = git.run(["remote", "get-url", "origin"]).value
        let refs = run(["ls-remote", "--heads", "origin", "refs/heads/\(branch)"])
        guard refs.ok else { return nil }
        var remoteHead = ""
        if !refs.value.isEmpty {
            guard run(["fetch", "--no-tags", "origin",
                       "+refs/heads/\(branch):refs/remotes/origin/\(branch)"]).ok else { return nil }
            remoteHead = git.run(["rev-parse", "--verify", "refs/remotes/origin/\(branch)"]).value
            guard !remoteHead.isEmpty else { return nil }
        }
        let head = git.run(["rev-parse", "--verify", "HEAD"]).value
        guard !head.isEmpty else { return nil }
        let log = remoteHead.isEmpty ? RunResult(code: 0, out: "")
            : git.run(["--no-pager", "log", "--oneline", "\(head)..\(remoteHead)"])
        guard log.ok else { output(log.text); return nil }
        return PushPreview(branch: branch, localHead: head, remoteHead: remoteHead,
                           remoteURL: remoteURL, lost: log.value)
    }

    @discardableResult
    func forcePush(_ preview: PushPreview, hard: Bool) -> RunResult {
        guard usable(git.status(recentLog: false), branch: preview.branch),
              matchingOriginEndpoints(),
              git.run(["remote", "get-url", "origin"]).value == preview.remoteURL,
              git.run(["rev-parse", "--verify", "HEAD"]).value == preview.localHead else {
            return fail("Branch or remote changed since the preview. Refresh and try again.")
        }
        let flag = hard ? "--force" : "--force-with-lease=refs/heads/\(preview.branch):\(preview.remoteHead)"
        let result = run(["-c", "remote.origin.mirror=false", "push", "--no-follow-tags", flag, "origin",
                          "\(preview.localHead):refs/heads/\(preview.branch)"])
        guard result.ok else { return result }
        // A raw object ID refspec cannot set a local branch's upstream.
        let upstream = run(["branch", "--set-upstream-to=origin/\(preview.branch)", preview.branch])
        if !upstream.ok { output("Push succeeded, but upstream setup failed. Ordinary Push can repair it.") }
        return result
    }

    @discardableResult
    func forcePull(branch: String) -> RunResult {
        var status = git.status(recentLog: false)
        guard usable(status, branch: branch), matchingOriginEndpoints() else { return RunResult(code: 1, out: "") }
        let fetched = run(["fetch", "--no-tags", "origin",
                           "+refs/heads/\(branch):refs/remotes/origin/\(branch)"])
        guard fetched.ok else { return fetched }
        let target = git.run(["rev-parse", "--verify", "refs/remotes/origin/\(branch)"]).value
        guard !target.isEmpty else { return fail("Remote branch not found; nothing was reset.") }
        status = git.status(recentLog: false)
        guard usable(status, branch: branch) else { return RunResult(code: 1, out: "") }
        let head = git.run(["rev-parse", "--verify", "HEAD"]).value
        let extras = git.run(["ls-files", "--others", "-z"])
        guard extras.ok else { return extras }
        if !head.isEmpty {
            guard let name = backup(head) else { return RunResult(code: 1, out: "") }
            if status.dirty || !extras.out.isEmpty {
                // Include ignored files: reset --hard can otherwise overwrite them
                // when the incoming tree tracks the same paths.
                let stash = run(["stash", "push", "--all", "-m", name])
                guard stash.ok else { return fail("Stash failed. Local files were not reset.") }
                let stashID = git.run(["rev-parse", "--verify", "refs/stash"]).value
                guard !stashID.isEmpty else { return fail("Could not verify the stash. Local files were not reset.") }
                output("Saved work (including ignored files): \(stashID)\nRecover with: git stash apply \(stashID)")
            }
        } else if status.dirty || !extras.out.isEmpty {
            return fail("An empty branch cannot be stashed. Commit or move all local files first; nothing was reset.")
        }
        let fresh = git.status(recentLog: false)
        let remainingFiles = git.run(["ls-files", "--others", "-z"])
        guard usable(fresh, branch: branch), !fresh.dirty,
              remainingFiles.ok, remainingFiles.out.isEmpty,
              git.run(["rev-parse", "--verify", "HEAD"]).value == head else {
            return fail("Local state changed during backup. Nothing was reset; preserve new work and retry.")
        }
        return run(["reset", "--hard", target])
    }

    @discardableResult
    func resolve(file: String) -> RunResult {
        let status = git.status(recentLog: false)
        guard status.isRepo, status.error.isEmpty else { return fail("Refresh the repository before resolving files.") }
        let files = git.run(["diff", "--name-only", "--diff-filter=U", "-z"])
        guard files.ok else { return files }
        guard files.out.split(separator: "\0").contains(Substring(file)) else {
            return fail("This file is no longer conflicted. Refresh the conflict list.")
        }
        return run(["--literal-pathspecs", "add", "-A", "--", file])
    }

    @discardableResult
    func recover(abort: Bool) -> RunResult {
        let status = git.status(recentLog: false)
        guard status.error.isEmpty, status.isRepo else { return fail("Refresh the repository before recovery.") }
        if !status.operation.isEmpty {
            // Do not stage unresolved markers automatically. The user edits and
            // marks each file resolved before Continue is allowed.
            if !abort && status.conflicts {
                return fail("Resolve each conflicted file, then mark it resolved with Resolve files before Continue.")
            }
            return run([status.operation, abort ? "--abort" : "--continue"])
        }
        return fail("No operation to abort or continue. For stash conflicts, resolve files and commit; the stash is kept.")
    }
}
