import unittest
from unittest.mock import Mock, patch
from motion import PageTransition


class TransitionTests(unittest.TestCase):
    def setUp(self):
        self.root = Mock()
        self.root.winfo_rgb.side_effect = lambda color: (65535, 65535, 65535) if color == '#ffffff' else (0, 0, 0)
        self.view = Mock()
        self.view.cget.side_effect = lambda key: '#000000' if key == 'foreground' else '#ffffff'
        self.effect = PageTransition(self.root, [self.view])

    def test_reduced_motion_has_no_timer_or_visual_change(self):
        with patch('motion.animations_enabled', return_value=False):
            self.effect.start()
        self.root.after.assert_not_called()
        self.view.configure.assert_not_called()

    def test_interruption_restores_original_color_and_cancels_timer(self):
        with patch('motion.animations_enabled', return_value=True):
            self.effect.start()
            timer = self.effect.timer
            self.effect.cancel()
        self.root.after_cancel.assert_called_once_with(timer)
        self.view.configure.assert_called_with(foreground='#000000')
        self.assertIsNone(self.effect.timer)
        self.assertEqual(self.effect.targets, [])

    def test_completion_restores_color(self):
        with patch('motion.animations_enabled', return_value=True), patch('motion.time.monotonic', side_effect=[0, 1]):
            self.effect.start()
        self.root.after.assert_not_called()
        self.view.configure.assert_called_with(foreground='#000000')
