"""Git operations for the Windows desktop app. No UI or third-party packages."""
from __future__ import annotations

import json
import ntpath
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from urllib.parse import urlsplit
from uuid import uuid4


class GitError(RuntimeError):
    pass


def tool_path(name):
    found = shutil.which(name + ".exe" if os.name == "nt" else name)
    if not found and os.name == "nt":
        git = shutil.which("git.exe")
        if git:
            candidate = Path(git).parent.parent / "usr" / "bin" / (name + ".exe")
            if candidate.is_file():
                found = str(candidate)
    if not found:
        raise GitError(f"{name} is unavailable. Install Git for Windows and enable it on PATH, then restart JustGit.")
    return found


def stop_process(process):
    if os.name == "nt":
        if process.poll() is None:
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW, timeout=10, check=False)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)


@dataclass
class Result:
    code: int
    out: str
    err: str = ""

    @property
    def value(self):
        return self.out.rstrip("\r\n") if self.code == 0 else ""

    @property
    def text(self):
        return "\n".join(part.strip() for part in (self.out, self.err) if part.strip())


def execute(executable, args, cwd=None, env=None, timeout=180):
    environment = os.environ.copy()
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"):
        environment.pop(key, None)
    environment.update(GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never",
                       GIT_OPTIONAL_LOCKS="0", GIT_ASKPASS="false", SSH_ASKPASS="false",
                       GIT_EDITOR="true", GIT_SEQUENCE_EDITOR="false", LC_ALL="C",
                       LLVM_PROFILE_FILE=os.devnull)
    environment.setdefault("GIT_SSH_COMMAND",
                           "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15")
    environment.update(env or {})
    try:
        process = subprocess.Popen(
            [executable, *args], cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
            start_new_session=os.name != "nt")
    except OSError as error:
        raise GitError(str(error)) from error
    chunks = queue.Queue(maxsize=64)
    stopped = threading.Event()

    def drain(stream, index):
        try:
            while not stopped.is_set():
                data = stream.read(16384)
                while not stopped.is_set():
                    try:
                        chunks.put((index, data), timeout=.1)
                        break
                    except queue.Full:
                        continue
                if not data:
                    break
        finally:
            stream.close()

    for index, stream in enumerate((process.stdout, process.stderr)):
        threading.Thread(target=drain, args=(stream, index), daemon=True).start()
    buffers = [bytearray(), bytearray()]
    finished = 0
    deadline = time.monotonic() + timeout
    try:
        while finished < 2 or process.poll() is None:
            if time.monotonic() >= deadline:
                raise GitError("Command timed out. Refresh before retrying; inspect any unfinished operation.")
            try:
                index, data = chunks.get(timeout=.05)
            except queue.Empty:
                continue
            if data:
                buffers[index].extend(data)
                if sum(map(len, buffers)) > 8 * 1024 * 1024:
                    raise GitError("Command output exceeded 8 MiB. Inspect this repository in Terminal.")
            else:
                finished += 1
        return Result(process.wait(), *(bytes(b).decode("utf-8", errors="replace") for b in buffers))
    except BaseException:
        stopped.set()
        stop_process(process)
        raise


def remote_url(raw):
    value = raw.strip()
    if not value or any(ord(c) < 32 for c in value) or value.startswith("-"):
        raise GitError("Enter an SSH/HTTPS URL or a local repository path.")
    if ntpath.isabs(value) or value.startswith(("/", "./", "../", "~", "file://")):
        return os.path.expanduser(value)
    if value.lower().startswith(("https://", "http://")):
        parsed = urlsplit(value)
        if not parsed.hostname or not parsed.path.strip("/"):
            raise GitError("The remote URL must include a repository path.")
        path = parsed.path.strip("/")
        path += "" if path.endswith(".git") else ".git"
        host = parsed.hostname
        return f"ssh://git@[{host}]/{path}" if ":" in host else f"git@{host}:{path}"
    if value.startswith("ssh://"):
        ssh_target(value)
        if not urlsplit(value).path.strip("/"):
            raise GitError("The SSH URL must include a repository path.")
        return value
    if re.fullmatch(r"(?:[^@\s/:]+@)?[^@\s/:]+:[^:\r\n].*", value):
        return value
    raise GitError("Use ssh://user@host:port/repo, git@host:repo, or an absolute local path.")


def ssh_target(raw):
    value = raw.strip()
    try:
        parsed = urlsplit(value if "://" in value else "ssh://" + value)
        port = parsed.port
        host = parsed.hostname
        user = parsed.username or "git"
        if (parsed.scheme != "ssh" or not host or host.startswith("-")
                or any(c.isspace() for c in host + user)
                or parsed.password is not None or parsed.query or parsed.fragment
                or (port is not None and not 1 <= port <= 65535)):
            raise ValueError()
    except ValueError as error:
        raise GitError("Use a hostname or ssh://user@host:port for the connection test.") from error
    return host, user, port


