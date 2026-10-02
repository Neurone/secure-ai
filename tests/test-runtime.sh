#!/usr/bin/env bash
# Tests for the shared wrapper building blocks of lib/runtime.sh that are
# easier to check directly than through a wrapper run.
#
# Usage: bash tests/test-runtime.sh

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=../lib/log.sh
source "$REPO_DIR/lib/log.sh"
# shellcheck source=../lib/runtime.sh
source "$REPO_DIR/lib/runtime.sh"

# run_gitconfig_mount <name> <gitconfig content or empty for no file>
# Runs append_filtered_gitconfig_mount for a fresh home; the mounted copy ends
# up in GITCONFIG_COPY, the home's own file in GITCONFIG_ORIGINAL.
run_gitconfig_mount() {
  local scenario_dir="$T/runtime-$1"
  mkdir -p "$scenario_dir/home" "$scenario_dir/run"
  GITCONFIG_ORIGINAL="$scenario_dir/home/.gitconfig"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$GITCONFIG_ORIGINAL"; fi
  GITCONFIG_COPY="$scenario_dir/run/gitconfig"
  # shellcheck disable=SC2034 # read by append_filtered_gitconfig_mount
  TMPDIR_RUN="$scenario_dir/run"
  MOUNT_ARGS=()
  HOME="$scenario_dir/home" append_filtered_gitconfig_mount
}

echo "=== G1: every credential section is dropped, identity and aliases are kept ==="
run_gitconfig_mount g1 '[user]
	name = Test User
[credential]
	helper = osxkeychain
[credential "https://github.com"]
	helper = !gh auth git-credential
[credential "https://gist.github.com"]
	username = someone
[alias]
	st = status'
has_no_pattern "$GITCONFIG_COPY" 'credential' "no credential section left"
has_no_pattern "$GITCONFIG_COPY" 'helper' "no helper left"
has_pattern "$GITCONFIG_COPY" 'name = Test User' "identity kept"
has_pattern "$GITCONFIG_COPY" 'st = status' "aliases kept"
has_pattern "$GITCONFIG_ORIGINAL" 'osxkeychain' "the host file is untouched"
content_is <(printf '%s\n' "${MOUNT_ARGS[@]}") "-v
$GITCONFIG_COPY:/home/node/.gitconfig:ro" "the copy is mounted read-only"

echo "=== G2: a config without credential sections is copied as it is ==="
run_gitconfig_mount g2 '[user]
	name = Test User'
content_is "$GITCONFIG_COPY" "$(cat "$GITCONFIG_ORIGINAL")" "copy equals the original"

echo "=== G3: no ~/.gitconfig -> nothing mounted ==="
run_gitconfig_mount g3 ""
path_absent "$GITCONFIG_COPY" "no copy made"
content_is <(echo "${#MOUNT_ARGS[@]}") "0" "no mount argument"

finish_tests
