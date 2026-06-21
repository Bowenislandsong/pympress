#!/bin/bash
#
# build_mac_app.sh — assemble a TeXSlide.app bundle (and optional .dmg) for macOS.
#
# Modes:
#   local     (default) The bundle launches pympress from an existing conda env on THIS
#             machine. Fast; double-clickable; not portable to other Macs. Use to verify
#             the .app / launcher / icon mechanics.
#   portable  Copy the conda env *inside* the .app so it runs on a clean Mac with nothing
#             installed. ~400 MB. Unsigned: recipients right-click -> Open the first time.
#
# Usage:  scripts/build_mac_app.sh [local|portable] [--dmg]
#
set -euo pipefail

MODE="local"
MAKE_DMG="no"
INSTALL="no"
for arg in "$@"; do
    case "$arg" in
        local|portable) MODE="$arg" ;;
        --dmg) MAKE_DMG="yes" ;;
        --install) INSTALL="yes" ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

APP_NAME="TeXSlide"
BUNDLE_ID="io.github.texslide"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$(python3 -c "import re;print(re.search(r\"__version__ = '([^']+)'\", open('$REPO/pympress/__init__.py').read()).group(1))" 2>/dev/null || echo "1.0")"

OUT_DIR="$REPO/dist"
APP="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "==> Building $APP_NAME.app  (mode: $MODE, version: $VERSION)"

# --- locate the conda env we built (pygobject/gtk3/poppler/...) ------------------------
ENV_PREFIX="${TEXSLIDE_ENV:-}"
if [ -z "$ENV_PREFIX" ]; then
    for cand in "$HOME/miniconda3/envs/texslide" "$HOME/anaconda3/envs/texslide" "${CONDA_PREFIX:-}"; do
        if [ -n "$cand" ] && [ -x "$cand/bin/python" ] && [ -d "$cand/lib/girepository-1.0" ]; then ENV_PREFIX="$cand"; break; fi
    done
fi
if [ -z "$ENV_PREFIX" ] || [ ! -x "$ENV_PREFIX/bin/python" ]; then
    echo "!! Could not find the 'texslide' conda env. Set TEXSLIDE_ENV=/path/to/env and retry." >&2
    exit 1
fi
echo "    conda env: $ENV_PREFIX"

# --- fresh bundle skeleton -------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# --- icon ------------------------------------------------------------------------------
ICON_SVG="$REPO/packaging/texslide_icon.svg"
if command -v rsvg-convert >/dev/null 2>&1 && [ -f "$ICON_SVG" ]; then
    echo "==> Rendering icon"
    ICONSET="$(mktemp -d)/$APP_NAME.iconset"; mkdir -p "$ICONSET"
    for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
                "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
                "512:512x512" "1024:512x512@2x"; do
        px="${spec%%:*}"; name="${spec##*:}"
        rsvg-convert -w "$px" -h "$px" "$ICON_SVG" -o "$ICONSET/icon_${name}.png"
    done
    iconutil -c icns "$ICONSET" -o "$RES/$APP_NAME.icns"
    rm -rf "$(dirname "$ICONSET")"
else
    echo "    (rsvg-convert or icon SVG missing — skipping icon)"
fi

# --- Info.plist ------------------------------------------------------------------------
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>          <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key>       <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>         <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>   <string>11.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>     <string>PDF document</string>
            <key>CFBundleTypeRole</key>     <string>Viewer</string>
            <key>LSItemContentTypes</key>   <array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# --- payload (portable) ----------------------------------------------------------------
if [ "$MODE" = "portable" ]; then
    echo "==> Copying environment into the bundle (this takes a minute, ~400 MB)"
    mkdir -p "$RES/env"
    # copy the env, then prune obvious bloat to keep the download smaller
    (cd "$ENV_PREFIX" && tar cf - .) | (cd "$RES/env" && tar xf -)
    find "$RES/env" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
    find "$RES/env" -type d -name 'tests' -path '*/site-packages/*' -prune -exec rm -rf {} + 2>/dev/null || true
    find "$RES/env" -type f \( -name '*.a' -o -name '*.pyc' \) -delete 2>/dev/null || true
    rm -rf "$RES/env/share/doc" "$RES/env/share/gtk-doc" "$RES/env/share/man" 2>/dev/null || true
    echo "==> Copying app source into the bundle"
    mkdir -p "$RES/app"
    (cd "$REPO" && tar cf - pympress) | (cd "$RES/app" && tar xf -)
    find "$RES/app" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
