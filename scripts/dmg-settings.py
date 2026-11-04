# dmgbuild settings for Sill.dmg: night lake background, Sill on the left, Applications on the right.
import os.path
app = defines.get("app", "dist/Sill.app")  # noqa: F821 (dmgbuild injects `defines`)
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "brand/Sill.icns"
background = "brand/dmg-background.tiff"
window_rect = ((200, 160), (660, 420))
icon_size = 96
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_locations = {os.path.basename(app): (170, 180), "Applications": (490, 180)}
format = "UDZO"
