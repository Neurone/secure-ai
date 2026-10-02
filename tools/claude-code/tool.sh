#!/usr/bin/env bash

# Per-tool definitions for Claude Code, sourced after lib/log.sh,
# lib/common.sh and lib/components.sh by the sai commands and claude.sh, with
# TOOL_DIR set to this directory.

# shellcheck disable=SC2034 # read by the sai commands and claude.sh
TOOL_BINARY="claude"
# shellcheck disable=SC2034 # read by the sai commands and claude.sh
TOOL_WRAPPER="$TOOL_DIR/claude.sh"
TOOL_DOCKERFILE="$TOOL_DIR/container/Dockerfile.claude-code"
TOOL_BUILD_CONTEXT="$TOOL_DIR/container"
TOOL_STATE_DIR="$SECURE_AI_HOME_DIR/claude-code"

SECURE_CLAUDE_IMAGE_NAME="claude-code-sandbox"
# shellcheck disable=SC2034 # read by the sai commands and claude.sh
TOOL_IMAGE_REF="$SECURE_CLAUDE_IMAGE_NAME"
# shellcheck disable=SC2034 # read by the sai commands and claude.sh
SECURE_CLAUDE_LOCAL_VOLUME="secure-claude-code-local"

# The sandbox's own Claude Code config dir (settings, login, ~/.claude.json,
# sessions, ...), separate from any native ~/.claude and shared by every
# sandbox instance.
# shellcheck disable=SC2034 # read by the sai commands and claude.sh
SECURE_CLAUDE_CONFIG_DIR="$TOOL_STATE_DIR/config"

# Builds the sandbox image, showing the docker output only if the build fails.
build_sandbox_image() {
  component_build_args
  log_build "Building $SECURE_CLAUDE_IMAGE_NAME..."
  run_quietly docker build "${COMPONENT_BUILD_ARGS[@]}" -t "$SECURE_CLAUDE_IMAGE_NAME" -f "$TOOL_DOCKERFILE" "$TOOL_BUILD_CONTEXT" || return 1
  log_success "Built $SECURE_CLAUDE_IMAGE_NAME"
}

# Rebuilds the sandbox image unconditionally, so a Dockerfile or components
# edit made since the last build is picked up ('sai install' and 'sai config'
# call this). claude.sh, by contrast, only builds the image when it doesn't
# exist at all, so this is the supported way to apply such a change. No-op if
# Docker isn't installed; 'sai install' already warns about that separately.
tool_rebuild_image() {
  command -v docker >/dev/null 2>&1 || return 0
  build_sandbox_image
}
