#!/usr/bin/env bash
set -euo pipefail

# Runs Claude Code inside a Docker sandbox, isolated from any native install:
# nothing of the native ~/.claude, ~/.claude.json, keychain login or binary is
# read, mounted or modified.

# Resolve this script's real location, following symlinks: once 'sai install'
# runs, 'claude' is a symlink to this file, so BASH_SOURCE[0] alone would
# point at the symlink's directory instead of this tool's directory.
# lib/path-utils.sh (which has a general resolve_path helper) cannot be
# sourced yet, since its own path is derived from here, hence this inline loop.
SELF_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SELF_SOURCE" ]; do
  SELF_SOURCE_DIR="$(cd -P "$(dirname "$SELF_SOURCE")" && pwd)"
  SELF_SOURCE="$(readlink "$SELF_SOURCE")"
  [[ "$SELF_SOURCE" = /* ]] || SELF_SOURCE="$SELF_SOURCE_DIR/$SELF_SOURCE"
done
TOOL_DIR="$(cd "$(dirname "$SELF_SOURCE")" && pwd -P)"
LIB_DIR="$TOOL_DIR/../../lib"

# Loaded first so every later failure can be reported with log_error; if
# log.sh itself is missing, bash reports it and set -e stops here.
# shellcheck source=/dev/null
source "$LIB_DIR/log.sh"

for required_file in "$LIB_DIR/common.sh" "$LIB_DIR/components.sh" "$LIB_DIR/runtime.sh" "$TOOL_DIR/tool.sh"; do
  if [ ! -f "$required_file" ]; then
    log_error "could not find required file at $required_file"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$required_file"
done

require_file "$TOOL_DOCKERFILE" "Dockerfile"
require_docker_running

# The image only needs building once: claude itself lives on a persistent
# volume and updates itself there, so a new release never requires a rebuild.
if ! docker image inspect "$TOOL_IMAGE_REF" >/dev/null 2>&1; then
  build_sandbox_image
fi

prepare_sandbox_run

# Named volume (not a host bind mount) holding the native claude install.
# It persists across --rm containers, so an update claude applies to itself
# carries forward from run to run instead of resetting to the version baked
# into the image every time.
MOUNT_ARGS+=(-v "$SECURE_CLAUDE_LOCAL_VOLUME:/home/node/.local")

# Everything Claude Code keeps (settings, login, ~/.claude.json, sessions,
# agents, ...) lives in one host directory that only this sandbox uses, never
# the native ~/.claude. It is mounted at the same absolute path as on the host
# and handed to claude through CLAUDE_CONFIG_DIR, so absolute paths written
# into it (e.g. by host tools editing settings.json) resolve on both sides.
# A whole-directory mount keeps renames inside it working (Claude saves via
# temp-file-then-rename, which fails with EBUSY onto a single-file mount) and
# keeps its lock files shared by every concurrent container.
mkdir -p "$SECURE_CLAUDE_CONFIG_DIR"
MOUNT_ARGS+=(-v "$SECURE_CLAUDE_CONFIG_DIR:$SECURE_CLAUDE_CONFIG_DIR$MOUNT_SUFFIX")

# Container-only overrides, injected as an extra settings layer via --settings
# so nothing is written to the config directory.
CONTAINER_SETTINGS='{"companyAnnouncements":["🐳  DOCKER SANDBOX — this is the containerized Claude Code, not the native install"]}'

docker run \
  "${COMMON_RUN_ARGS[@]}" \
  "${MOUNT_ARGS[@]}" \
  -e CLAUDE_CONFIG_DIR="$SECURE_CLAUDE_CONFIG_DIR" \
  -e ANTHROPIC_API_KEY \
  -e ANTHROPIC_MODEL \
  "$TOOL_IMAGE_REF" \
  --settings "$CONTAINER_SETTINGS" \
  "$@"
