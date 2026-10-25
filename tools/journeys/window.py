#!/usr/bin/env python3
"""Drive the built window with the operating system's own input.

The window journeys in journeys/gui press keys in a probe; this one goes through
the real window system: the window is started on the made-up disk, found by
its process, given the keyboard, sent the search shortcut and a name as key
presses, and closed as a person closes it. The window records every frame's
input as it received it (JM_UI_RECORD); journeys/window replays that recording
and checks what the keys did in the accessibility tree.

    tools/journeys/window.py build/journeys/app/Leita build/journeys/window

Linux needs an X display (just window-journey runs this under xvfb-run) and
xdotool; macOS needs the runner to be allowed to send keys through System
Events; Windows needs a desktop session. Each step that fails says which.
The result, with how long each step took, is <out>/window.json.
"""

import ctypes
import ctypes.util
import json
import os
import shutil
import subprocess
import sys
import time

TYPED = "Docker.raw"
FIND_SECONDS = 60
# The scan of the made-up disk is paced as a real walk: its status line said
# 9.6 s on the hosted Linux runner (test run 40143753338). Typing after it has
# finished searches the whole disk once.
SCAN_SECONDS = 25
# The search's answer under AddressSanitizer on a hosted runner had not come in
# 30 s (the same run), so it is given longer.
SEARCH_SECONDS = 60
EXIT_SECONDS = 60


def fail(message):
    print(f"window: {message}", file=sys.stderr)
    sys.exit(1)


def environment(home, recording):
    """The window's environment: its own home, the made-up disk, recording."""
    env = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith(("XDG_", "LEITA_")) and k not in ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA")
    }
    env.update(
        HOME=home,
        USERPROFILE=home,
        APPDATA=os.path.join(home, "data"),
        LOCALAPPDATA=os.path.join(home, "data"),
        XDG_DATA_HOME=os.path.join(home, "data"),
        XDG_CONFIG_HOME=os.path.join(home, "config"),
        XDG_STATE_HOME=os.path.join(home, "state"),
        XDG_CACHE_HOME=os.path.join(home, "cache"),
        LEITA_SYNTHETIC="0",
        JM_UI_RECORD=recording,
    )
    if sys.platform.startswith("linux"):
        env["SDL_VIDEODRIVER"] = "x11"
    return env


class X11:
    """Xlib through xdotool, and WM_DELETE_WINDOW sent as a window manager would."""

    def __init__(self):
        if not shutil.which("xdotool"):
            fail("xdotool is not installed")
        if not os.environ.get("DISPLAY"):
            fail("no X display: run under xvfb-run")

    def xdo(self, *args):
        return subprocess.run(["xdotool", *args], capture_output=True, text=True, check=False)

    def find(self, pid):
        found = self.xdo("search", "--onlyvisible", "--pid", str(pid))
        ids = found.stdout.split()
        return int(ids[-1]) if ids else None

    def focus(self, window):
        self.xdo("windowfocus", "--sync", str(window))

    def focused(self, window):
        got = self.xdo("getwindowfocus").stdout.strip()
        return got == str(window)

    def title(self, window):
        return self.xdo("getwindowname", str(window)).stdout.strip()

    def shortcut(self, key):
        self.xdo("key", "--clearmodifiers", f"ctrl+{key}")

    def type(self, text):
        self.xdo("type", "--delay", "60", text)

    def close(self, window):
        x = ctypes.cdll.LoadLibrary(ctypes.util.find_library("X11"))
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x.XInternAtom.restype = ctypes.c_ulong
        x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
        x.XFlush.argtypes = [ctypes.c_void_p]
        x.XCloseDisplay.argtypes = [ctypes.c_void_p]

        class ClientMessage(ctypes.Structure):
            _fields_ = [
                ("type", ctypes.c_int),
                ("serial", ctypes.c_ulong),
                ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p),
                ("window", ctypes.c_ulong),
                ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int),
                ("data", ctypes.c_long * 5),
            ]

        class Event(ctypes.Union):
            _fields_ = [("message", ClientMessage), ("pad", ctypes.c_long * 24)]

        display = x.XOpenDisplay(None)
        event = Event()
        event.message.type = 33  # ClientMessage
        event.message.window = window
        event.message.message_type = x.XInternAtom(display, b"WM_PROTOCOLS", 0)
        event.message.format = 32
        event.message.data[0] = x.XInternAtom(display, b"WM_DELETE_WINDOW", 0)
        x.XSendEvent(display, window, 0, 0, ctypes.byref(event))
        x.XFlush(display)
        x.XCloseDisplay(display)


