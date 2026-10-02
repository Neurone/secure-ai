#!/usr/bin/env bash

# 'sai install': installs the Docker sandbox wrappers so that each tool's
# command (claude, opencode, ...) resolves to its wrapper.
#
# A native install of a tool is optional and, if present, left completely
# untouched, so its own updater keeps working exactly as before. Instead, this
# creates a dedicated directory (~/.secure-ai/bin) containing, per
# installed tool:
#   - <tool>          -> the Docker sandbox wrapper
#   - <tool>-original -> the native binary, only if one is found on PATH
# and prepends that directory to PATH via the shell startup files, so the
# tool's name always resolves to the sandbox wrapper first.
#
# 'sai uninstall' undoes this.

# Installs the shims and image of one tool.
install_tool() {
  local tool_name="$1"
  load_tool_definition "$tool_name"

  local shim="$TOOL_SHIM"
  local shim_original="$TOOL_SHIM_ORIGINAL"

  require_file "$TOOL_WRAPPER" "wrapper script"
  chmod +x "$TOOL_WRAPPER"
  require_file "$TOOL_DOCKERFILE" "Dockerfile"

  local shim_dir_real native_path=""
  shim_dir_real="$SECURE_AI_SHIM_DIR"
  if [ -d "$SECURE_AI_SHIM_DIR" ]; then
    shim_dir_real="$(cd "$SECURE_AI_SHIM_DIR" && pwd -P)"
  fi

  # A native install is optional: the sandboxed tool never uses it. When one
  # is found it is linked as '<tool>-original' purely as a convenience escape
  # hatch to the unsandboxed binary.
  native_path="$(find_native_binary "$TOOL_BINARY" "$shim_dir_real")" || native_path=""

  # Already fully installed: report and exit without touching anything.
  if shim_points_to_wrapper "$shim" \
     && { [ -z "$native_path" ] || [ -L "$shim_original" ]; } \
     && any_rc_has_path_block; then
    log_info "Already installed:"
    log_info "$shim -> $TOOL_WRAPPER"
    if [ -L "$shim_original" ]; then
      log_info "$shim_original -> $(readlink "$shim_original")"
    else
      log_info "No native '$TOOL_BINARY' on PATH; $shim_original was not created (not needed by the sandboxed '$TOOL_BINARY')."
    fi
    log_info "PATH entry already present in shell startup files."
    # A rebuild failure here (e.g. offline) must not fail the re-run as long as
    # an existing image keeps working. Without one (e.g. the first build
    # failed) there is nothing to fall back to, so it is a hard failure, like
    # a fresh install below.
    if ! tool_rebuild_image; then
      if command -v docker >/dev/null 2>&1 && ! docker image inspect "$TOOL_IMAGE_REF" >/dev/null 2>&1; then
        log_error "could not build the sandbox image and no previous image exists."
        exit 1
      fi
      log_warn "could not rebuild the sandbox image now; keeping the current one."
    fi
    return 0
  fi

  # Don't clobber anything at these two paths that we don't manage ourselves.
  local managed_path
  for managed_path in "$shim" "$shim_original"; do
    if [ -e "$managed_path" ] && [ ! -L "$managed_path" ]; then
      log_error "$managed_path exists and is not a symlink managed by this installer. Inspect and remove it manually before re-running 'sai install'."
      exit 1
    fi
  done

  if ! mkdir -p "$SECURE_AI_SHIM_DIR" 2>/dev/null; then
    log_error "could not create $SECURE_AI_SHIM_DIR. Check permissions on $HOME."
    exit 1
  fi

  if [ -n "$native_path" ]; then
    log_found "Found native $TOOL_BINARY at: $native_path"
    ln -sf "$native_path" "$shim_original"
    log_step "Linked: $shim_original -> $native_path"
  else
    log_info "No native '$TOOL_BINARY' command found in PATH (outside of $SECURE_AI_SHIM_DIR); skipping $shim_original."
    log_info "The sandboxed '$TOOL_BINARY' does not need it."
  fi

  ln -sf "$TOOL_WRAPPER" "$shim"
  log_step "Linked: $shim -> $TOOL_WRAPPER"

  if ! shim_points_to_wrapper "$shim"; then
    log_error "verification failed, '$shim' does not resolve to $TOOL_WRAPPER after linking."
    exit 1
  fi

  log_step "Configuring PATH..."
  configure_shell_path

  tool_rebuild_image

  echo >&2
  log_success "Installed '$TOOL_BINARY' (sandboxed, runs in Docker): $shim -> $TOOL_WRAPPER"
  if [ -n "$native_path" ]; then
    log_info "The native $TOOL_BINARY at $native_path is untouched; '$TOOL_BINARY-original' runs it."
  fi
}

# Prints the line to paste in the current shell so the sandboxed commands
# resolve right away. hash -r is needed in both cases: bash and zsh cache
# command locations, so a previously resolved native command would keep
# winning.
print_current_shell_hint() {
  if shim_dir_on_path; then
    echo "  hash -r"
  else
    # shellcheck disable=SC2016 # '$PATH' must stay literal, expanded when the line is pasted
    printf '  export PATH="%s:$PATH"; hash -r\n' "$SECURE_AI_SHIM_DIR"
  fi
}

# Usage: sai install [<tool|all>]
# Without an argument, asks for confirmation to install every tool.
cmd_install() {
  if [ "$#" -eq 0 ]; then
    confirm_all_tools Install
  else
    select_tools "$1" || { usage_for_tool_command install; exit 1; }
  fi

  require_supported_os

  if command -v docker >/dev/null 2>&1; then
    require_docker_running
  else
    log_warn "docker not found in PATH. The sandboxed commands require Docker to run; install it before using them."
  fi

  local tool_name
  for tool_name in "${SELECTED_TOOLS[@]}"; do
    log_section "$tool_name"
    install_tool "$tool_name"
  done

  echo >&2
  log_notice "New shells pick up the sandboxed commands automatically. To use them in this shell right away, run:"
  echo >&2
  print_current_shell_hint >&2
  echo >&2
  log_info "Run '$REPO_DIR/sai uninstall [<$(secure_ai_tools_names)|all>]' at any time to undo this."
}
