#!/usr/bin/env bash
set -euo pipefail

# Runs opencode inside a Docker sandbox, isolated from any native install.
#
# opencode's four directories (config, data, state, cache) live in host
# directories that only this sandbox uses (~/.secure-ai/opencode/),
# bind-mounted whole, read/write, at opencode's usual paths inside the
# container. They are shared by every sandbox instance, like the single set of
# directories a native opencode uses, and stay editable from the host. Nothing
# of a native opencode (~/.config/opencode, ~/.local/share/opencode, ...) is
# read, mounted or modified, and no host credentials are forwarded as
# environment variables (see the docker run block below).

# Resolve this script's real location, following symlinks: once 'sai install'
# runs, 'opencode' is a symlink to this file, so BASH_SOURCE[0] alone would
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

# ---------------------------------------------------------------------------
# opencode itself is built from the official upstream source at the latest
# stable release (see ensure_sandbox_image_current in tool.sh): it builds only
# when a newer stable release is out, and falls back to the last successful
# local build if that build fails.
# ---------------------------------------------------------------------------
if ! ensure_sandbox_image_current "$TOOL_DOCKERFILE" "$TOOL_BUILD_CONTEXT"; then
  exit 1
fi

prepare_sandbox_run

# Created here so Docker does not create the mount sources itself, as root.
mkdir -p "$SECURE_OPENCODE_CONFIG_DIR" "$SECURE_OPENCODE_DATA_DIR" \
         "$SECURE_OPENCODE_STATE_DIR" "$SECURE_OPENCODE_CACHE_DIR"

# The host port a local model provider (e.g. LM Studio) listens on. Note
# this does not by itself restrict the container to only this port:
# host.docker.internal is reachable on Docker Desktop (macOS/Windows)
# regardless of any flag or network, so a sandboxed process could still
# reach any other host port directly. This only sets the value handed to
# opencode for the one provider it's meant to reach (see below).
SECURE_OPENCODE_LMSTUDIO_PORT="${SECURE_OPENCODE_LMSTUDIO_PORT:-1234}"

# opencode resolves its directories under HOME (/home/node, set in the docker
# run below), so each sandbox directory is mounted at the usual opencode path.
# What each holds:
#   config: opencode.json(c), cli.json (theme, keybinds, plugin list), the
#     background-service config, agents/, commands/, plugins/, skills/, ...
#   data: the session database (in v2 it also holds the provider
#     credentials), logs, repos.
#   state: UI state (selected model, prompt history) and file locks.
#   cache: npm-installed plugins.
MOUNT_ARGS+=(
  -v "$SECURE_OPENCODE_CONFIG_DIR:/home/node/.config/opencode$MOUNT_SUFFIX"
  -v "$SECURE_OPENCODE_DATA_DIR:/home/node/.local/share/opencode$MOUNT_SUFFIX"
  -v "$SECURE_OPENCODE_STATE_DIR:/home/node/.local/state/opencode$MOUNT_SUFFIX"
  -v "$SECURE_OPENCODE_CACHE_DIR:/home/node/.cache/opencode$MOUNT_SUFFIX"
)

# No credentials (env vars or files) are forwarded into the container by
# this wrapper: use a provider that needs none (LM Studio, Ollama, ...), or
# run 'opencode auth login' inside the container itself.
#
# host.docker.internal lets a provider configured against a local server on
# the host (e.g. LM Studio, Ollama) stay reachable from inside the
# container. On Linux this requires --add-host explicitly; on Docker Desktop
# (macOS/Windows) it resolves regardless of this flag, and so does every
# other port on the host — there is no way to scope it down to a single
# port from inside this wrapper (see README.md for what was tried).
# OPENCODE_LMSTUDIO_BASEURL is set so the same opencode.json works both
# natively and sandboxed: reference it as
# '"baseURL": "{env:OPENCODE_LMSTUDIO_BASEURL}"'. For native use nothing is
# needed when your LM Studio listens on the default endpoint -- an unset
# variable substitutes to an empty string, which opencode treats as no
# override, so the provider falls back to its built-in
# http://127.0.0.1:1234/v1 default; export the variable only if it listens
# elsewhere (see README.md).
docker run \
  "${COMMON_RUN_ARGS[@]}" \
  "${MOUNT_ARGS[@]}" \
  --add-host=host.docker.internal:host-gateway \
  -e OPENCODE_LMSTUDIO_BASEURL="http://host.docker.internal:$SECURE_OPENCODE_LMSTUDIO_PORT/v1" \
  "$TOOL_IMAGE_REF" \
  "$@"
