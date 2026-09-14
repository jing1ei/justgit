"""Run with: python -m unittest discover -s Windows -p test_*.py -v."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest

from core import Git, GitError, Settings, execute, remote_url, ssh_target


class ParsingTests(unittest.TestCase):
    def test_windows_paths_are_not_ssh(self):
        for path in (r"C:\work\repo.git", r"\\server\share\repo.git", "C:/work/repo.git"):
            self.assertEqual(remote_url(path), path)

    def test_https_converts_and_strips_credentials(self):
        self.assertEqual(remote_url("https://user:secret@example.invalid/team/repo?x=1#top"),
                         "git@example.invalid:team/repo.git")

    def test_custom_ssh_preserved(self):
        value = "ssh://testuser@example.invalid:2222/team/repo"
        self.assertEqual(remote_url(value), value)
        self.assertEqual(ssh_target(value), ("example.invalid", "testuser", 2222))

    def test_bad_urls_rejected(self):
        for value in ("", "-bad", "ext::command", "https://host", "ssh://user:password@host/repo",
                      "ssh://host:99999/repo", "git@host:", "one\nline"):
            with self.subTest(value=value), self.assertRaises(GitError):
                remote_url(value)

    def test_test_host_and_port(self):
        self.assertEqual(ssh_target("testuser@host:2222"), ("host", "testuser", 2222))

    def test_settings_roundtrip_and_stale_paths(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            settings = Settings(root / "settings.json")
            settings.recent = [str(root), str(root / "."), str(root / "gone"), None]
            settings.skin = "Dark"
            settings.save()
            reread = Settings(settings.path)
            self.assertEqual(reread.recent, [str(root.resolve())])
            self.assertEqual(reread.skin, "Dark")
            settings.path.write_text("[]", encoding="utf-8")
            self.assertEqual(Settings(settings.path).recent, [])

    def test_process_deadline(self):
        start = time.monotonic()
        with self.assertRaises(GitError):
            execute(sys.executable, ["-c", "import time; time.sleep(30)"], timeout=.2)
        self.assertLess(time.monotonic() - start, 8)

    def test_process_streams(self):
        result = execute(sys.executable, ["-c", "import sys; print('value'); print('warning', file=sys.stderr)"])
        self.assertEqual(result.value, "value")
        self.assertIn("warning", result.err)

    def test_output_limit(self):
        with self.assertRaisesRegex(GitError, "8 MiB"):
            execute(sys.executable, ["-c", "import sys; sys.stdout.write('x' * 9000000)"])


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="justgit-windows-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {
            "HOME": str(self.root), "USERPROFILE": str(self.root),
            "XDG_CONFIG_HOME": str(self.root), "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0",
            "GIT_AUTHOR_NAME": "JustGit Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "JustGit Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }
        self.local = self.repo("local")
        self.remote = self.repo("origin.git", bare=True)
        self.peer = self.repo("peer")
        self.write(self.local, "file.txt", "base\n")
        self.local.commit("base")
        self.local.set_remote(self.remote.path)
        self.local.push("main")
        self.peer.set_remote(self.remote.path)
        self.peer.pull("main")

    def repo(self, name, bare=False):
        path = self.root / name
        path.mkdir()
        git = Git(path, env=self.env)
        git.run("init", *(["--bare"] if bare else []), "-b", "main")
        return git

    def write(self, git, name, text):
        path = Path(git.path) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def head(self, git):
        return git.read("rev-parse", "HEAD")

    def test_status_untracked_and_detached(self):
        self.local.run("config", "status.showUntrackedFiles", "no")
        self.write(self.local, "space name.txt", "content")
        state = self.local.state()
        self.assertIn("?? space name.txt", state.files)
        self.local.run("checkout", "--detach", "HEAD")
        self.assertTrue(self.local.state().detached)

    def test_staging_failure_stops_sync(self):
        original = self.head(self.local)
        self.write(self.local, ".git/index.lock", "locked")
        self.write(self.local, "file.txt", "dirty")
        with self.assertRaises(GitError):
            self.local.sync("main", "must not commit")
        self.assertEqual(self.head(self.local), original)
        self.assertEqual(self.head(self.remote), original)

    def test_missing_remote_sync_creates_branch(self):
        self.local.new_branch("new-branch")
        self.local.sync("new-branch", "nothing")
        self.assertEqual(self.remote.read("rev-parse", "new-branch"), self.head(self.local))

    def test_failed_fetch_never_resets_stale_tracking_ref(self):
        self.write(self.local, "extra.txt", "extra")
        self.local.commit("extra")
        original = self.head(self.local)
        self.local.run("remote", "set-url", "origin", str(self.root / "gone.git"))
        self.write(self.local, "file.txt", "precious")
        with self.assertRaises(GitError):
            self.local.force_pull("main")
        self.assertEqual(self.head(self.local), original)
        self.assertEqual((Path(self.local.path) / "file.txt").read_text(), "precious")

    def test_stash_failure_never_resets(self):
        original = self.head(self.local)
        self.write(self.local, "file.txt", "precious")
        self.write(self.local, ".git/index.lock", "locked")
        with self.assertRaises(GitError):
            self.local.force_pull("main")
        self.assertEqual(self.head(self.local), original)
        self.assertEqual((Path(self.local.path) / "file.txt").read_text(), "precious")

    def test_force_pull_saves_ignored_and_untracked_files(self):
        self.write(self.local, ".git/info/exclude", "ignored.txt\n")
        self.write(self.local, "ignored.txt", "ignored data")
        self.write(self.local, "untracked.txt", "untracked data")
        self.write(self.local, "file.txt", "dirty")
        self.local.force_pull("main")
        self.assertEqual(self.local.read("show", "stash^3:ignored.txt"), "ignored data")
        self.assertEqual(self.local.read("show", "stash^3:untracked.txt"), "untracked data")
        self.assertEqual(self.local.read("show", "stash:file.txt"), "dirty")
        self.assertTrue(self.local.read("branch", "--list", "backup-*"))

    def test_force_push_pins_preview_even_after_another_fetch(self):
        preview = self.local.preview_push("main")
        self.write(self.peer, "peer.txt", "peer")
        self.peer.commit("peer")
        self.peer.push("main")
        self.local.run("fetch", "origin")
        with self.assertRaises(GitError):
            self.local.force_push(preview)
        self.assertEqual(self.head(self.remote), self.head(self.peer))

    def test_force_push_new_branch_sets_upstream(self):
        self.local.new_branch("new")
        self.local.force_push(self.local.preview_push("new"))
        self.assertEqual(self.local.read("rev-parse", "--abbrev-ref", "@{upstream}"), "origin/new")

    def test_remote_repairs_multiple_urls(self):
        self.local.run("config", "--add", "remote.origin.url", str(self.root / "unused"))
        with self.assertRaises(GitError):
            self.local.endpoint()
        self.local.run("config", "--add", "remote.origin.pushurl", str(self.root / "push"))
        self.local.set_remote(self.remote.path)
        self.assertEqual(self.local.endpoint(), self.remote.path)

    def test_pull_does_not_rebase_changed_branch(self):
        changed = []
        def log(line):
            if line.startswith("$ git fetch") and not changed:
                changed.append(True)
                self.local.run("switch", "-c", "other")
        self.local.log = log
        with self.assertRaises(GitError):
            self.local.pull("main")
        self.assertEqual(self.local.state().branch, "other")

    def test_squash_is_atomic_and_preserves_tree(self):
        for index in range(2):
            self.write(self.local, "file.txt", str(index))
            self.local.commit(str(index))
        tree = self.local.read("rev-parse", "HEAD^{tree}")
        self.local.squash("main", 3, "one", self.head(self.local))
        self.assertEqual(self.local.read("rev-list", "--count", "HEAD"), "1")
        self.assertEqual(self.local.read("rev-parse", "HEAD^{tree}"), tree)
        self.assertFalse(self.local.state().files)

    def test_squash_failed_signing_preserves_head(self):
        self.write(self.local, "file.txt", "second")
        self.local.commit("second")
        original = self.head(self.local)
        self.local.run("config", "commit.gpgSign", "true")
        self.local.run("config", "gpg.program", str(self.root / "missing-signer"))
        with self.assertRaises(GitError):
            self.local.squash("main", 2, "fail", original)
        self.assertEqual(self.head(self.local), original)
        self.assertFalse(self.local.state().files)

    def test_rebase_abort_and_continue(self):
        self.write(self.local, "file.txt", "local\n")
        self.local.commit("local")
        original = self.head(self.local)
        self.write(self.peer, "file.txt", "remote\n")
        self.peer.commit("remote")
        self.peer.push("main")
        with self.assertRaises(GitError):
            self.local.pull("main")
        self.assertEqual(self.local.state().operation, "rebase")
        self.local.recover(abort=True)
        self.assertEqual(self.head(self.local), original)
        with self.assertRaises(GitError):
            self.local.pull("main")
        self.write(self.local, "file.txt", "resolved\n")
        self.local.resolve("file.txt")
        self.local.recover()
        self.assertFalse(self.local.state().operation)

    def test_conflict_path_is_literal(self):
        for file in ("a[1].txt", "a1.txt"):
            self.write(self.local, file, "base\n")
        self.local.commit("files")
        self.local.new_branch("side")
        for file in ("a[1].txt", "a1.txt"):
            self.write(self.local, file, "side\n")
        self.local.commit("side")
        self.local.run("switch", "main")
        for file in ("a[1].txt", "a1.txt"):
            self.write(self.local, file, "main\n")
        self.local.commit("main")
        self.local.run("merge", "side", "-m", "merge", check=False)
        self.write(self.local, "a[1].txt", "resolved\n")
        self.local.resolve("a[1].txt")
        self.assertEqual(self.local.state().conflicts, ("a1.txt",))


if __name__ == "__main__":
    unittest.main()
