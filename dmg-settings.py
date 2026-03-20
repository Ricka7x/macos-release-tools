#
# dmgbuild settings for Snapback
# https://dmgbuild.readthedocs.io/en/latest/settings.html
#
# Usage: dmgbuild -s scripts/dmg-settings.py "Snapback" output.dmg
# Or with defines: dmgbuild -s scripts/dmg-settings.py -D app=/path/to/Snapback.app "Snapback" output.dmg
#

import os

# `defines` is injected by dmgbuild at runtime via exec()
try:
    _d = defines  # type: ignore[name-defined]
except NameError:
    _d = {}

# App path can be overridden via -D app=...
application = _d.get("app", "Snapback.app")
app_name = os.path.basename(application)

# Files to include in the DMG
files = [application]

# Symlink to /Applications
symlinks = {"Applications": "/Applications"}

# Icon positions: {name: (x, y)}
icon_locations = {
    app_name:       (170, 210),
    "Applications": (490, 210),
}

# Window appearance
background = _d.get("background", "scripts/assets/dmg-background.png")

window_rect       = ((200, 200), (660, 480))   # ((x, y), (w, h))
default_view      = "icon-view"
show_icon_preview = False
show_status_bar   = False
show_tab_view     = False
show_toolbar      = False
show_pathbar      = False
show_sidebar      = False

icon_size         = 120
text_size         = 13
