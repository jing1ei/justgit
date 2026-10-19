"""Validated appearance data. Layout and executable code are never accepted."""
import json
import math
import re


def system_is_dark():
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                           r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as key:
            return winreg.QueryValueEx(key, "AppsUseLightTheme")[0] == 0
    except (ImportError, OSError):
        return False


def resolved_style(mode, custom=None, dark=False):
    if mode == "Custom" and custom:
        return dict(custom)
    return dict(DARK if mode == "Dark" or (mode == "Automatic" and dark) else LIGHT)

LIGHT = dict(name="Opal", canvas="#FAF0F6", panel="#EDF5FF", ink="#293347",
             inkSoft="#58657C", rule="#D4DDEE", accent="#536BA5", accentInk="#FFFFFF",
             positive="#286843", negative="#B13D45", caution="#8B540C",
             consoleBg="#FCFDFF", consoleInk="#33415B", fontUI="Segoe UI",
             fontDisplay="Segoe UI", fontMono="Consolas", sizeUI=10, sizeDisplay=11, sizeMono=10)
DARK = dict(LIGHT, name="Opal Dark", canvas="#242333", panel="#283448", ink="#F4F2FC",
            inkSoft="#BDC5DE", rule="#46516C", accent="#BACDFF", accentInk="#242333", positive="#84B98E",
            negative="#EB8585", caution="#D09D4B", consoleBg="#202A3B", consoleInk="#E6EDFF")
LIMITS = dict(sizeUI=(9, 14), sizeDisplay=(10, 20), sizeMono=(9, 15))


def parse_style(raw, base=None):
    if len(raw) > 100000:
        raise ValueError("Style code is too large. Paste a single JSON object.")
    try:
        data = json.loads(raw)
    except ValueError:
        match = re.search(r"```(?:json)?\s*(.*?)```", raw, re.S)
        body = match.group(1) if match else raw[raw.find('{'):raw.rfind('}') + 1]
        try:
            data = json.loads(body)
        except ValueError as error:
            raise ValueError("Invalid JSON. Your current appearance is unchanged.") from error
    if not isinstance(data, dict):
        raise ValueError("Style code must be a JSON object.")
    result = dict(base or LIGHT)
    notes = []
    for key, value in data.items():
        if key not in LIGHT:
            notes.append(f"Ignored unsupported key: {key}")
        elif key in LIMITS:
            if isinstance(value, bool) or not isinstance(value, (float, int)) or (isinstance(value, float) and not math.isfinite(value)):
                raise ValueError(f"{key} must be a finite number.")
            low, high = LIMITS[key]
            result[key] = max(low, min(high, round(value)))
            if result[key] != value:
                notes.append(f"{key} adjusted to {result[key]} for readability.")
        elif key == "name" or key.startswith("font"):
            if not isinstance(value, str) or not value.strip() or any(ord(c) < 32 for c in value):
                raise ValueError(f"{key} must be nonempty, single-line text.")
            result[key] = value.strip()[:80]
        else:
            if not isinstance(value, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", value):
                raise ValueError(f"{key} must be a color such as #536BA5.")
            result[key] = value.upper()
    def luminance(color):
        channels = [int(color[i:i+2], 16) / 255 for i in (1, 3, 5)]
        linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in channels]
        return sum(a * b for a, b in zip(linear, (.2126, .7152, .0722)))
    for foreground, background in (("ink", "canvas"), ("consoleInk", "consoleBg"), ("accentInk", "accent")):
        a, b = sorted((luminance(result[foreground]), luminance(result[background])))
        if (b + .05) / (a + .05) < 4:
            notes.append(f"Low contrast: {foreground} on {background} may be hard to read.")
    return result, notes


def style_code(style):
    return json.dumps(style, indent=2, ensure_ascii=True)


def llm_brief(style):
    return ("Restyle JustGit. Return only the complete JSON below with revised colors and fonts. "
            "Keep all keys. Colors use #RRGGBB; font names must be installed Windows fonts. "
            "Keep text readable against its background. sizeUI: 9-14, sizeDisplay: 10-20, "
            "sizeMono: 9-15. Do not add layout, spacing, positioning, control labels, or code.\n\n"
            + style_code(style))


def readable_text(preferred, background):
    def luminance(color):
        values = [int(color[i:i+2], 16) / 255 for i in (1, 3, 5)]
        return sum((v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4) * w
                   for v, w in zip(values, (.2126, .7152, .0722)))
    bg = luminance(background)
    fg = luminance(preferred)
    if (max(bg, fg) + .05) / (min(bg, fg) + .05) >= 4.5:
        return preferred
    return '#000000' if (bg + .05) / .05 >= 1.05 / (bg + .05) else '#FFFFFF'
