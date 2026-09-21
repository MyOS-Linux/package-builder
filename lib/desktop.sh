#!/usr/bin/env bash
# desktop.sh — .desktop file post-processing
#
# Called after the AppImage is assembled, operating on the work directory.
# Globals expected:
#   VERBOSE

# process_desktop_files <app_dir> <pkg_name> <hidden_flag>
#
# <app_dir>     — the AppDir root (contains usr/share/applications/*.desktop)
# <pkg_name>    — package name (used for fallback matching)
# <hidden_flag> — "1" to add NoDisplay=true
process_desktop_files() {
  local app_dir="$1" pkg_name="$2" hidden="${3:-0}"

  local desktop_dir="${app_dir}/usr/share/applications"
  [[ -d "$desktop_dir" ]] || { log_verbose "No .desktop directory in AppDir."; return 0; }

  local found=0
  while IFS= read -r -d '' df; do
    found=$(( found + 1 ))
    log_verbose "Processing desktop file: $df"
    _fix_exec_path "$df" "$app_dir"
    [[ "$hidden" == "1" ]] && _set_no_display "$df" || true
  done < <(find "$desktop_dir" -name '*.desktop' -print0)

  [[ "$found" == "0" ]] && log_verbose "No .desktop files found for $pkg_name."
  return 0
}

# Rewrite Exec= lines so they point to the bundled executable via AppRun.
# AppImage sets $APPDIR at runtime; we use a relative wrapper.
_fix_exec_path() {
  local df="$1" app_dir="$2"
  # Replace absolute paths that point inside the AppDir with just the basename.
  # The AppImage runtime prepends $APPDIR/usr/bin automatically via PATH.
  sed -i 's|^Exec=/usr/bin/|Exec=|' "$df"
  sed -i 's|^Exec=/usr/local/bin/|Exec=|' "$df"
  log_verbose "Exec path normalised in $(basename "$df")"
}

_set_no_display() {
  local df="$1"
  if grep -q '^NoDisplay=' "$df"; then
    sed -i 's/^NoDisplay=.*/NoDisplay=true/' "$df"
  else
    # Insert after the [Desktop Entry] header line
    sed -i '/^\[Desktop Entry\]/a NoDisplay=true' "$df"
  fi
  log_verbose "Set NoDisplay=true in $(basename "$df")"
}
