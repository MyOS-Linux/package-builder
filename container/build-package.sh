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
_log "Synchronising package databases..."
pacman -Sy --noconfirm &>/dev/null

_log "Installing $PKG_NAME..."
pacman -S --noconfirm --needed "$PKG_NAME" 2>&1 | { [[ "$VERBOSE" == "1" ]] && cat || tail -5; }

# ── 2. Determine package version ─────────────────────────────────────────────
VERSION="$(pacman -Qi "$PKG_NAME" | awk '/^Version/{print $3; exit}')"
VERSION="${VERSION#*:}"   # strip epoch
VERSION="${VERSION%-*}"   # strip pkgrel
_log "Version: $VERSION"
echo "$VERSION" > "${WORK_DIR}/version"

# ── 3. Collect package files into AppDir ─────────────────────────────────────
_log "Collecting package files..."

# pacman -Ql lists all files owned by the package.
# We copy them into AppDir preserving the path structure.
while IFS= read -r fpath; do
  [[ -f "$fpath" || -L "$fpath" ]] || continue
  dest="${APPDIR}${fpath}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$fpath" "$dest"
done < <(pacman -Ql "$PKG_NAME" | awk '{print $2}')

# ── 4. Dependency collection (fat vs thin) ────────────────────────────────────
# System libraries that must NEVER be bundled — they must come from the host.
# This list covers glibc, the kernel interface, graphics stack, and audio.
SYSTEM_LIB_PATTERNS=(
  'libm.so'
  'libc.so'
  'libpthread.so'
  'libdl.so'
  'librt.so'
  'libutil.so'
  'libresolv.so'
  'libnss_'
  'ld-linux'
  'ld-musl'
  # Graphics / display
  'libGL.so'
  'libGLX.so'
  'libGLdispatch.so'
  'libEGL.so'
  'libvulkan.so'
  'libdrm.so'
  'libgbm.so'
  'libwayland-'
  'libxcb'
  'libX11'
  'libXext'
  'libXrender'
  # Audio
  'libpipewire'
  'libpulse'
  'libasound'
  # Font / theme
  'libfontconfig'
  'libfreetype'
  'libpango'
  # D-Bus / systemd
  'libdbus-'
  'libsystemd'
  'libudev'
)

_is_system_lib() {
  local lib="$1"
  local pattern
  for pattern in "${SYSTEM_LIB_PATTERNS[@]}"; do
    [[ "$lib" == *"$pattern"* ]] && return 0
  done
  return 1
}

if [[ "$PKG_MODE" == "fat" ]]; then
  _log "Fat mode: collecting application-specific shared libraries..."

  # Find all ELF binaries in AppDir
  while IFS= read -r elf; do
    # ldd lists all transitive shared-library dependencies
    while IFS= read -r dep_line; do
      # ldd output: "  libfoo.so.1 => /usr/lib/libfoo.so.1 (0x...)"
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

# ── 5. Desktop file processing ────────────────────────────────────────────────
DESKTOP_DIR="${APPDIR}/usr/share/applications"
if [[ -d "$DESKTOP_DIR" ]]; then
  _log "Processing .desktop files (hidden=$PKG_HIDDEN)..."
  while IFS= read -r -d '' df; do
    # Normalise Exec= paths
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

# ── 6. AppRun entry point ─────────────────────────────────────────────────────
# Determine the primary executable for this package.
# Prefer /usr/bin/<pkgname>, then the first executable found in /usr/bin.
PRIMARY_BIN="${APPDIR}/usr/bin/${PKG_NAME}"
if [[ ! -x "$PRIMARY_BIN" ]]; then
  PRIMARY_BIN="$(find "${APPDIR}/usr/bin" -maxdepth 1 -type f -executable 2>/dev/null | head -n1 || true)"
fi
[[ -n "$PRIMARY_BIN" && -x "$PRIMARY_BIN" ]] || {
  # CLI tools may live in /usr/lib or similar; record the name for the host.
  _log "Warning: no executable found in usr/bin for $PKG_NAME — AppRun will be a stub."
  PRIMARY_BIN=""
}

