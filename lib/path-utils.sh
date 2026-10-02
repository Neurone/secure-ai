#!/usr/bin/env bash

# Prints the absolute path of $1 with every symlink in its chain resolved, like
# `readlink -f` (which not every macOS version has). Fails if $1 doesn't exist.
resolve_path() {
  local target="$1"

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    log_error "path does not exist: $target"
    return 1
  fi

  while [ -L "$target" ]; do
    local link_target
    link_target="$(readlink "$target")"
    if [[ "$link_target" = /* ]]; then
      target="$link_target"
    else
      target="$(dirname "$target")/$link_target"
    fi
  done

  local target_dir
  target_dir="$(cd "$(dirname "$target")" && pwd -P)"
  printf '%s/%s\n' "$target_dir" "$(basename "$target")"
}