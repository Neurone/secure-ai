#!/usr/bin/env bash

# 'sai uninstall': reverts the changes made by 'sai install' for the given
# tool(s): removes the shims from ~/.secure-ai/bin and, once no shim
# is left, the PATH entry from the shell startup files. 'sai install' never touches
# native installs, so there is nothing to undo there.

# Removes the shims of one tool. Returns 1 when its wrapper isn't installed.
uninstall_tool() {
  local tool_name="$1"
  load_tool_definition "$tool_name"

  local shim="$TOOL_SHIM"
  local shim_original="$TOOL_SHIM_ORIGINAL"

  shim_points_to_wrapper "$shim" || return 1

  rm -f "$shim"
  log_removed "Removed: $shim"

  if [ -e "$shim_original" ] || [ -L "$shim_original" ]; then
    rm -f "$shim_original"
    log_removed "Removed: $shim_original"
  fi

  if [ -d "$TOOL_STATE_DIR" ]; then
    log_kept "Kept: $TOOL_STATE_DIR (the sandbox's $tool_name settings, login and data; delete it manually if you don't need it)"
  fi
}

remove_dir_if_empty() {
  local dir="$1"
  if [ -d "$dir" ] && [ -z "$(ls -A "$dir")" ]; then
    rmdir "$dir"
    log_removed "Removed empty directory: $dir"
  fi
}

# Usage: sai uninstall [<tool|all>]
# Without an argument, asks for confirmation to uninstall every tool.
cmd_uninstall() {
  if [ "$#" -eq 0 ]; then
    confirm_all_tools Uninstall
  else
    select_tools "$1" || { usage_for_tool_command uninstall; exit 1; }
  fi

  require_supported_os

  local uninstalled_count=0 tool_name
  for tool_name in "${SELECTED_TOOLS[@]}"; do
    if uninstall_tool "$tool_name"; then
      uninstalled_count=$((uninstalled_count + 1))
    elif [ "$EXPLICIT_TOOL" -eq 1 ]; then
      log_warn "$SECURE_AI_SHIM_DIR does not hold the $SECURE_AI_NAME wrapper for $tool_name."
      log_info "Nothing to uninstall."
      exit 1
    fi
  done

  if [ "$uninstalled_count" -eq 0 ]; then
    log_warn "no $SECURE_AI_NAME wrapper is installed in $SECURE_AI_SHIM_DIR."
    log_info "Nothing to uninstall."
    exit 1
  fi

  remove_dir_if_empty "$SECURE_AI_SHIM_DIR"
  remove_dir_if_empty "$SECURE_AI_HOME_DIR"

  if [ ! -d "$SECURE_AI_SHIM_DIR" ]; then
    log_removed "Removing PATH entry..."
    deconfigure_shell_path
  fi

  echo >&2
  log_success "Uninstall complete. Native installs are never modified. Start a new shell (or re-source your shell startup files) for the original commands to resolve again."
}
