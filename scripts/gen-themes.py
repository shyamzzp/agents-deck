#!/usr/bin/env python3
"""Turn iTerm2 colour schemes into the token sets the dashboard reads.

Two sources, both optional:

  --yaml DIR    the yaml/ folder of mbadolato/iTerm2-Color-Schemes (MIT)
  --presets F   iTerm2's own ColorPresets.plist, normally found at
                <iTerm.app>/Contents/Resources/ColorPresets.plist

A scheme gives us a background, a foreground and sixteen ANSI colours. The
dashboard wants rather different things -- a panel that lifts off the
background, two weights of rule, a colour for "this one needs you". Those are
derived here rather than in CSS so that the stock theme keeps the exact hex it
has always had: an approximation would quietly restyle the default deck.

Usage:
  scripts/gen-themes.py --yaml ../iTerm2-Color-Schemes/yaml \
      --presets ~/Applications/iTerm.app/Contents/Resources/ColorPresets.plist \
      --out backend/internal/web/static/themes.json \
      --copy clients/flutter/agents_ui/assets/themes.json
"""

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

# The deck as it has always looked. Kept verbatim: it is the fallback in CSS,
# and the first entry in the picker.
STOCK = {
    # The app in the browser, as upstream draws it (settings.css :root).
    "--ground": "#1A1A18", "--panel": "#141412", "--block": "#222220",
    "--raised": "#2A2A27", "--hover": "#1C1C19", "--rule": "#3B3A36",
    "--line": "#262622", "--edge": "#55524B", "--term": "#0A0A0A",
    "--ink": "#E8E4DC", "--text": "#C9C5BC", "--soft": "#B5B1A8",
    "--muted": "#9A968C", "--dim": "#7A776F", "--orange": "#FF4D00",
    "--orange2": "#FF6A2E", "--ok": "#6FD69A", "--bad": "#F2766B",
    # The deck's own tokens, still drawn by the Flutter clients and the panel.
    "--bg": "#0A0A0A", "--accent": "#FF4D00", "--line-2": "#2A2925",
    "--empty": "#0B0B0B", "--sub-on-ink": "#3B3A36", "--empty-edge": "#22221F",
    "--sel": "#1C1C19", "--focus-bg": "#24241F", "--accent-hi": "#FF6A26",
    "--accent-edge": "#5A2E18", "--meta": "#9A968C", "--track": "#2A2925",
    "--panel-on": "#24241F", "--tool-claude": "#C98B6B",
    "--tool-codex": "#4FB3A6", "--tool-gemini": "#6F8FD8",
}


def clamp(n):
    return max(0, min(255, int(round(n))))


def parse_hex(s):
    s = s.strip().lstrip("#")
    if len(s) == 3:
        s = "".join(c * 2 for c in s)
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def to_hex(rgb):
    return "#%02X%02X%02X" % tuple(clamp(c) for c in rgb)


def mix(a, b, pct):
    """pct per cent of a, the rest b -- CSS color-mix in sRGB."""
    ra, rb = parse_hex(a), parse_hex(b)
    f = pct / 100.0
    return to_hex(tuple(ra[i] * f + rb[i] * (1 - f) for i in range(3)))


def luminance(c):
    def ch(v):
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = parse_hex(c)
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def saturation(c):
    r, g, b = (v / 255.0 for v in parse_hex(c))
    hi, lo = max(r, g, b), min(r, g, b)
    return 0.0 if hi == 0 else (hi - lo) / hi


def pick_accent(bg, fg, colors, cursor):
    """The colour that means "this one needs you".

    The stock accent is a hot orange, so the warm ANSI slots are tried first,
    then the rest, then the cursor. A candidate has to carry on the background
    and not read as the ordinary foreground, or the alert states stop being
    alerts.
    """
    order = [2, 10, 4, 12, 6, 14, 3, 11, 7, 15, 5, 13]
    cands = [colors[i - 1] for i in order if colors[i - 1]] + ([cursor] if cursor else [])
    ok = [c for c in cands if contrast(c, bg) >= 2.5 and contrast(c, fg) >= 1.3]
    if ok:
        return ok[0]
    # Nothing carries: lean on whichever candidate is furthest from the
    # background, so the state is at least visible.
    return max(cands, key=lambda c: contrast(c, bg)) if cands else fg


