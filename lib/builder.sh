#!/usr/bin/env bash
# builder.sh — orchestrate a single package/mode build
#
# Globals expected (set by main script):
#   BUILD_WORK_DIR, BUILD_ARTIFACTS_DIR, BUILD_LOGS_DIR
#   DRY_RUN, FORCE, VERBOSE
#   CONTAINER_RUNTIME, ARCH_IMAGE

# build_package <pkg_name> <mode> <flags_space_separated> <multi_mode>
build_package() {
  local pkg="$1" mode="$2" flags="${3:-}" multi_mode="${4:-0}"
  local hidden=0
  [[ " $flags " == *" hidden "* ]] && hidden=1

  log_step "Build: $pkg  mode=$mode  flags=${flags:-(none)}"

  # ── Dry-run short-circuit (before any container calls) ───────────────────────
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] Would build $pkg ($mode) — skipping version resolution and build"
    return 0
  fi

  # ── Resolve version from inside a temporary container ──────────────────────
  local version
  version="$(_resolve_version "$pkg")" || return 1
  log_info "Resolved version: $version"

  # ── Cache check ─────────────────────────────────────────────────────────────
  if [[ "${FORCE:-0}" != "1" ]] && artifact_exists "$pkg" "$version" "$mode" "$multi_mode"; then
    log_ok "Already built: ${pkg}-${version}${multi_mode:+"-$mode"}.app  (use --force to rebuild)"
    return 0
  fi

  # ── Prepare work directory ───────────────────────────────────────────────────
  local work_dir="${BUILD_WORK_DIR}/${pkg}-${mode}-$$"
  mkdir -p "${work_dir}/artifact"

  # ── Open log ─────────────────────────────────────────────────────────────────
  init_log "$pkg" "$version" "$mode"

  # ── Run container build ──────────────────────────────────────────────────────
  local exit_code=0
  run_build_container "$pkg" "$version" "$mode" "$work_dir" \
    -e "PKG_HIDDEN=$hidden" \
    || exit_code=$?

  if (( exit_code != 0 )); then
    log_error "Build failed for $pkg ($mode). Exit code: $exit_code"
    rm -rf "$work_dir"
    return "$exit_code"
  fi

  # ── Collect artifact ─────────────────────────────────────────────────────────
  collect_artifact "$work_dir" "$pkg" "$version" "$mode" "$multi_mode" || {
    rm -rf "$work_dir"
    return 1
  }

  # ── Cleanup work dir ─────────────────────────────────────────────────────────
  rm -rf "$work_dir"
  log_ok "Done: $pkg ($mode)"
}

# _resolve_version <pkg_name>
# Queries pacman inside a minimal container to get the current package version.
_resolve_version() {
  local pkg="$1"
  local version
  version="$("$CONTAINER_RUNTIME" run --rm "$ARCH_IMAGE" \
    bash -c "pacman -Sy --noconfirm &>/dev/null && pacman -Si '$pkg' 2>/dev/null | awk '/^Version/{print \$3; exit}'")" || {
    log_error "Failed to resolve version for '$pkg'. Is it a valid Arch package?"
    return 1
  }
  # Strip epoch prefix (e.g. "2:143.0.1-1" → "143.0.1-1") and pkgrel suffix
  version="${version#*:}"       # remove epoch
  version="${version%-*}"       # remove pkgrel
  [[ -n "$version" ]] || { log_error "Empty version for '$pkg'."; return 1; }
  echo "$version"
}
