#!/usr/bin/env bash

# Helpers and constants shared by the sai commands and the sandbox
# wrappers of every tool in tools/.
#
# Design: rather than replacing a native install in place, we keep it
# completely untouched (so its own updater is free to manage it however it
# likes) and instead put our own symlink with the same name in a dedicated
# directory that we prepend to PATH. Because it comes first in PATH, it always
# wins over whatever the native install currently looks like.

SECURE_AI_NAME="secure-ai"
SECURE_AI_HOME_DIR="$HOME/.$SECURE_AI_NAME"
SECURE_AI_SHIM_DIR="$SECURE_AI_HOME_DIR/bin"

SECURE_AI_RC_FILES=(
  "$HOME/.zshrc"
  "$HOME/.bashrc"
  "$HOME/.bash_profile"
  "$HOME/.profile"
)

SECURE_AI_PATH_MARKER_START="# >>> $SECURE_AI_NAME PATH (managed by 'sai install', see 'sai uninstall') >>>"
SECURE_AI_PATH_MARKER_END="# <<< $SECURE_AI_NAME PATH <<<"

require_supported_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin | Linux) ;;
    *)
      log_error "unsupported OS '$os' (only macOS and Linux are supported)"
      return 1
      ;;
  esac
}

# Fills SECURE_AI_TOOLS with the name of every tool in tools/ (the directories
# holding a tool.sh), sorted. Needs REPO_DIR to be set by the caller.
discover_tools() {
  local tool_file tool_dir
  SECURE_AI_TOOLS=()
  for tool_file in "$REPO_DIR"/tools/*/tool.sh; do
    [ -f "$tool_file" ] || continue
    tool_dir="${tool_file%/tool.sh}"
    SECURE_AI_TOOLS+=("${tool_dir##*/}")
  done
}

# Tool names joined by '|', for usage messages.
secure_ai_tools_names() {
  (IFS='|'; echo "${SECURE_AI_TOOLS[*]}")
}

usage_for_tool_command() {
  echo "Usage: sai $1 <$(secure_ai_tools_names)|all>" >&2
}

# Sets SELECTED_TOOLS from a tool name or "all", and EXPLICIT_TOOL to 1 when a
# single tool was named. Returns 1 for anything else; the caller prints usage.
select_tools() {
  local requested="${1:-}" known_tool
  if [ "$requested" = "all" ]; then
    SELECTED_TOOLS=("${SECURE_AI_TOOLS[@]}")
    EXPLICIT_TOOL=0
    return 0
  fi
  for known_tool in "${SECURE_AI_TOOLS[@]}"; do
    if [ "$requested" = "$known_tool" ]; then
      SELECTED_TOOLS=("$requested")
      EXPLICIT_TOOL=1
      return 0
    fi
  done
  return 1
}

# Asks the question $1 on stderr and reads the answer from stdin; returns on
# y/yes, exits 1 on anything else, EOF included.
confirm_or_abort() {
  local answer=""
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r answer || true
  case "$answer" in
    [yY] | [yY][eE][sS]) ;;
    *)
      log_info "Aborted."
      exit 1
      ;;
  esac
}

# Asks whether to $1 (a capitalised verb, e.g. "Install") every available
# tool. On yes sets SELECTED_TOOLS and EXPLICIT_TOOL like select_tools.
confirm_all_tools() {
  confirm_or_abort "$1 all available tools ($(secure_ai_tools_names | sed 's/|/, /g'))?"
  # shellcheck disable=SC2034 # read by the sai commands
  SELECTED_TOOLS=("${SECURE_AI_TOOLS[@]}")
  # shellcheck disable=SC2034 # read by the sai commands
  EXPLICIT_TOOL=0
}

# Runs a command with its output hidden; the output is replayed on stderr only
# if the command fails. Keeps noisy tools such as `docker build` quiet.
run_quietly() {
  local log_file status=0
  log_file="$(mktemp)"
  "$@" >"$log_file" 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    cat "$log_file" >&2
  fi
  rm -f "$log_file"
  return "$status"
}

# Exits with an error unless the docker CLI exists and its daemon answers.
require_docker_running() {
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker not found in PATH. Install Docker first."
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    log_error "the Docker daemon is not running or not reachable. Start Docker and retry."
    exit 1
  fi
}

# Exits with an error unless $1 is a file; $2 describes it (e.g. "Dockerfile").
require_file() {
  [ -f "$1" ] && return 0
  log_error "could not find $2 at $1"
  exit 1
}

# Sets TOOL_DIR and sources tools/<name>/tool.sh, which defines the TOOL_* vars,
# then derives TOOL_SHIM and TOOL_SHIM_ORIGINAL (the paths of its two shims).
# Needs REPO_DIR to be set by the caller.
load_tool_definition() {
  TOOL_DIR="$REPO_DIR/tools/$1"
  # shellcheck source=/dev/null
  source "$TOOL_DIR/tool.sh"
  # shellcheck disable=SC2034 # read by the sai commands
  TOOL_SHIM="$SECURE_AI_SHIM_DIR/$TOOL_BINARY"
  # shellcheck disable=SC2034 # read by the sai commands
  TOOL_SHIM_ORIGINAL="$SECURE_AI_SHIM_DIR/$TOOL_BINARY-original"
}

