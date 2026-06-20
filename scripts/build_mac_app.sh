#!/bin/bash
#
# build_mac_app.sh — assemble a TeXSlide.app bundle for macOS.
#
# Modes:
#   local     (default) The bundle launches pympress from an existing conda env on THIS
#             machine. Fast; double-clickable; gets you off the command line. Not portable
#             to other Macs. Use this to verify the .app / launcher / icon mechanics.
#   portable  Bundle a relocatable copy of the conda env *inside* the .app so it runs on a
#             clean Mac with nothing installed. Larger (~400 MB). Unsigned: recipients must
#             right-click -> Open the first time to get past Gatekeeper.
#
# Usage:  scripts/build_mac_app.sh [local|portable]
#
set -euo pipefail

MODE="${1:-local}"
APP_NAME="TeXSlide"
BUNDLE_ID="io.github.texslide"

# Resolve repository root (this script lives in <repo>/scripts/)
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
    for cand in "$HOME/miniconda3/envs/texslide" "$HOME/anaconda3/envs/texslide" "$CONDA_PREFIX"; do
        if [ -x "$cand/bin/python" ] && [ -d "$cand/lib/girepository-1.0" ]; then ENV_PREFIX="$cand"; break; fi
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

# --- icon: render the SVG to a full .icns ----------------------------------------------
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

# --- launcher --------------------------------------------------------------------------
if [ "$MODE" = "portable" ]; then
    echo "==> Bundling a relocatable copy of the environment (this takes a minute)"
    command -v conda-pack >/dev/null 2>&1 || { echo "!! conda-pack not installed: 'conda install -n texslide -c conda-forge conda-pack'"; exit 1; }
    mkdir -p "$RES/env"
    conda-pack -p "$ENV_PREFIX" -o "$(mktemp -d)/env.tar.gz" --force >/dev/null
    tar -xzf "$(dirname "$(mktemp -u)")"/env.tar.gz -C "$RES/env" 2>/dev/null || true
    # NB: conda-pack's exact output path handling is finalized once the local spike is confirmed.
    RUN_ENV="\$APPDIR/Resources/env"
    RUN_SRC="\$APPDIR/Resources/app"
    mkdir -p "$RES/app/pympress"
    cp -R "$REPO/pympress" "$RES/app/"
else
    RUN_ENV="$ENV_PREFIX"
    RUN_SRC="$REPO"
fi

cat > "$MACOS/$APP_NAME" <<LAUNCH
#!/bin/bash
# TeXSlide launcher (generated by build_mac_app.sh, mode=$MODE)
APPDIR="\$(cd "\$(dirname "\$0")/.." && pwd)"
LOG="\$HOME/Library/Logs/TeXSlide-launch.log"
mkdir -p "\$HOME/Library/Logs"
exec >> "\$LOG" 2>&1
echo "---- \$(date) launching TeXSlide ----"

ENVDIR="$RUN_ENV"
SRCDIR="$RUN_SRC"

if [ ! -x "\$ENVDIR/bin/python" ]; then
    osascript -e 'display alert "TeXSlide" message "The TeXSlide runtime was not found. Please reinstall the app."' || true
    exit 1
fi

export PATH="\$ENVDIR/bin:\$PATH"
export GI_TYPELIB_PATH="\$ENVDIR/lib/girepository-1.0"
export GDK_PIXBUF_MODULE_FILE="\$ENVDIR/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
export XDG_DATA_DIRS="\$ENVDIR/share:/usr/local/share:/usr/share"
export FONTCONFIG_PATH="\$ENVDIR/etc/fonts"
export PYTHONPATH="\$SRCDIR:\${PYTHONPATH:-}"
export GDK_BACKEND="\${GDK_BACKEND:-quartz}"

exec "\$ENVDIR/bin/python" -m pympress "\$@"
LAUNCH
chmod +x "$MACOS/$APP_NAME"

# refresh LaunchServices/Finder so the icon shows immediately
touch "$APP"
echo "==> Done: $APP"
echo "    Double-click it in Finder, or:  open '$APP'"