def test_ssh(target):
    host, user, port = ssh_target(target)
    args = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=15", "-T", "-l", user]
    if port:
        args += ["-p", str(port)]
    result = execute(tool_path("ssh"), [*args, host], timeout=40)
    greeting = result.text.lower()
    good = result.code == 0 or (result.code == 1 and any(
        text in greeting for text in ("successfully authenticated", "welcome to gitlab", "authenticated via ssh key")))
    if not good:
        raise GitError(result.text or "SSH connection failed.")
    return result.text or "SSH connection succeeded."


def key_file():
    return Path.home() / ".ssh" / "id_ed25519"


def create_key(comment=""):
    key = key_file()
    public = key.with_suffix(".pub")
    key.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if key.exists():
        if public.exists():
            return public.read_text(encoding="utf-8").strip()
        result = execute(tool_path("ssh-keygen"), ["-y", "-P", "", "-f", str(key)], timeout=30)
        if result.code:
            raise GitError("Could not recover the public key. For an encrypted key, run ssh-keygen -y -f "
                           + str(key) + " in Terminal.\n" + result.text)
        with public.open("x", encoding="utf-8") as stream:
            stream.write(result.value + "\n")
    else:
        if public.exists():
            raise GitError("A public key already exists without its private key. Preserve it before creating another key.")
        result = execute(tool_path("ssh-keygen"),
                         ["-t", "ed25519", "-N", "", "-C", comment, "-f", str(key)], timeout=30)
        if result.code:
            raise GitError(result.text)
    return public.read_text(encoding="utf-8").strip()


@dataclass
class State:
    root: str = ""
    branch: str = ""
    head: str = ""
    remote: str = ""
    operation: str = ""
    files: tuple = ()
    conflicts: tuple = ()
    history: str = ""
    ahead: int = 0
    behind: int = 0

    @property
    def detached(self):
        return self.branch == "(detached)"


@dataclass(frozen=True)
class PushPreview:
    branch: str
    local: str
    remote: str
    url: str
    lost: str


