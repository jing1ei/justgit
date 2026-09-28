"""Exercise asynchronous UI failure handling without opening a desktop window."""
import queue
import unittest
from unittest.mock import Mock, patch
from pathlib import Path
import tempfile
from core import Settings

from app import App
from core import GitError, State


class FailureStateTests(unittest.TestCase):
    def setUp(self):
        self.app = App.__new__(App)
        for name in ("root", "activity", "git", "set_busy", "display_state", "log", "tabs"):
            setattr(self.app, name, Mock())
        self.app.events = queue.Queue()
        self.app.busy = False
        self.original = State(root="repository", branch="main", head="commit")
        self.app.state = self.original

    def finish(self):
        event = self.app.events.get(timeout=5)
        self.app.events.put(event)
        with patch("app.messagebox.showerror"):
            self.app.poll()

    def test_setup_failure_preserves_repository(self):
        self.app.submit("Testing SSH", Mock(side_effect=GitError("Connection failed")), refresh=False)
        self.finish()
        self.assertIs(self.app.state, self.original)
        self.app.display_state.assert_not_called()
        self.app.git.state.assert_not_called()

    def test_completed_action_is_visible(self):
        self.app.submit("Committing", lambda: True, refresh=False)
        self.finish()
        self.app.activity.set.assert_called_with("Committing complete")

    def test_superseded_load_never_displays_stale_repository(self):
        self.app.loading_repository = True
        self.app.pending_repository = "latest"
        self.app.open_path = Mock()
        self.app.events.put(("done", (None, self.original, "old error", None, "Opening repository")))
        with patch("app.messagebox.showerror") as error:
            self.app.poll()
        self.app.display_state.assert_not_called()
        error.assert_not_called()
        self.app.open_path.assert_called_once_with("latest")
        self.assertIsNone(self.app.pending_repository)

    def test_rapid_repository_selection_keeps_only_latest(self):
        self.app.loading_repository = True
        self.app.pending_repository = None
        self.app.busy = True
        self.app.root.grab_current.return_value = None
        self.app.open_path("second")
        self.app.open_path("third")
        self.assertEqual(self.app.pending_repository, "third")

    def test_switch_preserves_commit_message_drafts(self):
        from core import Git
        with tempfile.TemporaryDirectory() as folder:
            first, second = Path(folder) / "first", Path(folder) / "second"
            first.mkdir(); second.mkdir()
            self.app.git = Git(first)
            self.app.commit_drafts = {}
            self.app.message = Mock()
            self.app.message.get.return_value = "Draft for first"
            self.app.root.grab_current.return_value = None
            self.app.transition = Mock()
            self.app.replace_text = Mock()
            self.app.path = Mock()
            self.app.branch = Mock()
            self.app.summary = Mock()
            self.app.remote = Mock()
            self.app.guidance = Mock()
            self.app.submit = Mock()
            self.app.open_path(str(second))
            self.assertEqual(self.app.commit_drafts[str(first.resolve())], "Draft for first")
            self.app.message.get.return_value = "Draft for second"
            self.app.open_path(str(first))
            self.app.message.set.assert_called_with("Draft for first")

    def test_refresh_failure_displays_unavailable_state(self):
        self.app.git.state.side_effect = GitError("Permission denied")
        self.app.submit("Refreshing", lambda: None)
        self.finish()
        state = self.app.display_state.call_args.args[0]
        self.assertIn("Permission denied", state.error)
        self.assertFalse(state.root)
        self.assertFalse(state.history)


