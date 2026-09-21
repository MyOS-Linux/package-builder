#!/usr/bin/env bash
# tests/test_builder.sh — integration tests using a mock container runtime.
# No real Docker/Podman or network access required.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/parser.sh"
source "${SCRIPT_DIR}/lib/appimage.sh"
source "${SCRIPT_DIR}/lib/desktop.sh"

PASS=0; FAIL=0
_tmp_dir="$(mktemp -d)"
trap 'rm -rf "$_tmp_dir"' EXIT

# Override build dirs to temp space
BUILD_ARTIFACTS_DIR="${_tmp_dir}/artifacts"
BUILD_LOGS_DIR="${_tmp_dir}/logs"
BUILD_WORK_DIR="${_tmp_dir}/work"
mkdir -p "$BUILD_ARTIFACTS_DIR" "$BUILD_LOGS_DIR" "$BUILD_WORK_DIR"
export BUILD_ARTIFACTS_DIR BUILD_LOGS_DIR BUILD_WORK_DIR

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"; PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc  expected='$expected'  actual='$actual'"; FAIL=$(( FAIL + 1 ))
  fi
}
assert_true() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then
    echo "  PASS: $desc"; PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc"; FAIL=$(( FAIL + 1 ))
  fi
}
assert_false() {
  local desc="$1"; shift
  if ! "$@" 2>/dev/null; then
    echo "  PASS: $desc"; PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc (expected false)"; FAIL=$(( FAIL + 1 ))
  fi
}

# ── Test 1: artifact_exists returns false when nothing built ─────────────────
echo "--- Test 1: cache miss"
assert_false "no artifact yet (single mode)" artifact_exists "firefox" "143.0.1" "fat" "0"
assert_false "no artifact yet (multi mode)"  artifact_exists "mc"      "4.8.31"  "fat" "1"

# ── Test 2: collect_artifact places file correctly (single mode) ─────────────
echo "--- Test 2: collect_artifact — single mode"
work="${_tmp_dir}/work/firefox-fat-$$"
mkdir -p "${work}/artifact"
touch "${work}/artifact/firefox-143.0.1.AppImage"
CURRENT_LOG_FILE="/dev/null"
collect_artifact "$work" "firefox" "143.0.1" "fat" "0"
assert_true "artifact exists after collect (single)" \
  test -f "${BUILD_ARTIFACTS_DIR}/firefox-143.0.1.app"

# ── Test 3: collect_artifact — multi mode naming ─────────────────────────────
echo "--- Test 3: collect_artifact — multi mode"
work="${_tmp_dir}/work/mc-fat-$$"
mkdir -p "${work}/artifact"
touch "${work}/artifact/mc-4.8.31.AppImage"
collect_artifact "$work" "mc" "4.8.31" "fat" "1"
assert_true "artifact exists after collect (multi-fat)" \
  test -f "${BUILD_ARTIFACTS_DIR}/mc-4.8.31-fat.app"

# ── Test 4: artifact_exists returns true after collect ───────────────────────
echo "--- Test 4: cache hit after collect"
assert_true "cache hit (single)" artifact_exists "firefox" "143.0.1" "fat" "0"
assert_true "cache hit (multi)"  artifact_exists "mc"      "4.8.31"  "fat" "1"

# ── Test 5: collect_artifact fails when no artifact file present ─────────────
echo "--- Test 5: collect_artifact — missing artifact"
work="${_tmp_dir}/work/empty-$$"
mkdir -p "${work}/artifact"
rc=0
collect_artifact "$work" "ghost" "1.0" "thin" "0" 2>/dev/null || rc=$?
if [[ "$rc" != "0" ]]; then
  echo "  PASS: correctly failed on missing artifact"; PASS=$(( PASS + 1 ))
else
  echo "  FAIL: should have failed on missing artifact"; FAIL=$(( FAIL + 1 ))
fi