def pick_dim(bg, fg, colors):
    """Second-rank text: "idle 3h", "done 1h ago", the counts in the header.

    Bright black is the scheme's own answer to this and is used where it
    carries. 3.0 is where such text stops being a smudge; plenty of light
    schemes sit just under it, and a fixed blend towards the foreground does
    not always clear it either (a low-contrast scheme like Solarized Light has
    little room between the two). So the blend walks towards the foreground
    until it does, and settles for the foreground itself rather than leave the
    text unreadable.
    """
    c = colors[8]  # color_09, bright black
    if c and 3.0 <= contrast(c, bg) <= 9.0:
        return c
    for pct in (55, 65, 75, 85, 95):
        blend = mix(fg, bg, pct)
        if contrast(blend, bg) >= 3.0:
            return blend
    return fg


def lift(c, against, target):
    """c, moved away from `against` until it carries at `target`.

    A terminal scheme only has to carry one size of monospace text, and some
    of them (Penumbra, Solarized, Ozz's Blizzard) sit at 2.5-4:1. The deck
    draws smaller text and more of it, so a colour that low is walked away
    from the surface it sits on, towards black or white depending on which
    side of it the surface is, until it clears the floor. 595 of the 611
    schemes never reach this: their own colours already carry.

    The walk keeps the scheme's own direction: black text on Hot Dog Stand's
    red stays black and settles at 3.9, because turning it white to buy
    0.6 of contrast would not be that scheme any more.
    """
    if contrast(c, against) >= target:
        return c
    towards = "#000000" if luminance(against) > luminance(c) else "#FFFFFF"
    for pct in range(95, -1, -5):
        blend = mix(c, towards, pct)
        if contrast(blend, against) >= target:
            return blend
    return towards


def tool_colour(c, bg, fg, fallback):
    if c and contrast(c, bg) >= 2.0:
        return c
    return fallback


# What the deck's text has to carry against the surface it sits on. The ink
# floor is WCAG AA for body text; second-rank text is held to the 3.0 that
# pick_dim already uses.
INK_FLOOR = 4.5
MUTED_FLOOR = 3.0


def tokens_for(bg, fg, colors, cursor):
    light = luminance(bg) > 0.5
    accent = pick_accent(bg, fg, colors, cursor)
    # Panels sit on --ground, a step of the background towards the
    # foreground, so that is what the text has to carry against.
    ground = mix(bg, fg, 92.8)
    fg = lift(fg, ground, INK_FLOOR)
    dim = pick_dim(bg, fg, colors)
    t = {
        "--bg": bg.upper(),
        "--ink": fg.upper(),
        "--accent": accent.upper(),
        "--dim": dim.upper(),
        # Surfaces, each a step of the background towards the foreground. Every
        # percentage below was solved from the stock theme's own hex, so a
        # scheme is restyled by the same amounts the deck already uses.
        "--panel": mix(bg, fg, 95.5),
        "--empty": mix(bg, fg, 99.5),
        "--empty-edge": mix(bg, fg, 89.2),
        "--sel": mix(bg, fg, 91.9),
        "--focus-bg": mix(bg, fg, 88.3),
        "--line": mix(bg, fg, 87.4),
        "--line-2": mix(bg, fg, 85.6),
        "--track": mix(bg, fg, 85.6),
        "--panel-on": mix(bg, fg, 88.3),
        "--edge": mix(bg, fg, 77.9),
        "--meta": lift(mix(bg, fg, 35.1), ground, MUTED_FLOOR),
        "--sub-on-ink": mix(bg, fg, 77.9),
        "--accent-hi": mix(accent, fg, 88),
        "--accent-edge": mix(accent, bg, 45),
        "--tool-claude": tool_colour(colors[3], bg, fg, STOCK["--tool-claude"]),
        "--tool-codex": tool_colour(colors[6], bg, fg, STOCK["--tool-codex"]),
        "--tool-gemini": tool_colour(colors[4], bg, fg, STOCK["--tool-gemini"]),
    }
    # The app in the browser has its own names for the same idea. Every blend
    # below was solved from upstream's own hex, so the stock theme comes back
    # exactly rather than approximately.
    green = colors[2] or colors[10]
    red = colors[1] or colors[9]
    t.update({
        "--term": bg.upper(),
        "--ground": ground,
        "--block": mix(bg, fg, 89.2),
        "--raised": mix(bg, fg, 85.6),
        "--hover": mix(bg, fg, 91.9),
        "--rule": mix(bg, fg, 77.9),
        "--edge": mix(bg, fg, 66.2),
        "--text": mix(bg, fg, 14.0),
        "--soft": mix(bg, fg, 23.0),
        "--muted": lift(mix(bg, fg, 35.1), ground, MUTED_FLOOR),
        "--orange": accent.upper(),
        "--orange2": mix(accent, fg, 88),
        "--ok": tool_colour(green, bg, fg, STOCK["--ok"]),
        "--bad": tool_colour(red, bg, fg, STOCK["--bad"]),
    })
    return t, light


