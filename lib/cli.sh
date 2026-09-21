#!/usr/bin/env bash
# cli.sh — argument parsing, help text, and fzf interactive selection

usage() {
  cat <<'EOF'
Usage: package-builder [OPTIONS] [PACKAGE|all]

Build Arch packages into MyOS .app bundles.

Arguments:
  PACKAGE       Build the named package (modes from packages.txt).
  all           Build every package in packages.txt.
  (none)        Interactive mode — select packages with fzf.

Options:
  --dry-run     Show what would be done without building.
  --force       Rebuild even if the artifact already exists.
  --verbose     Show detailed build output.
  --help        Show this help and exit.

Environment:
  PACKAGE_LIST        Path to packages.txt  (default: ./packages.txt)
  CONTAINER_RUNTIME   docker or podman      (default: docker)
  ARCH_IMAGE          Arch base image       (default: archlinux:latest)
EOF
}

# parse_args "$@"
# Sets globals: DRY_RUN, FORCE, VERBOSE, TARGET_PKG
# shellcheck disable=SC2034  # consumed by builder.sh and main script
parse_args() {
  DRY_RUN=0; FORCE=0; VERBOSE=0; TARGET_PKG=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --force)   FORCE=1   ;;
      --verbose) VERBOSE=1 ;;
      --help)    usage; exit 0 ;;
      --*)       log_error "Unknown option: $1"; usage >&2; exit 1 ;;
      *)
        if [[ -z "$TARGET_PKG" ]]; then
          TARGET_PKG="$1"
        else
          log_error "Unexpected argument: $1"; usage >&2; exit 1
        fi
        ;;
    esac
    shift
  done
}

# fzf_select_packages — returns newline-separated list of selected package names
# Reads from PKG_ORDER (populated by parser.sh).
fzf_select_packages() {
  command -v fzf &>/dev/null || { log_error "'fzf' is required for interactive mode."; return 1; }

  local selected
  selected="$(printf '%s\n' "${PKG_ORDER[@]}" \
    | fzf --multi --prompt='Select packages (TAB to multi-select): ' \
          --header='package-builder — choose packages to build')" || {
    log_info "No packages selected."
    return 1
  }
  echo "$selected"
}
