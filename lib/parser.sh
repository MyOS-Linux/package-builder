#!/usr/bin/env bash
# parser.sh — parse and validate packages.txt
#
# Each non-blank, non-comment line has the form:
#   <package-name> <mode> [mode...] [flags...]
#
# Valid modes : fat  thin
# Valid flags : hidden
#
# After sourcing this file, call:
#   parse_package_list <file>
#
# Results are stored in associative arrays:
#   PKG_MODES[<name>]  — space-separated list of modes
#   PKG_FLAGS[<name>]  — space-separated list of flags (may be empty)
#   PKG_ORDER          — indexed array preserving declaration order

declare -gA PKG_MODES=()
declare -gA PKG_FLAGS=()
declare -ga PKG_ORDER=()

readonly _VALID_MODES="fat thin"
readonly _VALID_FLAGS="hidden"

parse_package_list() {
  local file="$1"
  [[ -f "$file" ]] || { log_error "Package list not found: $file"; return 1; }

  PKG_MODES=(); PKG_FLAGS=(); PKG_ORDER=()

  local lineno=0 errors=0
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    lineno=$(( lineno + 1 ))
    # Strip inline comments, leading/trailing whitespace
    local line
    line="$(echo "$raw_line" | sed 's/#.*//' | xargs)"
    [[ -z "$line" ]] && continue

    read -ra tokens <<< "$line"
    local name="${tokens[0]}"
    local rest=("${tokens[@]:1}")

    if [[ ${#rest[@]} -eq 0 ]]; then
      log_error "Line $lineno: '$name' has no mode specified."
      (( errors++ )); continue
    fi

    # Detect duplicate package definitions
    if [[ -v PKG_MODES["$name"] ]]; then
      log_error "Line $lineno: duplicate package definition '$name'."
      (( errors++ )); continue
    fi

    local modes=() flags=() token_errors=0
    for tok in "${rest[@]}"; do
      if _is_valid_mode "$tok"; then
        # Detect duplicate modes on the same line
        if _array_contains "$tok" "${modes[@]+"${modes[@]}"}"; then
          log_error "Line $lineno: duplicate mode '$tok' for package '$name'."
          (( token_errors++ ))
        else
          modes+=("$tok")
        fi
      elif _is_valid_flag "$tok"; then
        if _array_contains "$tok" "${flags[@]+"${flags[@]}"}"; then
          log_warn "Line $lineno: duplicate flag '$tok' for package '$name' (ignored)."
        else
          flags+=("$tok")
        fi
      else
        log_error "Line $lineno: unknown token '$tok' for package '$name'."
        (( token_errors++ ))
      fi
    done

    [[ "$token_errors" -gt 0 ]] && { errors=$(( errors + 1 )); continue; }
    [[ ${#modes[@]} -eq 0 ]] && { log_error "Line $lineno: '$name' has no valid mode."; errors=$(( errors + 1 )); continue; }

    PKG_MODES["$name"]="${modes[*]}"
    # shellcheck disable=SC2034  # consumed by package-builder main script
    PKG_FLAGS["$name"]="${flags[*]:-}"
    PKG_ORDER+=("$name")
  done < "$file"

  [[ "$errors" -eq 0 ]] || { log_error "$errors error(s) in $file — aborting."; return 1; }
  [[ ${#PKG_ORDER[@]} -gt 0 ]] || { log_error "No packages defined in $file."; return 1; }
  return 0
}

_is_valid_mode() { [[ " $_VALID_MODES " == *" $1 "* ]]; }
_is_valid_flag() { [[ " $_VALID_FLAGS " == *" $1 "* ]]; }

_array_contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}