fi

# --- launcher --------------------------------------------------------------------------
# Build-time variables (expanded now); runtime logic kept literal in the quoted heredoc.
cat > "$MACOS/$APP_NAME" <<LAUNCHHEAD
#!/bin/bash
# TeXSlide launcher (generated by build_mac_app.sh, mode=$MODE)
MODE="$MODE"
ENV_PREFIX_LOCAL="$ENV_PREFIX"
REPO_LOCAL="$REPO"
LAUNCHHEAD
cat >> "$MACOS/$APP_NAME" <<'LAUNCHBODY'
APPDIR="$(cd "$(dirname "$0")/.." && pwd)"   # .../TeXSlide.app/Contents
LOG="$HOME/Library/Logs/TeXSlide-launch.log"
mkdir -p "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
echo "---- $(date) launching TeXSlide (mode=$MODE) ----"

if [ "$MODE" = "portable" ]; then
    ENVDIR="$APPDIR/Resources/env"
    SRCDIR="$APPDIR/Resources/app"
else
    ENVDIR="$ENV_PREFIX_LOCAL"
    SRCDIR="$REPO_LOCAL"
fi

if [ ! -x "$ENVDIR/bin/python" ]; then
    osascript -e 'display alert "TeXSlide" message "The TeXSlide runtime was not found. Please reinstall the app."' || true
    exit 1
fi

export PATH="$ENVDIR/bin:$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$ENVDIR/lib:${DYLD_FALLBACK_LIBRARY_PATH:-/usr/local/lib:/usr/lib}"
export GI_TYPELIB_PATH="$ENVDIR/lib/girepository-1.0"
export XDG_DATA_DIRS="$ENVDIR/share:/usr/local/share:/usr/share"
export GSETTINGS_SCHEMA_DIR="$ENVDIR/share/glib-2.0/schemas"
export FONTCONFIG_PATH="$ENVDIR/etc/fonts"
export GDK_BACKEND="${GDK_BACKEND:-quartz}"

# gdk-pixbuf's loaders.cache stores ABSOLUTE paths, which break when the bundle is moved
# to another Mac. Regenerate it at launch into a writable cache dir.
CACHE_DIR="$HOME/Library/Caches/TeXSlide"
mkdir -p "$CACHE_DIR"
if [ -x "$ENVDIR/bin/gdk-pixbuf-query-loaders" ]; then
    if "$ENVDIR/bin/gdk-pixbuf-query-loaders" > "$CACHE_DIR/loaders.cache" 2>/dev/null; then
        export GDK_PIXBUF_MODULE_FILE="$CACHE_DIR/loaders.cache"
    fi
fi
[ -n "${GDK_PIXBUF_MODULE_FILE:-}" ] || export GDK_PIXBUF_MODULE_FILE="$ENVDIR/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"

export PYTHONPATH="$SRCDIR:${PYTHONPATH:-}"

echo "ENVDIR=$ENVDIR"
echo "python: $("$ENVDIR/bin/python" --version 2>&1)"
exec "$ENVDIR/bin/python" -m pympress "$@"
LAUNCHBODY
chmod +x "$MACOS/$APP_NAME"

touch "$APP"
echo "==> Done: $APP"

# --- optional DMG ----------------------------------------------------------------------
if [ "$MAKE_DMG" = "yes" ]; then
    echo "==> Building DMG"
    DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
    STAGE="$(mktemp -d)/dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$(dirname "$STAGE")"
    echo "==> Done: $DMG"
    ls -lh "$DMG"
fi

# --- optional install to /Applications (and remove the in-repo duplicate) --------------
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ "$INSTALL" = "yes" ]; then
    echo "==> Installing to /Applications/$APP_NAME.app"
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$APP" 2>/dev/null || true   # drop old registration of the build copy
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    # remove the in-repo build copy so it doesn't show up as a 2nd app in Finder/Spotlight
    rm -rf "$APP"
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "/Applications/$APP_NAME.app" 2>/dev/null || true
    echo "==> Installed: /Applications/$APP_NAME.app  (in-repo build copy removed)"
fi

echo "    Try it:  open '/Applications/$APP_NAME.app'"
