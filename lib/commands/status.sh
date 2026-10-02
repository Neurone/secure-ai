#!/usr/bin/env bash

# 'sai status': read-only report of what 'sai install' set up for each tool,
# plus the shell PATH setup they share. It never modifies anything.

print_shim_status() {
  local shim="$1"
  if [ ! -e "$shim" ] && [ ! -L "$shim" ]; then
    echo "  shim:      not installed"
  elif shim_points_to_wrapper "$shim"; then
    echo "  shim:      installed ($shim -> $TOOL_WRAPPER)"
  elif [ -L "$shim" ]; then
    echo "  shim:      stale ($shim -> $(readlink "$shim"), expected $TOOL_WRAPPER)"
  else
    echo "  shim:      conflict ($shim exists and is not a symlink managed by sai)"
  fi
}

print_original_status() {
  local shim_original="$1"
  if [ ! -L "$shim_original" ]; then
    echo "  original:  none"
  elif [ -e "$shim_original" ]; then
    echo "  original:  $shim_original -> $(readlink "$shim_original")"
  else
    echo "  original:  broken ($shim_original -> $(readlink "$shim_original"), target missing)"
  fi
}

print_image_status() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "  image:     $TOOL_IMAGE_REF: docker not found"
  elif docker image inspect "$TOOL_IMAGE_REF" >/dev/null 2>&1; then
    echo "  image:     $TOOL_IMAGE_REF: present"
  else
    echo "  image:     $TOOL_IMAGE_REF: not built"
  fi
}

print_state_dir_status() {
  if [ -d "$TOOL_STATE_DIR" ]; then
    echo "  state:     $TOOL_STATE_DIR (exists)"
  else
    echo "  state:     $TOOL_STATE_DIR (absent)"
  fi
}

print_tool_status() {
  local tool_name="$1"
  load_tool_definition "$tool_name"
  echo "$tool_name"
  print_shim_status "$TOOL_SHIM"
  print_original_status "$TOOL_SHIM_ORIGINAL"
  print_image_status
  print_state_dir_status
}

print_shell_status() {
  local rc_files_with_block
  rc_files_with_block="$(rc_files_with_path_block | paste -sd ',' - | sed 's/,/, /g')"
  echo "shell"
  echo "  PATH entry in startup files: ${rc_files_with_block:-none}"
  if shim_dir_on_path; then
    echo "  Shim dir on current PATH:    yes"
  else
    echo "  Shim dir on current PATH:    no"
  fi
}

# Usage: sai status [<tool|all>]
cmd_status() {
  select_tools "${1:-all}" || { usage_for_tool_command status; exit 1; }

  require_supported_os

  local tool_name
  for tool_name in "${SELECTED_TOOLS[@]}"; do
    print_tool_status "$tool_name"
  done
  print_shell_status
}
