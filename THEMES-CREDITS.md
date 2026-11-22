# Theme credits

The deck ships 611 colour themes. None of the colours are ours.

## iTerm2's own presets

11 of them (Dark Background, Light Background, Solarized, Solarized Dark,
Solarized Light, Tango Dark, Tango Light, Pastel (Dark Background), Smoooooth,
High Contrast, Regular) are read from iTerm2's `ColorPresets.plist`. iTerm2 is
GPL-2.0-or-later; only the colour values are used, no code.

  https://iterm2.com

## iTerm2-Color-Schemes

The other 600 come from Mark Badolato's collection, used under the MIT licence
reproduced below. Each scheme in it carries its own author's credit in that
repository's `CREDITS.md`.

  https://github.com/mbadolato/iTerm2-Color-Schemes

## What we do with them

`scripts/gen-themes.py` reads a scheme's background, foreground and sixteen
ANSI colours and works out the tokens the dashboard needs that a terminal
scheme has no opinion about: the panel surface, two weights of rule, the
"needs you" accent. The result is `backend/internal/web/static/themes.json`.
Regenerate it with the command in that script's docstring.

---

MIT License

Copyright (c) 2011 to Present Mark Badolato

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

This license covers the iTerm-Color-Schemes repository collection of themes. 

The copyright/license for each individual theme belongs to the author of that theme.