# Both quote styles are in use, and most files carry a trailing `# Red (...)`
# comment naming the ANSI slot.
FIELD = re.compile(r"""^\s*([a-z_0-9]+)\s*:\s*['"]?\#?([0-9A-Fa-f]{6})['"]?\s*(?:\#.*)?$""")
NAME = re.compile(r"""^\s*name\s*:\s*['"]?(.*?)['"]?\s*(?:\#.*)?$""")


def read_yaml(path):
    """These files are a flat list of `key: "#rrggbb"`, so no parser is needed."""
    out, name = {}, path.stem
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = FIELD.match(line)
        if m:
            out[m.group(1)] = "#" + m.group(2)
            continue
        m = NAME.match(line)
        if m:
            name = m.group(1)
    if "background" not in out or "foreground" not in out:
        return None
    colors = [out.get("color_%02d" % i) for i in range(1, 17)]
    if sum(c is not None for c in colors) < 8:
        return None
    return name, out["background"], out["foreground"], colors, out.get("cursor")


def read_presets(path):
    """iTerm2's own presets: component floats, 0..1, in a plist."""
    with open(path, "rb") as f:
        data = plistlib.load(f)
    for name, p in sorted(data.items()):
        def col(key):
            c = p.get(key)
            if not isinstance(c, dict):
                return None
            try:  # components are floats, but some presets store them as strings
                return to_hex(tuple(float(c.get(k, 0.0)) * 255.0 for k in
                                    ("Red Component", "Green Component", "Blue Component")))
            except (TypeError, ValueError):
                return None
        bg, fg = col("Background Color"), col("Foreground Color")
        if not bg or not fg:
            continue
        colors = [col("Ansi %d Color" % i) for i in range(16)]
        if sum(c is not None for c in colors) < 8:
            continue
        yield name, bg, fg, colors, col("Cursor Color")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--yaml", type=Path)
    ap.add_argument("--presets", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--copy", type=Path, action="append", default=[],
                    help="write the same file here too (the Flutter clients bundle a copy)")
    args = ap.parse_args()

    themes, seen = [], set()

    def add(name, bg, fg, colors, cursor, source):
        key = name.strip().lower()
        if not key or key in seen:
            return
        seen.add(key)
        t, light = tokens_for(bg, fg, colors, cursor)
        themes.append({"name": name.strip(), "light": light, "source": source, "tokens": t})

    # iTerm2's built-ins first, so a name they share is theirs.
    if args.presets and args.presets.exists():
        for row in read_presets(args.presets):
            add(*row, "iterm2")

    if args.yaml and args.yaml.is_dir():
        for p in sorted(args.yaml.glob("*.yml")) + sorted(args.yaml.glob("*.yaml")):
            row = read_yaml(p)
            if row:
                add(*row, "iterm2-color-schemes")

    themes.sort(key=lambda x: x["name"].lower())
    stock = {"name": "agents deck", "light": False, "source": "built-in", "tokens": dict(STOCK)}
    out = {"version": 1, "default": "agents deck", "themes": [stock] + themes}
    text = json.dumps(out, separators=(",", ":"), ensure_ascii=False) + "\n"
    args.out.write_text(text, encoding="utf-8")
    for also in args.copy:
        also.parent.mkdir(parents=True, exist_ok=True)
        also.write_text(text, encoding="utf-8")
    dark = sum(1 for t in themes if not t["light"])
    print("%d themes (%d dark, %d light) -> %s (%.0f KB)" %
          (len(out["themes"]), dark + 1, len(themes) - dark, args.out,
           args.out.stat().st_size / 1024), file=sys.stderr)


if __name__ == "__main__":
    main()
