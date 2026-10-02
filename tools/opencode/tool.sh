#!/usr/bin/env bash

# Per-tool definitions for opencode, sourced after lib/log.sh, lib/common.sh
# and lib/components.sh by the sai commands and opencode.sh, with TOOL_DIR set
# to this directory.

# shellcheck disable=SC2034 # read by the sai commands and opencode.sh
TOOL_BINARY="opencode"
# shellcheck disable=SC2034 # read by the sai commands and opencode.sh
TOOL_WRAPPER="$TOOL_DIR/opencode.sh"
TOOL_DOCKERFILE="$TOOL_DIR/container/Dockerfile.opencode"
TOOL_BUILD_CONTEXT="$TOOL_DIR/container"
TOOL_STATE_DIR="$SECURE_AI_HOME_DIR/opencode"

SECURE_OPENCODE_IMAGE_NAME="opencode-sandbox"
# shellcheck disable=SC2034 # read by the sai commands and opencode.sh
TOOL_IMAGE_REF="$SECURE_OPENCODE_IMAGE_NAME:current"

# The sandbox's own opencode directories: separate from any native opencode,
# shared by every sandbox instance.
# shellcheck disable=SC2034 # read by the sai commands and opencode.sh
SECURE_OPENCODE_CONFIG_DIR="$TOOL_STATE_DIR/config"
# shellcheck disable=SC2034 # read by the sai commands and opencode.sh
SECURE_OPENCODE_DATA_DIR="$TOOL_STATE_DIR/data"
# shellcheck disable=SC2034 # read by the sai commands and opencode.sh
SECURE_OPENCODE_STATE_DIR="$TOOL_STATE_DIR/state"
# shellcheck disable=SC2034 # read by the sai commands and opencode.sh
SECURE_OPENCODE_CACHE_DIR="$TOOL_STATE_DIR/cache"

# The sandbox builds opencode itself from the official source, straight from
# upstream, at the latest stable release of this major version line, whatever
# opencode is installed on the host.
OPENCODE_UPSTREAM_REPO="https://github.com/anomalyco/opencode.git"
OPENCODE_MAJOR="2"
OPENCODE_VERSION_LABEL="org.opencode-sandbox.version"

# Prints the stable vX.Y.Z tags (no pre-release/CI suffix) of the major version
# lines given as arguments, one per line, e.g. `stable_opencode_tags 2 3`. One
# network round trip serves every line, because opencode.sh pays it on every
# launch. Prints nothing (and returns success) if the tag list cannot be
# fetched (offline). Callers rely on the empty-output contract to decide on
# fallbacks; a non-zero return here would abort them under set -e before those
# fallbacks run.
# Bounded with a low-speed timeout so a dead network fails fast instead of
# hanging opencode.sh on every launch.
stable_opencode_tags() {
  local major
  local -a tag_patterns=()
  for major in "$@"; do
    tag_patterns+=("refs/tags/v${major}.*")
  done
  # `|| true` on purpose: an empty result (git failing offline, or no tag
  # matching) fails the pipeline (git exits 128 offline, grep exits 1 on no
  # match), which would surface through the caller's command substitution and
  # trip set -e.
  GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=10 \
    git ls-remote --tags "$OPENCODE_UPSTREAM_REPO" "${tag_patterns[@]}" 2>/dev/null \
    | awk -F'/' '{print $NF}' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    || true
}

# Prints the highest tag of major version $1 among the tags $2 (one per line,
# as stable_opencode_tags prints them), nothing if there is none.
#
# sort -t . -k 2,2n -k 3,3n is the POSIX-portable equivalent of GNU's
# `sort -V` for tag-shaped input: the tags are exactly vMAJOR.MINOR.PATCH, so
# the minor and patch fields sort numerically (lexical order would pick v2.0.9
# over v2.0.15). macOS's BSD sort lacks -V, so it cannot be used.
highest_opencode_tag_of_major() {
  local major="$1" tags="$2"
  printf '%s\n' "$tags" \
    | grep -E "^v${major}\.[0-9]+\.[0-9]+\$" \
    | sort -t . -k 2,2n -k 3,3n \
    | tail -1 \
    || true
}

# Warns (does not build) if the tags $2 hold a stable tag of the major version
# line after $1: e.g. with OPENCODE_MAJOR=2, a published v3.x.y means a new
# major is available upstream that this wrapper won't pick up on its own.
warn_if_newer_major_opencode_available() {
  local current_major="$1" tags="$2"
  local newer
  newer="$(highest_opencode_tag_of_major "$((current_major + 1))" "$tags")"
  [ -n "$newer" ] && log_notice "opencode $newer is available upstream. This wrapper only builds v$current_major.x automatically; bump OPENCODE_MAJOR in tools/opencode/tool.sh to move to it."
  return 0
}

