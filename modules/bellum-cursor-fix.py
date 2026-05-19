#!/usr/bin/env python3
# WebView2 inside Wine creates its X11 window with cursor=None; root-cursor
# inheritance is broken on Wayland+KDE+Nvidia, so the cursor goes invisible
# over the launcher. Wine never re-sets the cursor (verified via xtrace), so a
# one-shot external XDefineCursor sticks. We re-apply on a slow poll in case
# WebView2 spawns new child windows after startup.
#
# Auto-exits ~IDLE_TIMEOUT after the last matching window disappears, so this
# is safe to launch as a background sidekick from the bellum wrapper.
import sys
import time
from Xlib import display
from Xlib.error import XError

POLL_INTERVAL = 2.0
IDLE_TIMEOUT = 10.0
STARTUP_TIMEOUT = 120.0

d = display.Display()
root = d.screen().root
cursor_font = d.open_font("cursor")
arrow = cursor_font.create_glyph_cursor(
    cursor_font,
    68,
    69,
    (0, 0, 0),
    (65535, 65535, 65535),
)


def walk(win, fn):
    try:
        fn(win)
        for c in win.query_tree().children:
            walk(c, fn)
    except XError:
        pass


def find_matches(substr):
    matches = []

    def visit(w):
        try:
            name = w.get_wm_name()
            cls = w.get_wm_class()
        except XError:
            return
        if (name and substr.lower() in name.lower()) or (
            cls and any(substr.lower() in c.lower() for c in cls)
        ):
            matches.append(w)

    walk(root, visit)
    return matches


def apply_cursor(w):
    w.change_attributes(cursor=arrow)


def main():
    substr = sys.argv[1] if len(sys.argv) > 1 else "astarte"
    print(f"bellum-cursor-fix: watching for '{substr}'", flush=True)

    start = time.time()
    last_match = None
    seen_any = False

    while True:
        matches = find_matches(substr)
        if matches:
            for w in matches:
                walk(w, apply_cursor)
            d.flush()
            last_match = time.time()
            if not seen_any:
                seen_any = True
                print(
                    f"  cursor applied to {len(matches)} window(s)", flush=True
                )
        else:
            now = time.time()
            if seen_any and (now - last_match) > IDLE_TIMEOUT:
                print("bellum-cursor-fix: launcher gone, exiting", flush=True)
                return 0
            if not seen_any and (now - start) > STARTUP_TIMEOUT:
                print(
                    "bellum-cursor-fix: no launcher window appeared, exiting",
                    flush=True,
                )
                return 1
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
