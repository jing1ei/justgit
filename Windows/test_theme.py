import json
from pathlib import Path
import tempfile
import unittest
from core import Settings
from theme import LIGHT, DARK, parse_style, style_code, llm_brief, resolved_style, system_is_dark, readable_text
from unittest.mock import patch, MagicMock


class ThemeTests(unittest.TestCase):
    def test_sidebar_text_falls_back_on_conflicting_colors(self):
        self.assertEqual(readable_text('#FFFFFF', '#FFFFFF'), '#000000')
        self.assertEqual(readable_text('#000000', '#000000'), '#FFFFFF')
        self.assertEqual(readable_text('#FFFFFF', '#2255AA'), '#FFFFFF')
        self.assertEqual(readable_text('#2255AA', '#2255AA'), '#FFFFFF')

    def test_default_palettes_have_readable_text_and_accents(self):
        for theme in (LIGHT, DARK):
            _, notes = parse_style(style_code(theme))
            self.assertFalse(any('Low contrast' in note for note in notes), notes)

    def test_automatic_follows_system_without_overriding_custom(self):
        self.assertEqual(resolved_style("Automatic", dark=True), DARK)
        self.assertEqual(resolved_style("Automatic", dark=False), LIGHT)
        self.assertEqual(resolved_style("Light", dark=True), LIGHT)
        custom = dict(LIGHT, accent="#123456")
        self.assertEqual(resolved_style("Custom", custom, dark=True), custom)
        with tempfile.TemporaryDirectory() as folder:
            settings = Settings(Path(folder) / "settings.json")
            self.assertEqual(settings.skin, "Automatic")
            settings.save()
            self.assertEqual(Settings(settings.path).skin, "Automatic")

    def test_windows_app_theme_preference(self):
        registry = MagicMock()
        with patch.dict('sys.modules', winreg=registry):
            registry.QueryValueEx.return_value = (0, 4)
            self.assertTrue(system_is_dark())
            registry.QueryValueEx.return_value = (1, 4)
            self.assertFalse(system_is_dark())
            registry.OpenKey.side_effect = OSError('Unavailable')
            self.assertFalse(system_is_dark())

    def test_roundtrip_and_prompt(self):
        self.assertEqual(parse_style(style_code(LIGHT))[0], LIGHT)
        self.assertIn(style_code(LIGHT), llm_brief(LIGHT))

    def test_fenced_partial_code_and_layout_rejection(self):
        style, notes = parse_style('Here it is:\n```json\n{"accent":"#123456","padding":99}\n```')
        self.assertEqual(style['accent'], '#123456')
        self.assertEqual(style['canvas'], LIGHT['canvas'])
        self.assertNotIn('padding', style)
        self.assertTrue(notes)

    def test_invalid_code_preserves_base(self):
        base = dict(LIGHT)
        for raw in ('[]', 'not json', '{"canvas":"red"}', '{"sizeUI":true}', '{"sizeUI":NaN}'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                parse_style(raw, base)
        self.assertEqual(base, LIGHT)

    def test_saved_custom_style_survives_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            settings = Settings(Path(folder) / 'settings.json')
            settings.appearance = dict(LIGHT, accent='#123456')
            settings.skin = 'Custom'
            settings.save()
            loaded = Settings(settings.path)
            self.assertEqual(loaded.skin, 'Custom')
            self.assertEqual(loaded.appearance['accent'], '#123456')

    def test_old_settings_still_load(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'settings.json'
            path.write_text(json.dumps({'skin': 'Dark', 'recent': []}))
            self.assertEqual(Settings(path).skin, 'Dark')
            self.assertIsNone(Settings(path).appearance)

    def test_extreme_sizes_and_low_contrast(self):
        style, notes = parse_style(json.dumps({'sizeUI': 10**400, 'ink': '#F4F5F6'}))
        self.assertEqual(style['sizeUI'], 14)
        self.assertTrue(any('Low contrast' in note for note in notes))
