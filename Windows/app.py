"""Windows desktop entry point. Python 3.11+ with Tk and Git for Windows."""
from __future__ import annotations

import argparse
from datetime import datetime
import os
from pathlib import Path
import queue
import subprocess
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk

from core import Git, GitError, Settings, State, create_key, execute, key_file, test_ssh, tool_path


class App:
    def __init__(self, root, settings=None, restore=True):
        self.root = root
        self.settings = settings or Settings()
        self.git = None
        self.state = State()
        self.busy = False
        self.events = queue.Queue()
        self.setup_window = None
        self.setup_controls = []
        self.buttons = {}
        self.root.title("JustGit")
        self.root.geometry("920x650")
        self.root.minsize(780, 560)
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.style = ttk.Style(root)
        self.skin = tk.StringVar(value=self.settings.skin)
        self.path = tk.StringVar()
        self.message = tk.StringVar()
        self.branch = tk.StringVar(value="No repository selected")
        self.summary = tk.StringVar(value="")
        self.remote = tk.StringVar(value="")
        self.activity = tk.StringVar(value="Ready")
        self._menu()
        self._panel()
        self.apply_skin(save=False)
        root.bind("<Control-o>", lambda _: self.open_dialog())
        root.bind("<Control-r>", lambda _: self.refresh())
        root.bind("<Control-Return>", lambda _: self.commit(push=True))
        root.bind("<FocusIn>", self.focused)
        self.poll_id = root.after(50, self.poll)
        if restore and self.settings.recent:
            root.after(100, lambda: self.open_path(self.settings.recent[0]))

    def _menu(self):
        menu = tk.Menu(self.root)
        file_menu = tk.Menu(menu, tearoff=False)
        file_menu.add_command(label="Open repository...", accelerator="Ctrl+O", command=self.open_dialog)
        file_menu.add_command(label="Refresh", accelerator="Ctrl+R", command=self.refresh)
        file_menu.add_separator()
        file_menu.add_command(label="Exit", command=self.close)
        menu.add_cascade(label="File", menu=file_menu)
        edit = tk.Menu(menu, tearoff=False)
        for label, event in (("Undo", "<<Undo>>"), ("Redo", "<<Redo>>"), ("Cut", "<<Cut>>"),
                             ("Copy", "<<Copy>>"), ("Paste", "<<Paste>>"), ("Select all", "<<SelectAll>>")):
            edit.add_command(label=label, command=lambda e=event: self.edit_event(e))
        menu.add_cascade(label="Edit", menu=edit)
        menu.add_command(label="Setup", command=self.open_setup)
        skins = tk.Menu(menu, tearoff=False)
        for name in ("Light", "Dark"):
            skins.add_radiobutton(label=name, variable=self.skin, value=name, command=self.apply_skin)
        menu.add_cascade(label="Skin", menu=skins)
        self.root.configure(menu=menu)

    def edit_event(self, event):
        widget = self.root.focus_get()
        if widget is not None:
            widget.event_generate(event)

    def button(self, parent, name, title, command, primary=False):
        button = ttk.Button(parent, text=title, command=command,
                            style="Primary.TButton" if primary else "TButton")
        self.buttons[name] = button
        return button

    def _panel(self):
        panel = ttk.Frame(self.root, padding=20)
        panel.pack(fill="both", expand=True)
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(8, weight=1)

        top = ttk.Frame(panel)
        top.grid(row=0, column=0, sticky="ew", pady=(0, 14))
        top.columnconfigure(0, weight=1)
        self.recents = ttk.Combobox(top, textvariable=self.path, values=self.settings.recent, state="readonly")
        self.recents.grid(row=0, column=0, sticky="ew", padx=(0, 12))
        self.recents.bind("<<ComboboxSelected>>", lambda _: self.open_path(self.path.get()))
        self.button(top, "open", "Open...", self.open_dialog).grid(row=0, column=1, padx=4)
        self.button(top, "refresh", "Refresh", self.refresh).grid(row=0, column=2, padx=4)
        ttk.Separator(panel).grid(row=1, column=0, sticky="ew")

        status = ttk.Frame(panel)
        status.grid(row=2, column=0, sticky="ew", pady=(12, 4))
        status.columnconfigure(0, weight=1)
        ttk.Label(status, textvariable=self.branch, style="Heading.TLabel", width=1).grid(row=0, column=0, sticky="ew")
        self.button(status, "init", "Initialize repository", self.initialize).grid(row=0, column=1, padx=4)
        self.button(status, "branch", "New branch...", self.new_branch).grid(row=0, column=2)
        ttk.Label(status, textvariable=self.summary, width=1).grid(row=1, column=0, sticky="ew", pady=5)

        origin = ttk.Frame(panel)
        origin.grid(row=3, column=0, sticky="ew", pady=(0, 8))
        origin.columnconfigure(0, weight=1)
        self.remote_label = ttk.Label(origin, textvariable=self.remote, wraplength=590)
        self.remote_label.grid(row=0, column=0, sticky="w")
        self.button(origin, "remote", "Remote...", self.set_remote).grid(row=0, column=1, sticky="e")
        self.recovery = ttk.Frame(panel)
        self.recovery.grid(row=4, column=0, sticky="ew", pady=(0, 8))
        ttk.Label(self.recovery, text="Recovery", style="Warning.TLabel").pack(side="left", padx=(0, 12))
        self.button(self.recovery, "resolve", "Resolve files...", self.resolve).pack(side="left", padx=4)
        self.button(self.recovery, "continue", "Continue", lambda: self.recover(False)).pack(side="left", padx=4)
        self.button(self.recovery, "abort", "Abort...", lambda: self.recover(True)).pack(side="left", padx=4)

        composer = ttk.Frame(panel)
        composer.grid(row=5, column=0, sticky="ew", pady=8)
        composer.columnconfigure(0, weight=1)
        ttk.Label(composer, text="Commit message").grid(row=0, column=0, sticky="w", pady=(0, 5))
        self.message_entry = ttk.Entry(composer, textvariable=self.message)
        self.message_entry.grid(row=1, column=0, sticky="ew")
        commands = ttk.Frame(panel)
        commands.grid(row=6, column=0, sticky="ew", pady=(0, 14))
        commands.columnconfigure(2, weight=1)
        self.button(commands, "commit", "Commit", self.commit).grid(row=0, column=0, padx=(0, 6))
        self.button(commands, "commit_push", "Commit & Push", lambda: self.commit(True), True).grid(row=0, column=1)
        for column, name in enumerate(("pull", "push", "sync"), 3):
            self.button(commands, name, name.title(), lambda n=name: self.normal(n)).grid(row=0, column=column, padx=4)

        details = ttk.Frame(panel)
        details.grid(row=7, column=0, sticky="ew", pady=(0, 6))
        ttk.Label(details, text="Repository", style="Heading.TLabel").pack(side="left")
        self.advanced = ttk.Menubutton(details, text="Advanced...")
        self.advanced.pack(side="right")
        self.advanced_menu = tk.Menu(self.advanced, tearoff=False)
        self.advanced_menu.add_command(label="Squash...", command=self.squash)
        self.advanced_menu.add_separator()
        self.advanced_menu.add_command(label="Force push (with lease)...", command=self.force_push)
        self.advanced_menu.add_command(label="Force pull...", command=self.force_pull)
        self.advanced["menu"] = self.advanced_menu

        self.tabs = ttk.Notebook(panel)
        self.tabs.grid(row=8, column=0, sticky="nsew")
        self.texts = {}
        for title in ("Changes", "History", "Activity"):
            frame = ttk.Frame(self.tabs)
            frame.columnconfigure(0, weight=1)
            frame.rowconfigure(0, weight=1)
            text = tk.Text(frame, wrap="word", state="disabled", borderwidth=0, highlightthickness=0,
                           font=("Consolas", 10), padx=12, pady=12, width=1, height=8)
            scroll = ttk.Scrollbar(frame, command=text.yview)
            text.configure(yscrollcommand=scroll.set)
            text.grid(row=0, column=0, sticky="nsew")
            scroll.grid(row=0, column=1, sticky="ns")
            self.tabs.add(frame, text=title)
            self.texts[title] = text
        footer = ttk.Frame(panel)
        footer.grid(row=9, column=0, sticky="ew", pady=(10, 0))
        self.progress = ttk.Progressbar(footer, mode="indeterminate", length=70)
        self.progress.pack(side="left", padx=(0, 10))
        ttk.Label(footer, textvariable=self.activity).pack(side="left")
        self.button(footer, "terminal", "Terminal", self.terminal).pack(side="right")
        self.button(footer, "explorer", "Explorer", self.explorer).pack(side="right", padx=6)
        self.paint()

    def apply_skin(self, save=True):
        dark = self.skin.get() == "Dark"
        bg, panel, fg, muted, accent = (
            ("#202224", "#292C2F", "#F3F4F5", "#B4BAC0", "#2E886C") if dark else
            ("#F4F5F6", "#FFFFFF", "#202428", "#59636D", "#216B54"))
        self.style.theme_use("clam")
        self.style.configure(".", background=bg, foreground=fg, font=("Segoe UI", 10))
        self.style.configure("TButton", padding=(10, 6))
        self.style.map("TButton", background=[("active", accent)], foreground=[("disabled", muted), ("active", "#FFFFFF")])
        self.style.configure("Primary.TButton", background=accent, foreground="#FFFFFF")
        self.style.configure("Heading.TLabel", font=("Segoe UI", 11, "bold"))
        self.style.configure("Warning.TLabel", foreground="#D09D4B" if dark else "#8B540C")
        self.style.configure("TEntry", fieldbackground=panel, foreground=fg, insertcolor=fg)
        self.style.configure("TCombobox", fieldbackground=panel, foreground=fg, arrowsize=14)
        self.style.map("TCombobox", fieldbackground=[("readonly", panel)], foreground=[("readonly", fg)])
        self.style.configure("TNotebook.Tab", padding=(12, 7))
        self.style.map("TNotebook.Tab", background=[("selected", panel)])
        self.root.configure(background=bg)
        for text in self.texts.values():
            text.configure(background=panel, foreground=fg, insertbackground=fg,
                           selectbackground=accent, selectforeground="#FFFFFF")
        self.settings.skin = self.skin.get()
        if save:
            self.save_settings()

    def save_settings(self):
        try:
            self.settings.save()
        except OSError as error:
            self.log("Could not save settings: " + str(error))

    def log(self, text):
        view = self.texts["Activity"]
        view.configure(state="normal")
        view.insert("end", str(text)[:32000] + "\n")
        size = int(view.count("1.0", "end", "chars")[0])
        if size > 200000:
            view.delete("1.0", f"1.0+{size - 180000}c")
        view.see("end")
        view.configure(state="disabled")

    def replace_text(self, title, text):
        view = self.texts[title]
        view.configure(state="normal")
        view.delete("1.0", "end")
        view.insert("end", text[:200000])
        view.configure(state="disabled")

    def set_busy(self, value):
        self.busy = value
        if value:
            self.progress.start(15)
        else:
            self.progress.stop()
        self.paint()
        for control in self.setup_controls:
            if control.winfo_exists():
                control.configure(state="disabled" if value else "normal")

    def paint(self):
        state = self.state
        normal = bool(state.root) and not state.operation and not state.conflicts
        branch = normal and not state.detached
        allowed = {
            "open": True, "refresh": self.git is not None,
            "init": self.git is not None and not state.root,
            "branch": normal and bool(state.head), "remote": normal, "commit": normal,
            "commit_push": branch and bool(state.remote), "pull": branch and bool(state.remote),
            "push": branch and bool(state.remote) and bool(state.head),
            "sync": branch and bool(state.remote), "resolve": bool(state.conflicts),
            "continue": bool(state.operation) and not state.conflicts,
            "abort": bool(state.operation), "terminal": self.git is not None, "explorer": self.git is not None,
        }
        for name, button in self.buttons.items():
            button.configure(state="normal" if allowed[name] and not self.busy else "disabled")
        self.message_entry.configure(state="normal" if normal and not self.busy else "disabled")
        self.recents.configure(state="disabled" if self.busy else "readonly")
        self.advanced.configure(state="normal" if branch and state.head and not self.busy else "disabled")
        for index in (2, 3):
            self.advanced_menu.entryconfigure(index, state="normal" if state.remote else "disabled")
        if state.operation or state.conflicts:
            self.recovery.grid()
        else:
            self.recovery.grid_remove()
        if self.git and not state.root:
            self.buttons["init"].grid()
        else:
            self.buttons["init"].grid_remove()

    def submit(self, label, work, callback=None, refresh=True):
        if self.busy:
            return
        self.set_busy(True)
        self.activity.set(label + "...")
        git = self.git

        def run():
            value, state, error = None, None, None
            try:
                value = work()
            except Exception as caught:
                error = str(caught)
            if refresh and git is not None:
                try:
                    state = git.state()
                except Exception as caught:
                    error = (error + "\n" if error else "") + "Refresh failed: " + str(caught)
            self.events.put(("done", (value, state, error, callback)))
        threading.Thread(target=run, daemon=True).start()

    def poll(self):
        try:
            while True:
                event, value = self.events.get_nowait()
                if event == "log":
                    self.log(value)
                else:
                    result, state, error, callback = value
                    if state is not None:
                        self.display_state(state)
                    elif self.git is not None and error:
                        self.state = State()
                    self.set_busy(False)
                    self.activity.set("Action stopped" if error else "Ready")
                    if error:
                        self.log(error)
                        self.tabs.select(2)
                        messagebox.showerror("JustGit", error[:4000], parent=self.root)
                    elif callback is not None:
                        callback(result)
        except queue.Empty:
            pass
        self.poll_id = self.root.after(50, self.poll)

    def display_state(self, state):
        self.state = state
        if state.root and self.git:
            self.git.path = state.root
            self.path.set(state.root)
            self.settings.recent = Settings.valid_paths([state.root, *self.settings.recent])
            self.recents.configure(values=self.settings.recent)
            self.save_settings()
        self.root.title("JustGit" + (" - " + Path(self.git.path).name if self.git else ""))
        self.branch.set(state.branch if state.root else "Not a Git repository")
        details = [f"{len(state.files)} changed" if state.files else "Working tree clean"]
        if state.ahead:
            details.append(f"{state.ahead} ahead")
        if state.behind:
            details.append(f"{state.behind} behind")
        if state.operation:
            details.append(state.operation + " in progress")
        if state.conflicts:
            details.append(f"{len(state.conflicts)} conflicts")
        if not state.head:
            details.append("No commits")
        self.summary.set("  |  ".join(details) if state.root else "")
        # Do not display embedded credentials from externally configured URLs.
        from urllib.parse import urlsplit, urlunsplit
        remote = state.remote
        if "://" in remote:
            try:
                parsed = urlsplit(remote)
                remote = urlunsplit((parsed.scheme, parsed.netloc.rsplit("@", 1)[-1], parsed.path, "", ""))
            except ValueError:
                remote = "(invalid remote URL)"
        self.remote.set("origin  " + (remote or "Not configured"))
        self.replace_text("Changes", "\n".join(state.files) if state.files else "Working tree clean" if state.root else "No repository")
        self.replace_text("History", state.history or "No commits")

    def open_dialog(self):
        if self.busy or self.root.grab_current() is not None:
            return
        path = filedialog.askdirectory(parent=self.root, title="Open repository", mustexist=True)
        if path:
            self.open_path(path)

    def open_path(self, path):
        if self.busy or self.root.grab_current() is not None:
            return
        folder = Path(path)
        if folder.is_file():
            folder = folder.parent
        if not folder.is_dir():
            self.settings.recent = Settings.valid_paths(self.settings.recent)
            self.recents.configure(values=self.settings.recent)
            self.path.set(self.git.path if self.git else "")
            self.save_settings()
            messagebox.showerror("Folder unavailable", str(path), parent=self.root)
            return
        self.git = Git(folder, log=lambda text: self.events.put(("log", text)))
        self.state = State()
        self.replace_text("Activity", "")
        self.replace_text("Changes", "Loading...")
        self.replace_text("History", "Loading...")
        self.tabs.select(0)
        self.path.set(self.git.path)
        self.message.set("")
        self.submit("Opening repository", lambda: None)

    def refresh(self):
        if self.git and not self.busy and self.root.grab_current() is None:
            self.submit("Refreshing", lambda: None)

    def focused(self, event):
        if event.widget is self.root and self.git and not self.busy and self.root.grab_current() is None:
            self.refresh()

    def initialize(self):
        if self.git and not self.busy and messagebox.askyesno("Initialize repository", self.git.path, parent=self.root):
            self.submit("Initializing", self.git.initialize)

    def commit_message(self):
        return self.message.get().strip() or "update " + datetime.now().strftime("%Y-%m-%d %H:%M")

    def commit(self, push=False):
        if self.busy or not self.state.root or self.root.grab_current() is not None:
            return
        git, branch, message = self.git, self.state.branch, self.commit_message()
        def work():
            git.commit(message)
            if push:
                git.push(branch)
        self.submit("Committing", work, callback=lambda _: self.message.set(""))

    def normal(self, command):
        if self.busy or not self.state.root:
            return
        git, branch, message = self.git, self.state.branch, self.commit_message()
        work = (lambda: git.sync(branch, message)) if command == "sync" else lambda: getattr(git, command)(branch)
        self.submit(command.title(), work,
                    callback=(lambda _: self.message.set("")) if command == "sync" else None)

    def new_branch(self):
        if self.busy:
            return
        name = simpledialog.askstring("New branch", "Branch name", parent=self.root)
        if name:
            self.submit("Creating branch", lambda: self.git.new_branch(name))

    def set_remote(self):
        if self.busy:
            return
        url = simpledialog.askstring("Remote", "SSH/HTTPS URL or local repository path",
                                     initialvalue=self.state.remote, parent=self.root)
        if url and messagebox.askyesno("Set origin", "Replace origin's fetch and push URLs and fetch mapping?",
                                       parent=self.root):
            self.submit("Setting origin", lambda: self.git.set_remote(url))

    def squash(self):
        if self.busy:
            return
        count = simpledialog.askinteger("Squash", "First-parent commits to combine (1 amends the message)",
                                        initialvalue=2, minvalue=1, parent=self.root)
        if count is None:
            return
        message = simpledialog.askstring("Squash", "Replacement commit message", parent=self.root)
        if message and message.strip():
            git, state = self.git, self.state
            self.submit("Squashing", lambda: git.squash(state.branch, count, message.strip(), state.head))

    def force_push(self):
        if self.busy:
            return
        git, branch = self.git, self.state.branch
        def confirm(preview):
            text = preview.lost or "No remote-only commits."
            if messagebox.askyesno("Force push with lease",
                                   "Replace origin/" + branch + "?\n\nRemote-only commits:\n" + text[:6000],
                                   icon="warning", parent=self.root):
                self.submit("Force pushing", lambda: git.force_push(preview))
        self.submit("Preparing preview", lambda: git.preview_push(branch), callback=confirm)

    def force_pull(self):
        if self.busy:
            return
        if messagebox.askyesno("Force pull", "Replace local history with origin? A backup branch and stash "
                               "of all local changes, including ignored files, are required first.",
                               icon="warning", parent=self.root):
            git, branch = self.git, self.state.branch
            self.submit("Force pulling", lambda: git.force_pull(branch))

    def resolve(self):
        if self.busy or not self.state.conflicts:
            return
        window = tk.Toplevel(self.root)
        window.title("Resolve files")
        window.transient(self.root)
        window.grab_set()
        choice = tk.StringVar(value=self.state.conflicts[0])
        ttk.Combobox(window, textvariable=choice, values=self.state.conflicts, state="readonly",
                     width=55).pack(padx=20, pady=20)
        def mark():
            file = choice.get()
            if messagebox.askyesno("Mark resolved", "Have you edited and resolved this file?\n" + file, parent=window):
                window.destroy()
                self.submit("Marking resolved", lambda: self.git.resolve(file))
        ttk.Button(window, text="Mark resolved", command=mark).pack(pady=(0, 20))

    def recover(self, abort):
        if self.busy:
            return
        if abort and not messagebox.askyesno("Abort", "Discard resolution edits and abort this operation?",
                                            icon="warning", parent=self.root):
            return
        self.submit("Aborting" if abort else "Continuing", lambda: self.git.recover(abort))

    def explorer(self):
        if self.git and not self.busy:
            try:
                if os.name == "nt":
                    os.startfile(self.git.path)
                else:
                    subprocess.Popen(["open", self.git.path])
            except OSError as error:
                messagebox.showerror("Explorer", str(error), parent=self.root)

    def terminal(self):
        if self.git and not self.busy:
            try:
                if os.name == "nt":
                    # No shell string or user path interpolation into cmd syntax.
                    subprocess.Popen([os.environ.get("COMSPEC", "cmd.exe")], cwd=self.git.path,
                                     creationflags=subprocess.CREATE_NEW_CONSOLE)
                else:
                    subprocess.Popen(["open", "-a", "Terminal", self.git.path])
            except OSError as error:
                messagebox.showerror("Terminal", str(error), parent=self.root)

    def open_setup(self):
        if self.busy:
            return
        if self.setup_window and self.setup_window.winfo_exists():
            self.setup_window.lift()
            return
        window = tk.Toplevel(self.root)
        self.setup_window = window
        window.title("Setup")
        window.transient(self.root)
        window.minsize(520, 400)
        frame = ttk.Frame(window, padding=20)
        frame.pack(fill="both", expand=True)
        frame.columnconfigure(1, weight=1)
        name, email, host = tk.StringVar(), tk.StringVar(), tk.StringVar(value="github.com")
        self.setup_controls = []
        for row, (label, variable) in enumerate((("Name", name), ("Email", email), ("SSH host", host))):
            ttk.Label(frame, text=label).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=6)
            entry = ttk.Entry(frame, textvariable=variable, width=42)
            entry.grid(row=row, column=1, sticky="ew", pady=6)
            self.setup_controls.append(entry)
        public = tk.Text(frame, height=6, width=55, wrap="word", state="disabled")
        public.grid(row=4, column=0, columnspan=2, sticky="nsew", pady=14)
        public.configure(background=self.texts["Changes"]["background"], foreground=self.texts["Changes"]["foreground"])

        def show_key(value):
            if window.winfo_exists():
                public.configure(state="normal")
                public.delete("1.0", "end")
                public.insert("end", value)
                public.configure(state="disabled")

        def load():
            values = [execute(tool_path("git"), ["config", "--global", "--get", key]).value
                      for key in ("user.name", "user.email")]
            key = key_file().with_suffix(".pub")
            return (*values, key.read_text(encoding="utf-8") if key.exists() else "")

        def loaded(values):
            if window.winfo_exists():
                name.set(values[0])
                email.set(values[1])
                show_key(values[2])

        def save():
            values = (name.get().strip(), email.get().strip())
            if not all(values):
                messagebox.showerror("Identity", "Name and email are required.", parent=window)
                return
            def work():
                for key, value in zip(("user.name", "user.email"), values):
                    result = execute(tool_path("git"), ["config", "--global", key, value])
                    if result.code:
                        raise GitError(result.text)
            self.submit("Saving identity", work, refresh=False)

        def generate():
            comment = email.get().strip()
            self.submit("Creating or recovering key", lambda: create_key(comment), callback=show_key, refresh=False)

        def copy():
            value = public.get("1.0", "end").strip()
            if value:
                self.root.clipboard_clear()
                self.root.clipboard_append(value)
                self.activity.set("Public key copied")

        def test():
            target = host.get()
            self.submit("Testing SSH", lambda: test_ssh(target), callback=self.log, refresh=False)

        buttons = ttk.Frame(frame)
        buttons.grid(row=3, column=0, columnspan=2, sticky="w", pady=10)
        for label, command in (("Save identity", save), ("Create / recover key", generate), ("Test SSH", test)):
            button = ttk.Button(buttons, text=label, command=command)
            button.pack(side="left", padx=(0, 8))
            self.setup_controls.append(button)
        copy_button = ttk.Button(frame, text="Copy public key", command=copy)
        copy_button.grid(row=5, column=0, columnspan=2, sticky="w")
        self.setup_controls.append(copy_button)
        self.submit("Loading setup", load, callback=loaded, refresh=False)

    def close(self):
        if self.busy:
            messagebox.showinfo("Operation in progress", "Wait for the current operation before quitting.", parent=self.root)
            return
        self.save_settings()
        self.root.after_cancel(self.poll_id)
        self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description="JustGit desktop")
    parser.add_argument("folder", nargs="?")
    parser.add_argument("--smoke-test", action="store_true", help="Check UI construction without modifying settings")
    args = parser.parse_args()
    if os.name == "nt":
        import ctypes
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except (AttributeError, OSError):
            pass
    root = tk.Tk()
    if args.smoke_test:
        import faulthandler
        faulthandler.dump_traceback_later(30, exit=True)
        import tempfile
        with tempfile.TemporaryDirectory(prefix="justgit-ui-") as folder:
            app = App(root, Settings(Path(folder) / "settings.json"), restore=False)
            root.update()
            assert "setup" not in app.buttons and "skin" not in app.buttons
            for width, height in ((780, 560), (1100, 760)):
                root.geometry(f"{width}x{height}")
                root.update()
                for widget in app.buttons.values():
                    if widget.winfo_ismapped():
                        assert widget.winfo_width() >= widget.winfo_reqwidth(), widget["text"]
            app.skin.set("Dark")
            app.apply_skin(save=False)
            root.update()
            app.state = State(root=folder, branch="main", head="test", remote="test",
                              operation="rebase", files=("UU file.txt",), conflicts=("file.txt",))
            app.paint()
            root.update()
            assert app.recovery.winfo_ismapped()
            assert app.buttons["resolve"].instate(["!disabled"])
            assert app.buttons["commit"].instate(["disabled"])
            app.state = State(root=folder, branch="(detached)", head="test")
            app.paint()
            root.update()
            assert app.buttons["branch"].instate(["!disabled"])
            assert app.buttons["push"].instate(["disabled"])
            assert not app.recovery.winfo_ismapped()
            app.close()
        faulthandler.cancel_dump_traceback_later()
        print("Desktop UI smoke test passed.")
        return
    app = App(root, restore=not bool(args.folder))
    if args.folder:
        root.after(100, lambda: app.open_path(args.folder))
    root.mainloop()


if __name__ == "__main__":
    main()
