#!/usr/bin/env bash
# build-package.sh — runs INSIDE the Arch container
#
# Environment variables injected by container.sh:
#   PKG_NAME    — Arch package name
#   PKG_MODE    — fat | thin
#   PKG_HIDDEN  — 1 if the .desktop entry should be hidden
#   VERBOSE     — 1 for detailed output
#
# Outputs written to /work/:
#   artifact/<name>-<version>.app   — the finished AppImage renamed to .app
#   build.log                       — appended build log fragment

set -Eeuo pipefail

VERBOSE="${VERBOSE:-0}"
PKG_HIDDEN="${PKG_HIDDEN:-0}"

_log()  { echo "[container] $*"; }
_vlog() { [[ "$VERBOSE" == "1" ]] && echo "[container] $*" || true; }
_err()  { echo "[container][ERR] $*" >&2; }

# ── Validate inputs ───────────────────────────────────────────────────────────
[[ -n "${PKG_NAME:-}" ]] || { _err "PKG_NAME is not set."; exit 1; }
[[ -n "${PKG_MODE:-}" ]] || { _err "PKG_MODE is not set."; exit 1; }
[[ "$PKG_MODE" == "fat" || "$PKG_MODE" == "thin" ]] || {
  _err "Unknown PKG_MODE: $PKG_MODE"; exit 1
}

_log "Building $PKG_NAME  mode=$PKG_MODE  hidden=$PKG_HIDDEN"

# ── Directories ───────────────────────────────────────────────────────────────
WORK_DIR="/work"
APPDIR="${WORK_DIR}/AppDir"
ARTIFACT_DIR="${WORK_DIR}/artifact"
mkdir -p "$APPDIR" "$ARTIFACT_DIR"

# ── 1. Sync package databases and install the package ────────────────────────
_log "Synchronising package databases and upgrading base system..."
pacman -Syu --noconfirm 2>&1 | { [[ "$VERBOSE" == "1" ]] && cat || tail -3; }

_log "Installing $PKG_NAME and build tools..."
pacman -S --noconfirm --needed "$PKG_NAME" wget 2>&1 | { [[ "$VERBOSE" == "1" ]] && cat || tail -5; }

# ── 2. Determine package version ─────────────────────────────────────────────
VERSION="$(pacman -Qi "$PKG_NAME" | awk '/^Version/{print $3; exit}')"
VERSION="${VERSION#*:}"   # strip epoch
VERSION="${VERSION%-*}"   # strip pkgrel
_log "Version: $VERSION"
echo "$VERSION" > "${WORK_DIR}/version"

# ── 3. Collect package files into AppDir ─────────────────────────────────────
_log "Collecting package files..."

while IFS= read -r fpath; do
  [[ -f "$fpath" || -L "$fpath" ]] || continue
  dest="${APPDIR}${fpath}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$fpath" "$dest"
done < <(pacman -Ql "$PKG_NAME" | awk '{print $2}')

# ── 4. Patch shell wrappers that use absolute /usr/ paths ────────────────────
# Some packages ship a thin shell wrapper in /usr/bin/ that hardcodes an
# absolute path like /usr/lib/<pkg>/<binary>.  Inside an AppImage $APPDIR is
# not /usr, so those paths do not exist on the host.  We rewrite every such
# wrapper to use ${APPDIR}/usr/ which the AppImage runtime sets before AppRun.
_log "Patching shell wrappers..."
while IFS= read -r wrapper; do
  file "$wrapper" | grep -q 'shell script' || continue
  grep -q '/usr/' "$wrapper" || continue
  _vlog "  patching wrapper: $wrapper"
  sed -i 's|/usr/|${APPDIR}/usr/|g' "$wrapper"
done < <(find "${APPDIR}/usr/bin" -maxdepth 1 -type f 2>/dev/null)

# ── 5. Dependency collection (fat vs thin) ────────────────────────────────────
# System libraries that must NEVER be bundled — they must come from the host.
SYSTEM_LIB_PATTERNS=(
  'libm.so' 'libc.so' 'libpthread.so' 'libdl.so' 'librt.so'
  'libutil.so' 'libresolv.so' 'libnss_' 'ld-linux' 'ld-musl'
  'libGL.so' 'libGLX.so' 'libGLdispatch.so' 'libEGL.so' 'libvulkan.so'
  'libdrm.so' 'libgbm.so' 'libwayland-' 'libxcb' 'libX11' 'libXext' 'libXrender'
  'libpipewire' 'libpulse' 'libasound'
  'libfontconfig' 'libfreetype' 'libpango'
  'libdbus-' 'libsystemd' 'libudev'
)

_is_system_lib() {
  local lib="$1" pattern
  for pattern in "${SYSTEM_LIB_PATTERNS[@]}"; do
    [[ "$lib" == *"$pattern"* ]] && return 0
  done
  return 1
}