# opencode-sandbox:current's org.opencode-sandbox.version label, i.e. which
# upstream tag the currently-installed image was built from. Empty if the
# image doesn't exist yet.
installed_sandbox_image_version() {
  docker image inspect --format "{{ index .Config.Labels \"$OPENCODE_VERSION_LABEL\" }}" "$SECURE_OPENCODE_IMAGE_NAME:current" 2>/dev/null
}

docker_host_arch() {
  case "$(uname -m)" in
    arm64 | aarch64) echo "arm64" ;;
    x86_64 | amd64) echo "x64" ;;
    *) echo "" ;;
  esac
}

# Builds opencode-sandbox compiled from source at the given upstream tag
# (Dockerfile.opencode's builder stage clones and compiles it; see there).
# Tags the result both :$tag and, only on success, repoints :current to it.
build_sandbox_image_for_tag() {
  local dockerfile="$1"
  local build_context="$2"
  local tag="$3"
  local arch
  arch="$(docker_host_arch)"
  if [ -z "$arch" ]; then
    log_error "unsupported host architecture '$(uname -m)' for building opencode from source."
    return 1
  fi

  component_build_args
  log_build "Building opencode $tag from source (github.com/anomalyco/opencode) -- this can take a few minutes..."
  if ! run_quietly docker build \
    "${COMPONENT_BUILD_ARGS[@]}" \
    --build-arg "OPENCODE_TAG=$tag" \
    --build-arg "OPENCODE_TARGET=linux-$arch" \
    --label "$OPENCODE_VERSION_LABEL=$tag" \
    -t "$SECURE_OPENCODE_IMAGE_NAME:$tag" \
    -f "$dockerfile" "$build_context"; then
    return 1
  fi
  docker tag "$SECURE_OPENCODE_IMAGE_NAME:$tag" "$SECURE_OPENCODE_IMAGE_NAME:current"
  log_success "Built opencode $tag"
}

# Used by opencode.sh on every launch: builds the latest stable opencode v2
# release only if it isn't already what :current was last built from. On
# build failure, falls back to whatever :current already points at (a prior
# successful build) with a warning; only errors out if there is no previous
# build to fall back to (or Docker itself isn't available).
ensure_sandbox_image_current() {
  local dockerfile="$1"
  local build_context="$2"

  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is required to run the sandboxed opencode."
    return 1
  fi

  local current
  current="$(installed_sandbox_image_version)"

  local upstream_tags latest
  upstream_tags="$(stable_opencode_tags "$OPENCODE_MAJOR" "$((OPENCODE_MAJOR + 1))")"
  latest="$(highest_opencode_tag_of_major "$OPENCODE_MAJOR" "$upstream_tags")"
  if [ -z "$latest" ]; then
    log_warn "could not resolve the latest stable opencode v$OPENCODE_MAJOR release from $OPENCODE_UPSTREAM_REPO (offline?)."
    if [ -n "$current" ]; then
      log_info "Continuing with cached build: opencode $current"
      return 0
    fi
    log_error "no previously built opencode-sandbox image is available either. Nothing to run."
    return 1
  fi

  warn_if_newer_major_opencode_available "$OPENCODE_MAJOR" "$upstream_tags"

  if [ "$current" = "$latest" ]; then
    return 0
  fi

  if build_sandbox_image_for_tag "$dockerfile" "$build_context" "$latest"; then
    return 0
  fi

  log_warn "build of opencode $latest failed; falling back to the last successful local build."
  if [ -n "$current" ]; then
    log_info "Continuing with cached build: opencode $current"
    return 0
  fi

  log_error "no previously built opencode-sandbox image is available either. Nothing to run."
  return 1
}

# Used by 'sai install' and 'sai config': always builds the latest stable
# release from scratch, so a Dockerfile or components edit made since the last
# build is picked up even when the upstream version hasn't changed
# (ensure_sandbox_image_current would skip the build in that case). No-op if
# Docker isn't installed; 'sai install' already warns about that separately.
force_rebuild_sandbox_image() {
  local dockerfile="$1"
  local build_context="$2"

  command -v docker >/dev/null 2>&1 || return 0

  local upstream_tags latest
  upstream_tags="$(stable_opencode_tags "$OPENCODE_MAJOR" "$((OPENCODE_MAJOR + 1))")"
  latest="$(highest_opencode_tag_of_major "$OPENCODE_MAJOR" "$upstream_tags")"
  if [ -z "$latest" ]; then
    log_error "could not resolve the latest stable opencode v$OPENCODE_MAJOR release from $OPENCODE_UPSTREAM_REPO."
    return 1
  fi
  warn_if_newer_major_opencode_available "$OPENCODE_MAJOR" "$upstream_tags"

  build_sandbox_image_for_tag "$dockerfile" "$build_context" "$latest"
}

# Used by 'sai install' and 'sai config': see force_rebuild_sandbox_image.
tool_rebuild_image() {
  force_rebuild_sandbox_image "$TOOL_DOCKERFILE" "$TOOL_BUILD_CONTEXT"
}