class GuidanceTests(unittest.TestCase):
    def test_group_lifecycle_and_order_persist(self):
        with tempfile.TemporaryDirectory() as folder:
            first, second = Path(folder) / "one", Path(folder) / "two"
            first.mkdir(); second.mkdir()
            app = App.__new__(App)
            app.settings = Settings(Path(folder) / "settings.json")
            app.settings.recent = [str(first.resolve()), str(second.resolve())]
            app.busy = False
            app.root = Mock()
            app.recents = Mock()
            app.recents.curselection.return_value = ()
            app.repository_rows = []
            app.rebuild_repositories = Mock()
            app.save_settings = app.settings.save
            with patch("app.simpledialog.askstring", return_value="Work"):
                app.organize_repositories("new")
            app.settings.membership = dict.fromkeys(app.settings.recent, "Work")
            app.repository_rows = [("repo", p) for p in app.settings.recent]
            app.recents.curselection.return_value = (1,)
            app.organize_repositories("up")
            self.assertEqual(Settings(app.settings.path).recent[0], str(second.resolve()))
            app.repository_rows = [("group", "Work")]
            app.recents.curselection.return_value = (0,)
            with patch("app.simpledialog.askstring", return_value="Personal"):
                app.organize_repositories("rename")
            loaded = Settings(app.settings.path)
            self.assertEqual(loaded.groups, ["Personal"])
            self.assertEqual(set(loaded.membership.values()), {"Personal"})
            app.repository_rows = [("group", "Personal")]
            with patch("app.messagebox.askyesno", return_value=True):
                app.organize_repositories("delete")
            loaded = Settings(app.settings.path)
            self.assertEqual(loaded.groups, [])
            self.assertEqual(loaded.membership, {})
            self.assertTrue(first.is_dir() and second.is_dir())

    def test_sidebar_switches_selected_repository_and_blocks_while_busy(self):
        app = App.__new__(App)
        app.recents = Mock()
        app.recents.curselection.return_value = (1,)
        app.settings = Mock(recent=["first", "second"])
        app.repository_rows = [("repo", "first"), ("repo", "second")]
        app.git = Mock(path="first")
        app.open_path = Mock()
        app.busy = False
        app.pick_repository()
        app.open_path.assert_called_once_with("second")
        app.open_path.reset_mock()
        app.busy = True
        app.pick_repository()
        app.open_path.assert_not_called()

    def test_failed_style_save_keeps_previous_appearance(self):
        from theme import LIGHT
        app = App.__new__(App)
        app.current_style = dict(LIGHT)
        app.root = Mock()
        app.settings = Mock(appearance=None, skin="Light")
        app.settings.save.side_effect = OSError("Read-only folder")
        app.skin = Mock()
        app.apply_skin = Mock()
        with patch("app.tkfont.families", return_value=("Segoe UI", "Consolas")):
            with self.assertRaisesRegex(ValueError, "Could not save"):
                app.apply_style_code('{"accent":"#123456"}')
        self.assertIsNone(app.settings.appearance)
        self.assertEqual(app.settings.skin, "Light")
        app.skin.set.assert_not_called()
        app.apply_skin.assert_not_called()

    def test_actionable_states(self):
        for state, instruction in (
            (State(), "Initialize repository"),
            (State(root="repo"), "first snapshot"),
            (State(root="repo", head="commit"), "Use Remote"),
            (State(root="repo", head="commit", branch="(detached)"), "New branch"),
            (State(root="repo", operation="rebase", conflicts=("file",)), "Resolve files"),
            (State(root="repo", operation="rebase"), "Continue"),
            (State(error="unavailable"), "permissions"),
        ):
            with self.subTest(state=state):
                self.assertIn(instruction, state.guidance)

    def test_unchanged_refresh_preserves_text_selection(self):
        app = App.__new__(App)
        view = Mock()
        view.get.return_value = "Unchanged history"
        app.texts = {"History": view}
        app.replace_text("History", "Unchanged history")
        view.delete.assert_not_called()
        view.insert.assert_not_called()

    def test_commit_shortcut_respects_disabled_push(self):
        app = App.__new__(App)
        app.busy = False
        app.root = Mock()
        app.root.grab_current.return_value = None
        app.submit = Mock()
        for state in (State(root="repo", head="commit"),
                      State(root="repo", head="commit", remote="origin", branch="(detached)")):
            app.state = state
            app.commit(push=True)
        app.submit.assert_not_called()


if __name__ == "__main__":
    unittest.main()