# True when $1 is a symlink resolving to the loaded tool's wrapper. Uses
# resolve_path from lib/path-utils.sh.
shim_points_to_wrapper() {
  local shim="$1"
  [ -L "$shim" ] && [ "$(resolve_path "$shim")" = "$(resolve_path "$TOOL_WRAPPER")" ]
}

# True when the shim directory is on the current PATH.
shim_dir_on_path() {
  case ":$PATH:" in
    *":$SECURE_AI_SHIM_DIR:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Finds the first executable named $1 on PATH, ignoring any entry that
# resolves to $2. Used to locate the native install while ignoring our own
# shim directory (which may itself already be on PATH).
find_native_binary() {
  local binary_name="$1"
  local exclude_dir="$2"
  local -a path_dirs
  IFS=':' read -r -a path_dirs <<< "$PATH"

  local dir resolved_dir
  for dir in "${path_dirs[@]}"; do
    [ -n "$dir" ] || continue
    resolved_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
    [ "$resolved_dir" = "$exclude_dir" ] && continue
    if [ -f "$dir/$binary_name" ] && [ -x "$dir/$binary_name" ]; then
      printf '%s\n' "$dir/$binary_name"
      return 0
    fi
  done
  return 1
}

path_block_present() {
  local rc_file="$1"
  [ -f "$rc_file" ] && grep -qF "$SECURE_AI_PATH_MARKER_START" "$rc_file"
}

any_rc_has_path_block() {
  local rc_file
  for rc_file in "${SECURE_AI_RC_FILES[@]}"; do
    path_block_present "$rc_file" && return 0
  done
  return 1
}

# Prints the rc files that currently hold the PATH block, one per line.
rc_files_with_path_block() {
  local rc_file
  for rc_file in "${SECURE_AI_RC_FILES[@]}"; do
    path_block_present "$rc_file" && echo "$rc_file"
  done
  return 0
}

add_path_block_to_rc_file() {
  local rc_file="$1"
  {
    echo ""
    echo "$SECURE_AI_PATH_MARKER_START"
    # shellcheck disable=SC2016 # '$PATH' must stay literal, expanded on shell startup, not now
    printf 'export PATH="%s:$PATH"\n' "$SECURE_AI_SHIM_DIR"
    echo "$SECURE_AI_PATH_MARKER_END"
  } >> "$rc_file"
}

remove_path_block_from_rc_file() {
  local rc_file="$1"
  local tmp_file
  tmp_file="$(mktemp "${rc_file}.$SECURE_AI_NAME.XXXXXX")"
  # add_path_block_to_rc_file writes a blank line before the block: hold blank
  # lines back so the one right before the block goes with it.
  awk -v start="$SECURE_AI_PATH_MARKER_START" -v end="$SECURE_AI_PATH_MARKER_END" '
    function flush_held_blank() { if (held_blank) { print ""; held_blank = 0 } }
    $0 == start { held_blank = 0; skip = 1; next }
    $0 == end { skip = 0; next }
    skip { next }
    $0 == "" { flush_held_blank(); held_blank = 1; next }
    { flush_held_blank(); print }
    END { flush_held_blank() }
  ' "$rc_file" > "$tmp_file"
  # Overwrite in place rather than mv: keeps the rc file's permissions and
  # leaves it a symlink if it is managed by a dotfiles tool.
  cat "$tmp_file" > "$rc_file"
  rm -f "$tmp_file"
}

# Adds the PATH block to every existing candidate rc file, or, if none of
# them exist yet, creates the one matching $SHELL. No-op if the block is
# already present anywhere (idempotent).
configure_shell_path() {
  if any_rc_has_path_block; then
    log_info "PATH entry already present in shell startup files."
    return 0
  fi

  local rc_file touched=0
  for rc_file in "${SECURE_AI_RC_FILES[@]}"; do
    [ -f "$rc_file" ] || continue
    add_path_block_to_rc_file "$rc_file"
    log_step "Added PATH entry to: $rc_file"
    touched=1
  done

  if [ "$touched" -eq 0 ]; then
    local default_rc
    case "$(basename "${SHELL:-}")" in
      zsh) default_rc="$HOME/.zshrc" ;;
      bash) default_rc="$HOME/.bash_profile" ;;
      *) default_rc="$HOME/.profile" ;;
    esac
    add_path_block_to_rc_file "$default_rc"
    log_success "Created and updated: $default_rc"
  fi
}

# Removes the PATH block from every rc file that has it. No-op if absent.
deconfigure_shell_path() {
  local rc_file found=0
  for rc_file in "${SECURE_AI_RC_FILES[@]}"; do
    if path_block_present "$rc_file"; then
      remove_path_block_from_rc_file "$rc_file"
      log_removed "Removed PATH entry from: $rc_file"
      found=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    log_info "No PATH entry found in shell startup files."
  fi
}
