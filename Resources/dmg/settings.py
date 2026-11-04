# dmgbuild settings for the Usage HUD installer window.
# Defines passed with -D: app (path to the signed "Usage HUD.app").
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
appname = os.path.basename(app)
here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else defines.get("here", ".")  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
badge_icon = None
background = defines.get("background")  # noqa: F821
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {appname: (170, 190), "Applications": (470, 190)}
# Hiding the signed app extension writes FinderInfo onto its bundle after
# signing, invalidating the strict signature check on the mounted image.
hide_extensions = []