class Git:
    def __init__(self, path, log=lambda _: None, env=None):
        self.path = str(Path(path).resolve())
        self.log = log
        self.env = env or {}

    def run(self, *args, check=True, quiet=False):
        if not quiet:
            self.log("$ git " + subprocess.list2cmdline(list(args)))
        result = execute(tool_path("git"), list(args), cwd=self.path, env=self.env)
        if not quiet and result.text:
            self.log(result.text)
        if check and result.code:
            raise GitError(result.text or f"Git exited with status {result.code}.")
        return result

    def read(self, *args):
        return self.run(*args, quiet=True).value

    def state(self):
        top = self.run("rev-parse", "--show-toplevel", check=False, quiet=True)
        if top.code:
            if "not a git repository" in top.text:
                return State()
            raise GitError(top.text)
        state = State(root=top.value)
        result = self.read("-c", "core.quotePath=false", "status", "--porcelain=v2", "--branch",
                           "-z", "--untracked-files=all", "--ignore-submodules=none")
        files, conflicts = [], []
        records = iter(result.split("\0"))
        for entry in records:
            if entry.startswith("# branch.head "):
                state.branch = entry[len("# branch.head "):]
            elif entry.startswith("# branch.oid "):
                state.head = entry[len("# branch.oid "):]
                if state.head == "(initial)":
                    state.head = ""
            elif entry.startswith(("1 ", "2 ", "u ")):
                count = {"1": 8, "2": 9, "u": 10}[entry[0]]
                fields = entry.split(" ", count)
                if len(fields) != count + 1:
                    raise GitError("Unrecognized Git status. Inspect this repository in Terminal.")
                name = fields[-1]
                files.append(fields[1].replace(".", " ") + " " + name)
                if entry[0] == "u":
                    conflicts.append(name)
                if entry[0] == "2":
                    next(records, None)
            elif entry.startswith("? "):
                files.append("?? " + entry[2:])
        state.files, state.conflicts = tuple(files), tuple(conflicts)
        metadata = Path(self.read("rev-parse", "--absolute-git-dir"))
        for marker, operation in (("rebase-apply/applying", "am"), ("rebase-merge", "rebase"),
                                  ("rebase-apply", "rebase"), ("MERGE_HEAD", "merge"),
                                  ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert")):
            if (metadata / marker).exists():
                state.operation = operation
                break
        if not state.operation and (metadata / "sequencer").exists():
            todo = (metadata / "sequencer/todo").read_text(encoding="utf-8")
            state.operation = "revert" if todo.startswith("revert ") else "cherry-pick"
        state.remote = self.run("remote", "get-url", "origin", check=False, quiet=True).value
        if state.head:
            state.history = self.read("--no-pager", "log", "-n", "30", "--oneline", "--decorate")
            if not state.detached:
                counts = self.run("rev-list", "--left-right", "--count",
                                  f"HEAD...refs/remotes/origin/{state.branch}", check=False, quiet=True).value.split()
                if len(counts) == 2:
                    state.ahead, state.behind = map(int, counts)
        return state

    def ready(self, branch=None):
        state = self.state()
        if not state.root:
            raise GitError("Initialize this folder as a repository first.")
        if state.operation or state.conflicts:
            raise GitError("Resolve files and Continue, or Abort the current operation.")
        if branch is not None and (state.detached or state.branch != branch):
            raise GitError("The branch changed or HEAD is detached. Refresh or create a branch.")
        if Path(self.path) != Path(state.root):
            raise GitError("Open the repository root before changing files.")
        return state

    def endpoint(self):
        fetch = self.read("remote", "get-url", "--all", "origin").splitlines()
        push = self.read("remote", "get-url", "--push", "--all", "origin").splitlines()
        if len(fetch) != 1 or fetch != push:
            raise GitError("Origin must have one matching fetch/push URL. Use Remote to repair it.")
        return fetch[0]

    def initialize(self):
        if self.state().root:
            raise GitError("This folder already belongs to a repository.")
        self.run("init", "-b", "main")
        ignore = Path(self.path) / ".gitignore"
        if not ignore.exists():
            with ignore.open("x", encoding="utf-8") as stream:
                stream.write(".DS_Store\nThumbs.db\n.env\n")

    def commit(self, message):
        self.ready()
        self.run("add", "-A")
        diff = self.run("diff", "--cached", "--quiet", "--exit-code", check=False, quiet=True)
        if diff.code == 0:
            self.log("Nothing to commit.")
            return False
        if diff.code != 1:
            raise GitError(diff.text)
        self.run("commit", "-m", message)
        return True

    def push(self, branch):
        state = self.ready(branch)
        if not state.head:
            raise GitError("Commit a file before pushing.")
        self.endpoint()
        self.run("-c", "remote.origin.mirror=false", "push", "--no-follow-tags", "--set-upstream",
                 "origin", f"refs/heads/{branch}:refs/heads/{branch}")

    def fetch(self, branch):
        self.run("fetch", "--no-tags", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}")
        return self.read("rev-parse", "--verify", f"refs/remotes/origin/{branch}")

    def pull(self, branch):
        state = self.ready(branch)
        target = self.fetch(branch)
        fresh = self.ready(branch)
        if fresh.head != state.head:
            raise GitError("Local history changed during fetch. Nothing was rebased.")
        if not fresh.head:
            if fresh.files:
                raise GitError("Commit or move local files before pulling into an empty branch.")
            self.run("merge", "--ff-only", target)
        else:
            self.run("rebase", "--autostash", target)
        after = self.state()
        if after.conflicts or after.operation:
            raise GitError("Pull left conflicts. Resolve files, then Continue or Commit. The autostash is retained.")

    def sync(self, branch, message):
        self.ready(branch)
        self.endpoint()
        self.commit(message)
        if self.read("ls-remote", "--heads", "origin", f"refs/heads/{branch}"):
            self.pull(branch)
        self.push(branch)

    def backup(self, head):
        name = "backup-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid4().hex[:8]
        self.run("branch", name, head)
        self.log(f"Recovery branch: {name}\nAfter preserving newer work: git reset --hard {name}")
        return name

    def squash(self, branch, count, message, expected):
        state = self.ready(branch)
        if state.files or state.head != expected:
            raise GitError("Squash needs a clean, unchanged branch. Refresh and retry.")
        if self.read("rev-parse", "--is-shallow-repository") != "false":
            raise GitError("Fetch complete history with git fetch --unshallow before squashing.")
        total = int(self.read("rev-list", "--first-parent", "--count", "HEAD"))
        if not 1 <= count <= total:
            raise GitError(f"Choose between 1 and {total} first-parent commits.")
        self.backup(state.head)
        if count == 1:
            self.run("commit", "--amend", "-m", message)
            return
        args = ["commit-tree", state.head + "^{tree}"]
        if count < total:
            args += ["-p", self.read("rev-parse", f"{state.head}~{count}")]
        if self.run("config", "--bool", "commit.gpgSign", check=False, quiet=True).value == "true":
            args.append("-S")
        replacement = self.run(*args, "-m", message).value
        if self.ready(branch).files:
            raise GitError("Working tree changed. Branch history was not rewritten.")
        self.run("update-ref", "-m", "JustGit squash", f"refs/heads/{branch}", replacement, expected)

    def preview_push(self, branch):
        state = self.ready(branch)
        if not state.head:
            raise GitError("There are no commits to push.")
        url = self.endpoint()
        remote = self.fetch(branch) if self.read("ls-remote", "--heads", "origin", f"refs/heads/{branch}") else ""
        lost = self.read("--no-pager", "log", "--oneline", f"{state.head}..{remote}") if remote else ""
        return PushPreview(branch, state.head, remote, url, lost)

    def force_push(self, preview):
        if self.ready(preview.branch).head != preview.local or self.endpoint() != preview.url:
            raise GitError("Branch or origin changed since the preview. Refresh and retry.")
        self.run("-c", "remote.origin.mirror=false", "push", "--no-follow-tags",
                 f"--force-with-lease=refs/heads/{preview.branch}:{preview.remote}",
                 "origin", f"{preview.local}:refs/heads/{preview.branch}")
        result = self.run("branch", f"--set-upstream-to=origin/{preview.branch}", preview.branch, check=False)
        if result.code:
            self.log("Push succeeded; ordinary Push can repair the upstream configuration.")

    def force_pull(self, branch):
        self.ready(branch)
        self.endpoint()
        target = self.fetch(branch)
        state = self.ready(branch)
        extras = self.read("ls-files", "--others", "-z")
        if state.head:
            backup = self.backup(state.head)
            if state.files or extras:
                self.run("stash", "push", "--all", "-m", backup)
                stash = self.read("rev-parse", "--verify", "refs/stash")
                self.log(f"Saved work, including ignored files: {stash}\nRecover with: git stash apply {stash}")
        elif state.files or extras:
            raise GitError("Unborn branches cannot be stashed. Commit or move all local files first.")
        fresh = self.ready(branch)
        if fresh.head != state.head or fresh.files or self.read("ls-files", "--others", "-z"):
            raise GitError("Local files changed during backup. Nothing was reset.")
        self.run("reset", "--hard", target)

    def set_remote(self, raw):
        self.ready()
        url = remote_url(raw)
        if "origin" in self.read("remote").splitlines():
            self.run("config", "--local", "--replace-all", "remote.origin.url", url)
        else:
            self.run("remote", "add", "origin", url)
        result = self.run("config", "--local", "--unset-all", "remote.origin.pushurl", check=False)
        if result.code not in (0, 5):
            raise GitError(result.text)
        self.run("config", "--local", "--replace-all", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        self.endpoint()

    def resolve(self, file):
        if file not in self.state().conflicts:
            raise GitError("The conflict list changed. Refresh and retry.")
        self.run("--literal-pathspecs", "add", "-A", "--", file)

    def recover(self, abort=False):
        state = self.state()
        if not state.operation:
            raise GitError("No active operation. Resolve stash conflicts and commit; the stash is retained.")
        if not abort and state.conflicts:
            raise GitError("Resolve each conflicted file before Continue.")
        self.run(state.operation, "--abort" if abort else "--continue")

    def new_branch(self, name):
        self.ready()
        self.run("check-ref-format", "--branch", name)
        self.run("switch", "-c", name)


class Settings:
    def __init__(self, path=None):
        self.path = Path(path) if path else Path(os.environ.get("LOCALAPPDATA", Path.home() / ".config")) / "JustGit/settings.json"
        self.recent = []
        self.skin = "Light"
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            self.recent = self.valid_paths(data.get("recent", []))
            if data.get("skin") in ("Light", "Dark"):
                self.skin = data["skin"]
        except (OSError, ValueError, TypeError, AttributeError):
            pass

    @staticmethod
    def valid_paths(paths):
        if not isinstance(paths, list):
            return []
        result, seen = [], set()
        for raw in paths:
            if not isinstance(raw, str):
                continue
            try:
                path = Path(raw).resolve()
                key = os.path.normcase(str(path))
                if path.is_dir() and key not in seen:
                    result.append(str(path))
                    seen.add(key)
            except (OSError, ValueError):
                continue
        return result[:12]

    def save(self):
        self.recent = self.valid_paths(self.recent)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(self.path.name + "." + uuid4().hex + ".tmp")
        try:
            temporary.write_text(json.dumps({"recent": self.recent, "skin": self.skin}), encoding="utf-8")
            os.replace(temporary, self.path)
        finally:
            temporary.unlink(missing_ok=True)