if [[ "$PKG_MODE" == "fat" ]]; then
  _log "Fat mode: collecting application-specific shared libraries..."
  while IFS= read -r elf; do
    while IFS= read -r dep_line; do
      lib_path="$(echo "$dep_line" | awk '/=>/{print $3}')"
      [[ -z "$lib_path" || "$lib_path" == "not" ]] && continue
      [[ -f "$lib_path" ]] || continue
      lib_name="$(basename "$lib_path")"
      _is_system_lib "$lib_name" && { _vlog "  skip (system): $lib_name"; continue; }
      lib_dest="${APPDIR}/usr/lib/${lib_name}"
      if [[ ! -e "$lib_dest" ]]; then
        _vlog "  bundle: $lib_path"
        cp -a "$lib_path" "$lib_dest"
      fi
    done < <(ldd "$elf" 2>/dev/null || true)
  done < <(find "$APPDIR" -type f -exec file {} \; | grep -i 'ELF.*executable\|ELF.*shared' | cut -d: -f1)
  _log "Fat mode: library collection complete."
else
  _log "Thin mode: skipping library bundling."
fi

# ── 6. Desktop file processing ────────────────────────────────────────────────
DESKTOP_DIR="${APPDIR}/usr/share/applications"
if [[ -d "$DESKTOP_DIR" ]]; then
  _log "Processing .desktop files (hidden=$PKG_HIDDEN)..."
  while IFS= read -r -d '' df; do
    sed -i 's|^Exec=/usr/bin/|Exec=|' "$df"
    sed -i 's|^Exec=/usr/local/bin/|Exec=|' "$df"
    if [[ "$PKG_HIDDEN" == "1" ]]; then
      if grep -q '^NoDisplay=' "$df"; then
        sed -i 's/^NoDisplay=.*/NoDisplay=true/' "$df"
      else
        sed -i '/^\[Desktop Entry\]/a NoDisplay=true' "$df"
      fi
      _vlog "  hidden: $(basename "$df")"
    fi
  done < <(find "$DESKTOP_DIR" -name '*.desktop' -print0)
fi

# ── 7. AppRun entry point ─────────────────────────────────────────────────────
PRIMARY_BIN="${APPDIR}/usr/bin/${PKG_NAME}"
if [[ ! -x "$PRIMARY_BIN" ]]; then
  PRIMARY_BIN="$(find "${APPDIR}/usr/bin" -maxdepth 1 -type f -executable 2>/dev/null | head -n1 || true)"
fi
[[ -n "$PRIMARY_BIN" && -x "$PRIMARY_BIN" ]] || {
  _log "Warning: no executable found in usr/bin for $PKG_NAME — AppRun will be a stub."
  PRIMARY_BIN=""
}

# AppRun — universal mount-path stability
# ----------------------------------------
# The AppImage runtime mounts the squashfs at a path with a random suffix:
#   /tmp/.mount_<name><random>/
# $HERE therefore changes on every launch.  Any application that uses its own
# executable path as a stable identity (profile locks, cache dirs, plugin
# search paths, Electron userData, Qt plugin paths, etc.) will see a different
# "installation" each time and may reset state or lose configuration.
#
# Universal mitigations:
#
#   ARGV0           — set to $APPIMAGE (the stable .app file path).
#                     The AppImage runtime already exports $APPIMAGE; ARGV0
#                     makes the same stable path visible as argv[0].
#
#   XDG_DATA_HOME   — redirected to ~/.local/share/<pkgname> so apps that
#   XDG_CONFIG_HOME   derive their data/config/cache dir from the executable
#   XDG_CACHE_HOME    path always land in the same place across launches.
#
# All three XDG overrides are only applied when the caller has NOT already
# set them, so a user can override by exporting the variables beforehand.
#
# Applications that hard-code absolute paths (~/.mozilla, ~/.config/chromium,
# etc.) are unaffected — those paths do not depend on $HERE.

APPRUN_FILE="${APPDIR}/AppRun"

# Write the static (non-interpolated) header with a quoted heredoc delimiter.
cat > "$APPRUN_FILE" <<'APPRUN_STATIC'
#!/usr/bin/env bash
# AppRun — generated by package-builder
HERE="$(dirname "$(readlink -f "$0")")"

# $APPIMAGE is set by the AppImage runtime to the stable path of the .app
# file.  Export it as ARGV0 so the application sees a consistent identity
# regardless of the random mount-point suffix in $HERE.
export ARGV0="${APPIMAGE:-$0}"

# Standard path exports
export PATH="${HERE}/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH:-}"
export XDG_DATA_DIRS="${HERE}/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
APPRUN_STATIC