cat > "${APPDIR}/AppRun" <<APPRUN
#!/usr/bin/env bash
# AppRun — generated by package-builder
HERE="\$(dirname "\$(readlink -f "\$0")")"
export PATH="\${HERE}/usr/bin:\${PATH}"
export LD_LIBRARY_PATH="\${HERE}/usr/lib:\${LD_LIBRARY_PATH:-}"
export XDG_DATA_DIRS="\${HERE}/usr/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
APPRUN
if [[ -n "$PRIMARY_BIN" ]]; then
  echo "exec \"\${HERE}/usr/bin/$(basename "$PRIMARY_BIN")\" \"\$@\"" >> "${APPDIR}/AppRun"
else
  echo "echo 'No primary executable found for ${PKG_NAME}' >&2; exit 1" >> "${APPDIR}/AppRun"
fi
chmod +x "${APPDIR}/AppRun"

# Provide a top-level symlink so the executable name is discoverable.
[[ -n "$PRIMARY_BIN" ]] && ln -sf "usr/bin/$(basename "$PRIMARY_BIN")" "${APPDIR}/$(basename "$PRIMARY_BIN")" || true

# ── 7. Locate or download a .desktop and icon for appimagetool ───────────────
# appimagetool requires a .desktop file and an icon at the AppDir root.
ROOT_DESKTOP="$(find "$APPDIR" -maxdepth 1 -name '*.desktop' 2>/dev/null | head -n1 || true)"
if [[ -z "$ROOT_DESKTOP" ]]; then
  # Try to find one inside usr/share/applications
  INNER_DESKTOP="$(find "${APPDIR}/usr/share/applications" -name '*.desktop' 2>/dev/null | head -n1 || true)"
  if [[ -n "$INNER_DESKTOP" ]]; then
    cp "$INNER_DESKTOP" "${APPDIR}/$(basename "$INNER_DESKTOP")"
    ROOT_DESKTOP="${APPDIR}/$(basename "$INNER_DESKTOP")"
  else
    # Generate a minimal stub desktop file
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

# Provide a stub icon if none exists (appimagetool requires one)
ROOT_ICON="$(find "$APPDIR" -maxdepth 1 \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -n1 || true)"
if [[ -z "$ROOT_ICON" ]]; then
  ICON_NAME="$(grep '^Icon=' "$ROOT_DESKTOP" | head -n1 | cut -d= -f2 | xargs)"
  ICON_NAME="${ICON_NAME:-${PKG_NAME}}"
  # Search installed icon themes
  FOUND_ICON="$(find /usr/share/icons /usr/share/pixmaps -name "${ICON_NAME}.png" -o -name "${ICON_NAME}.svg" 2>/dev/null | head -n1 || true)"
  if [[ -n "$FOUND_ICON" ]]; then
    cp "$FOUND_ICON" "${APPDIR}/${ICON_NAME}${FOUND_ICON##*.}"
  else
    # Create a 1x1 transparent PNG as a last resort
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
      > "${APPDIR}/${PKG_NAME}.png"
    _log "Warning: no icon found — using transparent stub."
  fi
fi

# ── 8. Download and run appimagetool ─────────────────────────────────────────
APPIMAGETOOL="/tmp/appimagetool"
if [[ ! -x "$APPIMAGETOOL" ]]; then
  _log "Downloading appimagetool..."
  wget -q -O "$APPIMAGETOOL" \
    "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod +x "$APPIMAGETOOL"
fi

_log "Running appimagetool..."
# ARCH=x86_64 suppresses the architecture detection prompt
ARCH=x86_64 "$APPIMAGETOOL" --no-appstream "$APPDIR" \
  "${ARTIFACT_DIR}/${PKG_NAME}-${VERSION}.app" \
  2>&1 | { [[ "$VERBOSE" == "1" ]] && cat || tail -10; }

_log "Build complete: ${PKG_NAME}-${VERSION}.app"