class Win32:
    """user32: the window found by its process, keys sent with SendInput."""

    KEYUP, UNICODE = 0x0002, 0x0004

    def __init__(self):
        from ctypes import wintypes

        self.w = wintypes
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)

        class KEYBDINPUT(ctypes.Structure):
            _fields_ = [
                ("wVk", wintypes.WORD),
                ("wScan", wintypes.WORD),
                ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD),
                ("dwExtraInfo", ctypes.c_size_t),
            ]

        class INPUT(ctypes.Structure):
            class _U(ctypes.Union):
                _fields_ = [("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]

            _anonymous_ = ("u",)
            _fields_ = [("type", wintypes.DWORD), ("u", _U)]

        self.INPUT, self.KEYBDINPUT = INPUT, KEYBDINPUT

    def find(self, pid):
        found = []
        proc = ctypes.WINFUNCTYPE(ctypes.c_bool, self.w.HWND, self.w.LPARAM)

        def each(hwnd, _):
            owner = self.w.DWORD()
            self.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
            if owner.value == pid and self.user32.IsWindowVisible(hwnd) and self.title(hwnd):
                found.append(hwnd)
            return True

        self.user32.EnumWindows(proc(each), 0)
        return found[0] if found else None

    def title(self, window):
        buf = ctypes.create_unicode_buffer(256)
        self.user32.GetWindowTextW(window, buf, 256)
        return buf.value

    def focus(self, window):
        # SetForegroundWindow succeeds only for "the process that received
        # the last input event" among its conditions (its Win32 reference,
        # Remarks); an Alt press first is that input.
        self.keys([(0x12, 0), (0x12, self.KEYUP)])
        self.user32.SetForegroundWindow(window)

    def focused(self, window):
        return self.user32.GetForegroundWindow() == window

    def keys(self, presses, unicode=False):
        inputs = (self.INPUT * len(presses))()
        for i, (code, flags) in enumerate(presses):
            inputs[i].type = 1  # INPUT_KEYBOARD
            if unicode:
                inputs[i].ki = self.KEYBDINPUT(0, code, flags | self.UNICODE, 0, 0)
            else:
                inputs[i].ki = self.KEYBDINPUT(code, 0, flags, 0, 0)
        self.user32.SendInput(len(presses), inputs, ctypes.sizeof(self.INPUT))

    def shortcut(self, key):
        vk = ord(key.upper())
        self.keys([(0x11, 0), (vk, 0), (vk, self.KEYUP), (0x11, self.KEYUP)])

    def type(self, text):
        for ch in text:
            self.keys([(ord(ch), 0), (ord(ch), self.KEYUP)], unicode=True)
            time.sleep(0.06)

    def close(self, window):
        self.user32.PostMessageW(window, 0x0010, 0, 0)  # WM_CLOSE


class Mac:
    """System Events through osascript, which the runner must be allowed."""

    def script(self, text):
        return subprocess.run(["osascript", "-e", text], capture_output=True, text=True, check=False)

    def process(self, pid):
        return f'(first process whose unix id is {pid})'

    def find(self, pid):
        self.pid = pid
        got = self.script(f'tell application "System Events" to count windows of {self.process(pid)}')
        if got.returncode != 0:
            print(f"window: System Events: {got.stderr.strip()}", file=sys.stderr)
            return None
        return 1 if got.stdout.strip() not in ("", "0") else None

    def title(self, _):
        got = self.script(f'tell application "System Events" to get name of window 1 of {self.process(self.pid)}')
        return got.stdout.strip()

    def focus(self, _):
        self.script(f'tell application "System Events" to set frontmost of {self.process(self.pid)} to true')

    def focused(self, _):
        got = self.script(f'tell application "System Events" to get frontmost of {self.process(self.pid)}')
        return got.stdout.strip() == "true"

    def shortcut(self, key):
        self.script(f'tell application "System Events" to keystroke "{key}" using command down')

    def type(self, text):
        self.script(f'tell application "System Events" to keystroke "{text}"')

    def close(self, _):
        got = self.script(
            'tell application "System Events" to click (first button whose subrole is "AXCloseButton") '
            f"of window 1 of {self.process(self.pid)}"
        )
        if got.returncode != 0:
            print(f"window: close button: {got.stderr.strip()}", file=sys.stderr)


def main():
    if len(sys.argv) != 3:
        fail("usage: window.py WINDOW_BINARY OUT_DIR")
    binary, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    shutil.rmtree(out, ignore_errors=True)
    home = os.path.join(out, "home")
    os.makedirs(home)
    recording = os.path.join(out, "session.rec")
    if sys.platform.startswith("linux"):
        driver = X11()
    elif sys.platform == "darwin":
        driver = Mac()
    else:
        driver = Win32()

    result = {"steps": {}}
    started = time.monotonic()

    def step(name, ok):
        result["steps"][name] = {"ok": bool(ok), "at_s": round(time.monotonic() - started, 1)}
        print(f"window: {name}: {'ok' if ok else 'FAILED'} at {result['steps'][name]['at_s']} s")
        return ok

    with open(os.path.join(out, "window.log"), "w") as log:
        proc = subprocess.Popen([binary, "/Users/alex"], env=environment(home, recording), stdout=log, stderr=log)
    try:
        window = None
        deadline = time.monotonic() + FIND_SECONDS
        while window is None and time.monotonic() < deadline and proc.poll() is None:
            window = driver.find(proc.pid)
            if window is None:
                time.sleep(0.5)
        if not step("appeared", window is not None):
            fail(f"no window of process {proc.pid} in {FIND_SECONDS} s (exit {proc.poll()})")
        time.sleep(SCAN_SECONDS)
        result["title"] = driver.title(window)
        driver.focus(window)
        time.sleep(0.5)
        step("focused", driver.focused(window))
        driver.shortcut("f")
        time.sleep(1)
        driver.type(TYPED)
        step("typed", True)
        time.sleep(SEARCH_SECONDS)
        driver.close(window)
        try:
            code = proc.wait(timeout=EXIT_SECONDS)
        except subprocess.TimeoutExpired:
            code = None
        result["exit_code"] = code
        step("closed", code == 0)

        # A debug window reports its allocations as it exits (cmd/gui/main.odin
        # defers jm:debug's report): "verdict: clean" or the issues it found.
        with open(os.path.join(out, "window.log"), errors="replace") as f:
            verdicts = [line for line in f if line.startswith("verdict:")]
        if verdicts:
            step("allocator clean", all(v.startswith("verdict: clean") for v in verdicts))
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()

    with open(os.path.join(out, "window.json"), "w") as f:
        json.dump(result, f, indent=2)

    if not all(s["ok"] for s in result["steps"].values()):
        fail(f"a step failed: {json.dumps(result)}")


if __name__ == "__main__":
    main()