# Append the per-package XDG redirects.  PKG_NAME is expanded by the outer
# shell now (build time), producing a literal package name in the AppRun
# script — that is intentional.
cat >> "$APPRUN_FILE" <<APPRUN_XDG
# Redirect XDG dirs to stable per-package locations so that apps which derive
# profile/cache paths from their executable location always land in the same
# directory across launches, regardless of the random AppImage mount path.
export XDG_DATA_HOME="\${XDG_DATA_HOME:-\${HOME}/.local/share/${PKG_NAME}}"
export XDG_CONFIG_HOME="\${XDG_CONFIG_HOME:-\${HOME}/.config/${PKG_NAME}}"
export XDG_CACHE_HOME="\${XDG_CACHE_HOME:-\${HOME}/.cache/${PKG_NAME}}"
mkdir -p "\${XDG_DATA_HOME}" "\${XDG_CONFIG_HOME}" "\${XDG_CACHE_HOME}"
APPRUN_XDG

# Append the exec line
if [[ -n "$PRIMARY_BIN" ]]; then
  echo "exec \"\${HERE}/usr/bin/$(basename "$PRIMARY_BIN")\" \"\$@\"" >> "$APPRUN_FILE"
else
  echo "echo 'No primary executable found for ${PKG_NAME}' >&2; exit 1" >> "$APPRUN_FILE"
fi
chmod +x "$APPRUN_FILE"

# Provide a top-level symlink so the executable name is discoverable.
[[ -n "$PRIMARY_BIN" ]] && ln -sf "usr/bin/$(basename "$PRIMARY_BIN")" "${APPDIR}/$(basename "$PRIMARY_BIN")" || true

# ── 8. Locate or download a .desktop and icon for appimagetool ───────────────
ROOT_DESKTOP="$(find "$APPDIR" -maxdepth 1 -name '*.desktop' 2>/dev/null | head -n1 || true)"
if [[ -z "$ROOT_DESKTOP" ]]; then
  INNER_DESKTOP="$(find "${APPDIR}/usr/share/applications" -name '*.desktop' 2>/dev/null | head -n1 || true)"
  if [[ -n "$INNER_DESKTOP" ]]; then
    cp "$INNER_DESKTOP" "${APPDIR}/$(basename "$INNER_DESKTOP")"
    ROOT_DESKTOP="${APPDIR}/$(basename "$INNER_DESKTOP")"
  else
    cat > "${APPDIR}/${PKG_NAME}.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=${PKG_NAME}
Exec=${PKG_NAME}
Icon=${PKG_NAME}
Categories=Utility;
DESKTOP
    ROOT_DESKTOP="${APPDIR}/${PKG_NAME}.desktop"
    _log "Warning: no .desktop file found — generated stub."
  fi
fi

ROOT_ICON="$(find "$APPDIR" -maxdepth 1 \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -n1 || true)"
if [[ -z "$ROOT_ICON" ]]; then
  ICON_NAME="$(grep '^Icon=' "$ROOT_DESKTOP" | head -n1 | cut -d= -f2 | xargs)"
  ICON_NAME="${ICON_NAME:-${PKG_NAME}}"
  FOUND_ICON="$(find "${APPDIR}/usr/share/icons" "${APPDIR}/usr/share/pixmaps" \
    /usr/share/icons /usr/share/pixmaps \
    -name "${ICON_NAME}.png" -o -name "${ICON_NAME}.svg" 2>/dev/null | head -n1 || true)"
  if [[ -n "$FOUND_ICON" ]]; then
    ext="${FOUND_ICON##*.}"
    cp "$FOUND_ICON" "${APPDIR}/${ICON_NAME}.${ext}"
  else
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
      > "${APPDIR}/${PKG_NAME}.png"
    _log "Warning: no icon found — using transparent stub."
  fi
fi

# ── 9. Download and run appimagetool ─────────────────────────────────────────
APPIMAGETOOL_SQUASHFS="/tmp/appimagetool.AppImage"
APPIMAGETOOL="/tmp/squashfs-root/AppRun"
if [[ ! -x "$APPIMAGETOOL" ]]; then
  _log "Downloading appimagetool..."
  wget -q -O "$APPIMAGETOOL_SQUASHFS" \
    "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod +x "$APPIMAGETOOL_SQUASHFS"
  cd /tmp && "$APPIMAGETOOL_SQUASHFS" --appimage-extract >/dev/null && cd - >/dev/null
fi

_log "Running appimagetool..."
ARCH=x86_64 "$APPIMAGETOOL" --no-appstream "$APPDIR" \
  "${ARTIFACT_DIR}/${PKG_NAME}-${VERSION}.app" \
  2>&1 | { [[ "$VERBOSE" == "1" ]] && cat || tail -10; }

_log "Build complete: ${PKG_NAME}-${VERSION}.app"
