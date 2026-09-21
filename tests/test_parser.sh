#!/usr/bin/env bash
# tests/test_parser.sh — unit tests for lib/parser.sh
# No container, no network, no real packages required.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/parser.sh"

PASS=0; FAIL=0
_tmp_dir="$(mktemp -d)"
trap 'rm -rf "$_tmp_dir"' EXIT

_pkg_file() { echo "${_tmp_dir}/$1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc"
    echo "        expected: '$expected'"
    echo "        actual  : '$actual'"
    FAIL=$(( FAIL + 1 ))
  fi
}

# Note: parse_package_list sets global arrays, so we call it directly
# (not in a subshell) and capture its exit code manually.
_parse_ok() {
  local desc="$1" file="$2"
  local rc=0
  parse_package_list "$file" 2>/dev/null || rc=$?
  if [[ "$rc" == "0" ]]; then
    echo "  PASS: $desc"; PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc (expected success, got rc=$rc)"; FAIL=$(( FAIL + 1 ))
  fi
}

_parse_fail() {
  local desc="$1" file="$2"
  local rc=0
  parse_package_list "$file" 2>/dev/null || rc=$?
  if [[ "$rc" != "0" ]]; then
    echo "  PASS: $desc"; PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc (expected failure)"; FAIL=$(( FAIL + 1 ))
  fi
}

# ── Test 1: comments and blank lines are ignored ──────────────────────────────
echo "--- Test 1: comments and blank lines"
f="$(_pkg_file t1.txt)"
cat > "$f" <<'EOF'
# this is a comment
   
firefox fat
# another comment
EOF
_parse_ok "parse succeeds" "$f"
assert_eq "one package" "1" "${#PKG_ORDER[@]}"
assert_eq "package name" "firefox" "${PKG_ORDER[0]}"

# ── Test 2: single mode ───────────────────────────────────────────────────────
echo "--- Test 2: single mode"
f="$(_pkg_file t2.txt)"
echo "kwrite thin" > "$f"
_parse_ok "parse succeeds" "$f"
assert_eq "mode" "thin" "${PKG_MODES[kwrite]}"
assert_eq "no flags" "" "${PKG_FLAGS[kwrite]}"

# ── Test 3: multiple modes ────────────────────────────────────────────────────
echo "--- Test 3: multiple modes"
f="$(_pkg_file t3.txt)"
echo "mc fat thin" > "$f"
_parse_ok "parse succeeds" "$f"
assert_eq "modes" "fat thin" "${PKG_MODES[mc]}"

# ── Test 4: hidden flag ───────────────────────────────────────────────────────
echo "--- Test 4: hidden flag"
f="$(_pkg_file t4.txt)"
echo "nnn thin hidden" > "$f"
_parse_ok "parse succeeds" "$f"
assert_eq "mode" "thin" "${PKG_MODES[nnn]}"
assert_eq "flag" "hidden" "${PKG_FLAGS[nnn]}"

# ── Test 5: malformed — no mode ───────────────────────────────────────────────
echo "--- Test 5: malformed — no mode"
f="$(_pkg_file t5.txt)"
echo "badpkg" > "$f"
_parse_fail "parse fails on no-mode line" "$f"

# ── Test 6: unknown mode ──────────────────────────────────────────────────────
echo "--- Test 6: unknown mode"
f="$(_pkg_file t6.txt)"
echo "badpkg supermode" > "$f"
_parse_fail "parse fails on unknown mode" "$f"

# ── Test 7: unknown flag ──────────────────────────────────────────────────────
echo "--- Test 7: unknown flag"
f="$(_pkg_file t7.txt)"
echo "firefox fat weirdFlag" > "$f"
_parse_fail "parse fails on unknown flag" "$f"

# ── Test 8: duplicate package definition ─────────────────────────────────────
echo "--- Test 8: duplicate package"
f="$(_pkg_file t8.txt)"
printf 'firefox fat\nfirefox thin\n' > "$f"
_parse_fail "parse fails on duplicate package" "$f"

# ── Test 9: duplicate mode on same line ──────────────────────────────────────
echo "--- Test 9: duplicate mode on same line"
f="$(_pkg_file t9.txt)"
echo "firefox fat fat" > "$f"
_parse_fail "parse fails on duplicate mode" "$f"

# ── Test 10: empty file ───────────────────────────────────────────────────────
echo "--- Test 10: empty file"
f="$(_pkg_file t10.txt)"
: > "$f"
_parse_fail "parse fails on empty file" "$f"

# ── Test 11: missing file ─────────────────────────────────────────────────────
echo "--- Test 11: missing file"
_parse_fail "parse fails on missing file" "/nonexistent/packages.txt"

# ── Test 12: PKG_ORDER preserves declaration order ───────────────────────────
echo "--- Test 12: declaration order preserved"
f="$(_pkg_file t12.txt)"
printf 'firefox fat\nnnn thin\nmc fat thin\n' > "$f"
_parse_ok "parse succeeds" "$f"
assert_eq "order[0]" "firefox" "${PKG_ORDER[0]}"
assert_eq "order[1]" "nnn"     "${PKG_ORDER[1]}"
assert_eq "order[2]" "mc"      "${PKG_ORDER[2]}"

# ── Test 13: inline comment stripped ─────────────────────────────────────────
echo "--- Test 13: inline comment stripped"
f="$(_pkg_file t13.txt)"
echo "firefox fat  # build the browser" > "$f"
_parse_ok "parse succeeds" "$f"
assert_eq "mode" "fat" "${PKG_MODES[firefox]}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" == "0" ]]