# ── Test 6: desktop — NoDisplay=true added when hidden ───────────────────────
echo "--- Test 6: desktop hidden flag"
app_dir="${_tmp_dir}/AppDir-hidden"
mkdir -p "${app_dir}/usr/share/applications"
cat > "${app_dir}/usr/share/applications/nnn.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=nnn
Exec=/usr/bin/nnn
Icon=nnn
EOF
CURRENT_LOG_FILE="/dev/null"
process_desktop_files "$app_dir" "nnn" "1"
assert_true "NoDisplay=true present" grep -q 'NoDisplay=true' "${app_dir}/usr/share/applications/nnn.desktop"

# ── Test 7: desktop — NoDisplay not added when not hidden ────────────────────
echo "--- Test 7: desktop not hidden"
app_dir="${_tmp_dir}/AppDir-visible"
mkdir -p "${app_dir}/usr/share/applications"
cat > "${app_dir}/usr/share/applications/firefox.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Firefox
Exec=/usr/bin/firefox
Icon=firefox
EOF
process_desktop_files "$app_dir" "firefox" "0"
assert_false "NoDisplay absent" grep -q 'NoDisplay=true' "${app_dir}/usr/share/applications/firefox.desktop"

# ── Test 8: desktop — Exec path normalised ───────────────────────────────────
echo "--- Test 8: desktop Exec normalisation"
assert_true "Exec normalised" grep -q '^Exec=firefox' "${app_dir}/usr/share/applications/firefox.desktop"

# ── Test 9: desktop — existing NoDisplay=false overwritten ───────────────────
echo "--- Test 9: desktop NoDisplay overwrite"
app_dir="${_tmp_dir}/AppDir-overwrite"
mkdir -p "${app_dir}/usr/share/applications"
cat > "${app_dir}/usr/share/applications/mc.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=mc
Exec=mc
Icon=mc
NoDisplay=false
EOF
process_desktop_files "$app_dir" "mc" "1"
assert_true  "NoDisplay overwritten to true" grep -q  '^NoDisplay=true'  "${app_dir}/usr/share/applications/mc.desktop"
assert_false "old NoDisplay=false gone"      grep -q  '^NoDisplay=false' "${app_dir}/usr/share/applications/mc.desktop"

# ── Test 10: dry-run — build_package with DRY_RUN=1 prints intent, no build ──
# We run in a child bash so we can stub _resolve_version after sourcing builder.sh
# by patching it via a wrapper script written to a temp file.
echo "--- Test 10: dry-run mode"
dry_run_script="${_tmp_dir}/dry_run_test.sh"
cat > "$dry_run_script" <<SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
export BUILD_ARTIFACTS_DIR="${BUILD_ARTIFACTS_DIR}"
export BUILD_LOGS_DIR="${BUILD_LOGS_DIR}"
export BUILD_WORK_DIR="${BUILD_WORK_DIR}"
export CONTAINER_RUNTIME=docker
export ARCH_IMAGE=archlinux:latest
export DRY_RUN=1 FORCE=0 VERBOSE=0
export CURRENT_LOG_FILE=/dev/null
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/appimage.sh"
source "${SCRIPT_DIR}/lib/desktop.sh"
source "${SCRIPT_DIR}/lib/container.sh"
source "${SCRIPT_DIR}/lib/builder.sh"
# Override after sourcing so our stub wins
_resolve_version() { echo "143.0.1"; }
build_package firefox fat "" 0
SCRIPT
dry_output="$(bash "$dry_run_script" 2>&1)" || true
if echo "$dry_output" | grep -qi 'dry.run'; then
  echo "  PASS: dry-run output mentions dry-run"; PASS=$(( PASS + 1 ))
else
  echo "  FAIL: dry-run output missing 'dry-run' — got: $dry_output"; FAIL=$(( FAIL + 1 ))
fi

# ── Test 11: 'all' — every package in list is parsed ─────────────────────────
echo "--- Test 11: 'all' target parses all packages"
pkg_file="${_tmp_dir}/all.txt"
printf 'firefox fat\nnnn thin hidden\nmc fat thin\n' > "$pkg_file"
all_count="$(bash -c "
  source '${SCRIPT_DIR}/lib/logging.sh'
  source '${SCRIPT_DIR}/lib/parser.sh'
  parse_package_list '$pkg_file' 2>/dev/null
  echo \${#PKG_ORDER[@]}
")"
assert_eq "all: 3 packages" "3" "$all_count"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" == "0" ]]
