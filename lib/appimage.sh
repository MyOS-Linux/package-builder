#!/usr/bin/env bash
# appimage.sh — host-side helpers for AppImage artifact management
#
# The actual AppImage is built INSIDE the container by build-package.sh.
# This module handles:
#   - locating the finished artifact in the work directory
#   - renaming it to the MyOS naming convention
#   - copying it to build/artifacts/

# collect_artifact <work_dir> <pkg_name> <version> <mode> <multi_mode>
#
# <multi_mode> — "1" if more than one mode is being built for this package
#               (triggers the -fat / -thin suffix)
collect_artifact() {
  local work_dir="$1" pkg="$2" version="$3" mode="$4" multi_mode="${5:-0}"

  local artifact_src
  artifact_src="$(find "${work_dir}/artifact" -name '*.app' -o -name '*.AppImage' 2>/dev/null | head -n1)"

  if [[ -z "$artifact_src" ]]; then
    log_error "No artifact found in ${work_dir}/artifact/ for $pkg ($mode)."
    return 1
  fi

  # Determine final name
  local final_name
  if [[ "$multi_mode" == "1" ]]; then
    final_name="${pkg}-${version}-${mode}.app"
  else
    final_name="${pkg}-${version}.app"
  fi

  local dest="${BUILD_ARTIFACTS_DIR}/${final_name}"
  mkdir -p "$BUILD_ARTIFACTS_DIR"
  cp "$artifact_src" "$dest"
  log_ok "Artifact: $dest"
}

# artifact_exists <pkg_name> <version> <mode> <multi_mode>
# Returns 0 if the artifact is already present (cache hit).
artifact_exists() {
  local pkg="$1" version="$2" mode="$3" multi_mode="${4:-0}"
  local final_name
  if [[ "$multi_mode" == "1" ]]; then
    final_name="${pkg}-${version}-${mode}.app"
  else
    final_name="${pkg}-${version}.app"
  fi
  [[ -f "${BUILD_ARTIFACTS_DIR}/${final_name}" ]]
}
