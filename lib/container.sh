#!/usr/bin/env bash
# container.sh — create, run, and destroy build containers
#
# Globals expected:
#   CONTAINER_RUNTIME  (docker|podman, default: docker)
#   ARCH_IMAGE         (default: archlinux:latest)
#   BUILD_WORK_DIR     (host-side work directory)
#   VERBOSE

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
ARCH_IMAGE="${ARCH_IMAGE:-archlinux:latest}"

# Active container name for the current build (set by run_build_container)
_ACTIVE_CONTAINER=''

# Register a trap so we never leave a container running on unexpected exit.
# Call this once from the main script.
register_container_cleanup() {
  trap '_cleanup_container' EXIT INT TERM
}

_cleanup_container() {
  if [[ -n "$_ACTIVE_CONTAINER" ]]; then
    log_verbose "Removing container $_ACTIVE_CONTAINER"
    "$CONTAINER_RUNTIME" rm -f "$_ACTIVE_CONTAINER" &>/dev/null || true
    _ACTIVE_CONTAINER=''
  fi
}

# check_runtime — verify the container runtime is available
check_runtime() {
  command -v "$CONTAINER_RUNTIME" &>/dev/null || {
    log_error "Container runtime '$CONTAINER_RUNTIME' not found in PATH."
    return 1
  }
  # Quick sanity: can we talk to the daemon?
  if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    docker info &>/dev/null || { log_error "Docker daemon is not running."; return 1; }
  fi
}

# run_build_container <pkg> <version> <mode> <work_dir> <script_args...>
#
# <version> is passed through to the container via PKG_NAME/PKG_MODE env vars
# and recorded in the log; the container itself re-derives it from pacman.
# shellcheck disable=SC2034  # version used in log context
run_build_container() {
  local pkg="$1" version="$2" mode="$3" work_dir="$4"
  shift 4
  local extra_args=("$@")

  local cname="package-builder-${pkg}-${mode}-$$"
  _ACTIVE_CONTAINER="$cname"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../container" && pwd)"

  log_step "Starting container for $pkg ($mode)"
  log_verbose "Runtime : $CONTAINER_RUNTIME"
  log_verbose "Image   : $ARCH_IMAGE"
  log_verbose "Work dir: $work_dir"

  local run_flags=(
    --name "$cname"
    --rm                          # auto-remove on exit
    -v "${script_dir}:/builder:ro,z"
    -v "${work_dir}:/work:z"
    -e "PKG_NAME=$pkg"
    -e "PKG_MODE=$mode"
    -e "VERBOSE=${VERBOSE:-0}"
    "${extra_args[@]+"${extra_args[@]}"}"
    "$ARCH_IMAGE"
    bash /builder/build-package.sh
  )

  local exit_code=0
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    "$CONTAINER_RUNTIME" run "${run_flags[@]}" 2>&1 | tee -a "${CURRENT_LOG_FILE:-/dev/null}" || exit_code=$?
  else
    "$CONTAINER_RUNTIME" run "${run_flags[@]}" >> "${CURRENT_LOG_FILE:-/dev/null}" 2>&1 || exit_code=$?
  fi

  _ACTIVE_CONTAINER=''   # container removed by --rm

  if (( exit_code != 0 )); then
    log_error "Container exited with status $exit_code for $pkg ($mode)."
    log_error "See log: $CURRENT_LOG_FILE"
    return "$exit_code"
  fi
}
