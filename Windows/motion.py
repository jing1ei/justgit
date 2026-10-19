"""Short content transitions with cancellation and system animation preference."""
import time


def animations_enabled():
    try:
        import ctypes
        value = ctypes.c_int(1)
        if ctypes.windll.user32.SystemParametersInfoW(0x1042, 0, ctypes.byref(value), 0):
            return bool(value.value)
    except (AttributeError, OSError):
        pass
    return False


class PageTransition:
    def __init__(self, root, views):
        self.root, self.views = root, views
        self.timer = None
        self.targets = []

    def cancel(self):
        if self.timer is not None:
            self.root.after_cancel(self.timer)
            self.timer = None
        for view, color, _ in self.targets:
            if view.winfo_exists():
                view.configure(foreground=color)
        self.targets = []

    def start(self):
        self.cancel()
        if not animations_enabled():
            return
        self.targets = [(v, v.cget('foreground'), v.cget('background')) for v in self.views]
        started = time.monotonic()
        def tick():
            self.timer = None
            progress = min(1, (time.monotonic() - started) / .12)
            strength = .55 + .45 * (1 - (1 - progress) ** 2)
            for view, foreground, background in self.targets:
                if view.winfo_exists():
                    fg, bg = self.root.winfo_rgb(foreground), self.root.winfo_rgb(background)
                    color = '#' + ''.join(f'{round((b + (f - b) * strength) / 257):02x}' for f, b in zip(fg, bg))
                    view.configure(foreground=color)
            if progress < 1:
                self.timer = self.root.after(16, tick)
            else:
                self.cancel()
        tick()
