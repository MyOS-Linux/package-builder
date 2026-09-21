#!/usr/bin/env bash
# logging.sh — console and file logging helpers

# Colours (disabled when not a terminal)
if [[ -t 1 ]]; then
  _C_RESET='\033[0m'; _C_RED='\033[0;31m'; _C_YELLOW='\033[0;33m'
  _C_GREEN='\033[0;32m'; _C_CYAN='\033[0;36m'; _C_BOLD='\033[1m'
else
  _C_RESET=''; _C_RED=''; _C_YELLOW=''; _C_GREEN=''; _C_CYAN=''; _C_BOLD=''
fi

# Current log file (set by builder.sh before each build)
CURRENT_LOG_FILE=''

_log_to_file() {
  [[ -n "$CURRENT_LOG_FILE" ]] && echo "$*" >> "$CURRENT_LOG_FILE" || true
}

log_info()    { echo -e "${_C_CYAN}[INFO]${_C_RESET}  $*";  _log_to_file "[INFO]  $*"; }
log_ok()      { echo -e "${_C_GREEN}[ OK ]${_C_RESET}  $*"; _log_to_file "[ OK ]  $*"; }
log_warn()    { echo -e "${_C_YELLOW}[WARN]${_C_RESET}  $*" >&2; _log_to_file "[WARN]  $*"; }
log_error()   { echo -e "${_C_RED}[ERR ]${_C_RESET}  $*" >&2; _log_to_file "[ERR ]  $*"; }
log_verbose() { [[ "${VERBOSE:-0}" == "1" ]] && { echo -e "        $*"; _log_to_file "        $*"; } || true; }
log_step()    { echo -e "${_C_BOLD}[STEP]${_C_RESET}  $*"; _log_to_file "[STEP]  $*"; }

# Open a new log file for a build
init_log() {
  local pkg="$1" version="$2" mode="$3"
  CURRENT_LOG_FILE="${BUILD_LOGS_DIR}/${pkg}-${version}-${mode}.log"
  mkdir -p "$BUILD_LOGS_DIR"
  {
    echo "package-builder build log"
    echo "package : $pkg"
    echo "version : $version"
    echo "mode    : $mode"
    echo "date    : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "image   : ${ARCH_IMAGE:-archlinux:latest}"
    echo "---"
  } > "$CURRENT_LOG_FILE"
}
