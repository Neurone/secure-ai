#!/usr/bin/env bash
# Tests for 'sai install' and 'sai uninstall', driven with the fake tools
# of lib/harness.sh.
#
# Usage: bash tests/test-install.sh

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

shim_dir_of() { printf '%s\n' "$1/.secure-ai/bin"; }
PATH_BLOCK="# >>> secure-ai PATH (managed by 'sai install', see 'sai uninstall') >>>"

echo "=== I1: install claude-code without a native claude ==="
REC="$T/record/i1"
HOME_I1="$T/home-i1"
run_install "$REC" "$HOME_I1" "" claude-code
rc=$?
exit_code_is "$rc" 0 "install succeeds"
link_points_to "$(shim_dir_of "$HOME_I1")/claude" "$REPO_DIR/tools/claude-code/claude.sh" "claude shim points at the wrapper"
path_absent "$(shim_dir_of "$HOME_I1")/claude-original" "no claude-original shim"
path_absent "$(shim_dir_of "$HOME_I1")/opencode" "no opencode shim"
has_pattern "$HOME_I1/.zshrc" 'secure-ai PATH' "PATH block added to .zshrc"
has_pattern "$REC/build.args" 'claude-code-sandbox' "claude image built"

echo "=== I1b: the closing hint reloads the PATH when the shim dir is not on it ==="
# shellcheck disable=SC2016 # '$PATH' must stay literal
has_line "$T/record/i1/stderr.txt" "  export PATH=\"$(shim_dir_of "$HOME_I1"):\$PATH\"; hash -r" "hint exports the shim dir and clears the command cache"

echo "=== I1c: the closing hint only clears the command cache when the shim dir is already on PATH ==="
REC="$T/record/i1c"
HOME_I1C="$T/home-i1c"
run_install "$REC" "$HOME_I1C" "$(shim_dir_of "$HOME_I1C")" claude-code
rc=$?
exit_code_is "$rc" 0 "install succeeds"
has_line "$REC/stderr.txt" "  hash -r" "hint clears the command cache"
has_no_pattern "$REC/stderr.txt" 'export PATH=' "hint does not export PATH again"

echo "=== I2: install claude-code with a native claude ==="
REC="$T/record/i2"
HOME_I2="$T/home-i2"
rm -f "$NATIVE_CALLS"
run_install "$REC" "$HOME_I2" "$T/native" claude-code
rc=$?
exit_code_is "$rc" 0 "install succeeds"
link_points_to "$(shim_dir_of "$HOME_I2")/claude-original" "$T/native/claude" "claude-original points at the native claude"
path_exists "$(shim_dir_of "$HOME_I2")/claude" "claude shim present"
path_absent "$NATIVE_CALLS" "the native claude is never executed"

echo "=== I3: re-running install is idempotent ==="
REC="$T/record/i3"
run_install "$REC" "$HOME_I1" "" claude-code
rc=$?
exit_code_is "$rc" 0 "re-install succeeds"
has_pattern "$REC/stderr.txt" 'Already installed' "reports already installed"
occurs_once "$HOME_I1/.zshrc" "$PATH_BLOCK" "PATH block not duplicated"

echo "=== I4: re-run while the image build fails -> warning, not failure ==="
REC="$T/record/i4"
FAKE_BUILD_FAIL=1 run_install "$REC" "$HOME_I1" "" claude-code
rc=$?
exit_code_is "$rc" 0 "re-install still succeeds"
has_pattern "$REC/stderr.txt" 'Warning' "build failure demoted to a warning"

echo "=== I5: a fresh install fails when the image build fails ==="
REC="$T/record/i5"
FAKE_BUILD_FAIL=1 run_install "$REC" "$T/home-i5" "" claude-code
rc=$?
exit_code_is "$rc" 1 "install fails"

echo "=== I6: install opencode with a native opencode ==="
REC="$T/record/i6"
HOME_I6="$T/home-i6"
FAKE_TAGS_V2="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 FAKE_IMAGE_STATE=absent \
  run_install "$REC" "$HOME_I6" "$T/native" opencode
rc=$?
exit_code_is "$rc" 0 "install succeeds"
link_points_to "$(shim_dir_of "$HOME_I6")/opencode" "$REPO_DIR/tools/opencode/opencode.sh" "opencode shim points at the wrapper"
link_points_to "$(shim_dir_of "$HOME_I6")/opencode-original" "$T/native/opencode" "opencode-original points at the native opencode"
has_line "$REC/build.args" "OPENCODE_TAG=v2.0.14" "image built from the latest stable tag"
path_absent "$(shim_dir_of "$HOME_I6")/claude" "no claude shim"

echo "=== I7: install opencode without a native opencode ==="
REC="$T/record/i7"
HOME_I7="$T/home-i7"
FAKE_TAGS_V2="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 FAKE_IMAGE_STATE=absent \
  run_install "$REC" "$HOME_I7" "" opencode
rc=$?
exit_code_is "$rc" 0 "install succeeds"
path_absent "$(shim_dir_of "$HOME_I7")/opencode-original" "opencode-original NOT created"
has_pattern "$REC/stderr.txt" "No native 'opencode'" "says no native opencode was found"
has_line "$REC/build.args" "OPENCODE_TAG=v2.0.14" "image built without a native opencode"

echo "=== I8: re-run opencode install while offline (already installed) ==="
REC="$T/record/i8"
FAKE_TAGS_V2='' FAKE_GIT_FAIL=1 run_install "$REC" "$HOME_I7" "" opencode
rc=$?
exit_code_is "$rc" 0 "re-install succeeds"
has_pattern "$REC/stderr.txt" 'Already installed' "reports already installed"
has_pattern "$REC/stderr.txt" 'Warning' "rebuild failure demoted to a warning"

echo "=== I8b: re-run opencode install when the build fails and no image exists ==="
REC="$T/record/i8b"
FAKE_BUILD_FAIL=1 FAKE_IMAGE_STATE=absent run_install "$REC" "$HOME_I7" "" opencode
rc=$?
exit_code_is "$rc" 1 "re-install fails"
has_pattern "$REC/stderr.txt" 'no previous image exists' "says there is no image to fall back to"

echo "=== I9: fresh opencode install while offline ==="
REC="$T/record/i9"
FAKE_TAGS_V2='' FAKE_GIT_FAIL=1 FAKE_IMAGE_STATE=absent run_install "$REC" "$T/home-i9" "" opencode
rc=$?
exit_code_is "$rc" 1 "install fails"
has_pattern "$REC/stderr.txt" 'could not resolve the latest stable' "clear error, not a silent death"

echo "=== I10: install all ==="
REC="$T/record/i10"
HOME_I10="$T/home-i10"
FAKE_TAGS_V2="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 FAKE_IMAGE_STATE=absent \
  run_install "$REC" "$HOME_I10" "$T/native" all
rc=$?
exit_code_is "$rc" 0 "install succeeds"
path_exists "$(shim_dir_of "$HOME_I10")/claude" "claude shim"
path_exists "$(shim_dir_of "$HOME_I10")/opencode" "opencode shim"
path_exists "$(shim_dir_of "$HOME_I10")/claude-original" "claude-original shim"
path_exists "$(shim_dir_of "$HOME_I10")/opencode-original" "opencode-original shim"
occurs_once "$HOME_I10/.zshrc" "$PATH_BLOCK" "a single PATH block for both tools"
has_pattern "$REC/build.args" 'claude-code-sandbox' "claude image built"
has_line "$REC/build.args" "OPENCODE_TAG=v2.0.14" "opencode image built"

echo "=== I11: a foreign file at the shim path is never overwritten ==="
REC="$T/record/i12"
HOME_I12="$T/home-i12"
mkdir -p "$(shim_dir_of "$HOME_I12")"
echo "mine" > "$(shim_dir_of "$HOME_I12")/claude"
run_install "$REC" "$HOME_I12" "" claude-code
rc=$?
exit_code_is "$rc" 1 "install refuses"
content_is "$(shim_dir_of "$HOME_I12")/claude" "mine" "foreign file untouched"

echo "=== I12: no argument asks for confirmation, then installs every tool ==="
REC="$T/record/i12-confirm"
HOME_I12C="$T/home-i12-confirm"
echo y | FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_STATE=absent run_install "$REC" "$HOME_I12C" ""
rc=$?
exit_code_is "$rc" 0 "install succeeds after 'y'"
has_pattern "$REC/stderr.txt" 'Install all available tools \(claude-code, opencode\)\? \[y/N\]' "prompt lists the discovered tools"
path_exists "$(shim_dir_of "$HOME_I12C")/claude" "claude shim installed"
path_exists "$(shim_dir_of "$HOME_I12C")/opencode" "opencode shim installed"

echo "=== I12b: declining or EOF at the install confirmation changes nothing ==="
REC="$T/record/i12-decline"
HOME_I12D="$T/home-i12-decline"
echo n | run_install "$REC" "$HOME_I12D" ""
rc=$?
exit_code_is "$rc" 1 "'n' aborts"
has_pattern "$REC/stderr.txt" 'Aborted' "says it aborted"
path_absent "$HOME_I12D/.secure-ai" "no shim created after 'n'"
path_absent "$REC/build.args" "no image build after 'n'"
run_install "$REC" "$HOME_I12D" "" </dev/null
rc=$?
exit_code_is "$rc" 1 "EOF aborts"
path_absent "$HOME_I12D/.secure-ai" "no shim created on EOF"

echo "=== I12c: unknown tool -> usage ==="
REC="$T/record/i12-unknown"
run_install "$REC" "$T/home-i12-unknown" "" nonsense </dev/null
rc=$?
exit_code_is "$rc" 1 "unknown tool refused"
has_pattern "$REC/stderr.txt" 'Usage' "usage printed"

echo "=== R1: uninstall after install ==="
REC="$T/record/r1"
run_uninstall "$REC" "$HOME_I1" claude-code
rc=$?
exit_code_is "$rc" 0 "uninstall succeeds"
path_absent "$HOME_I1/.secure-ai" "shim directories removed"
has_no_pattern "$HOME_I1/.zshrc" 'secure-ai PATH' "PATH block removed"

echo "=== R2: uninstall removes a dangling original (claude-code and opencode) ==="
for tool_case in "claude-code:claude" "opencode:opencode"; do
  tool_name="${tool_case%%:*}"
  binary="${tool_case##*:}"
  REC="$T/record/r2-$tool_name"
  HOME_R2="$T/home-r2-$tool_name"
  DANGLING_NATIVE="$T/native-dangling-$tool_name"
  mkdir -p "$DANGLING_NATIVE"
  write_fake_native "$DANGLING_NATIVE/$binary" "$binary"
  FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_STATE=absent run_install "$REC" "$HOME_R2" "$DANGLING_NATIVE" "$tool_name"
  rm -f "$DANGLING_NATIVE/$binary"
  run_uninstall "$REC" "$HOME_R2" "$tool_name"
  rc=$?
  exit_code_is "$rc" 0 "$tool_name: uninstall succeeds"
  path_absent "$HOME_R2/.secure-ai" "$tool_name: shim directories removed, including the dangling symlink"
done

echo "=== R3: uninstall keeps the sandbox's own state ==="
REC="$T/record/r3"
HOME_R3="$T/home-r3"
run_install "$REC" "$HOME_R3" "" claude-code
mkdir -p "$HOME_R3/.secure-ai/claude-code/config"
echo '{"model":"opus"}' > "$HOME_R3/.secure-ai/claude-code/config/settings.json"
run_uninstall "$REC" "$HOME_R3" claude-code
rc=$?
exit_code_is "$rc" 0 "uninstall succeeds"
content_is "$HOME_R3/.secure-ai/claude-code/config/settings.json" '{"model":"opus"}' "config dir left in place"
path_absent "$HOME_R3/.secure-ai/bin" "shim directory removed"
has_pattern "$REC/stderr.txt" 'Kept: .*/claude-code' "uninstall says the state was kept"

echo "=== R4: uninstall without an install ==="
REC="$T/record/r4"
run_uninstall "$REC" "$T/home-r4" claude-code
rc=$?
exit_code_is "$rc" 1 "uninstall refuses"
has_pattern "$REC/stderr.txt" 'Nothing to uninstall' "explains there is nothing to uninstall"
run_uninstall "$REC" "$T/home-r4" all
rc=$?
exit_code_is "$rc" 1 "uninstall all refuses too"

echo "=== R5: uninstalling one tool leaves the other (and the PATH block) alone ==="
REC="$T/record/r5"
run_uninstall "$REC" "$HOME_I10" opencode
rc=$?
exit_code_is "$rc" 0 "uninstall opencode succeeds"
path_absent "$(shim_dir_of "$HOME_I10")/opencode" "opencode shim removed"
path_absent "$(shim_dir_of "$HOME_I10")/opencode-original" "opencode-original removed"
path_exists "$(shim_dir_of "$HOME_I10")/claude" "claude shim still there"
has_pattern "$HOME_I10/.zshrc" 'secure-ai PATH' "PATH block kept for the remaining tool"
run_uninstall "$REC" "$HOME_I10" claude-code
rc=$?
exit_code_is "$rc" 0 "uninstall claude-code succeeds"
has_no_pattern "$HOME_I10/.zshrc" 'secure-ai PATH' "PATH block removed with the last tool"
path_absent "$HOME_I10/.secure-ai" "everything removed"

echo "=== R6: uninstall all ==="
REC="$T/record/r6"
HOME_R6="$T/home-r6"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_STATE=absent run_install "$REC" "$HOME_R6" "" all
run_uninstall "$REC" "$HOME_R6" all
rc=$?
exit_code_is "$rc" 0 "uninstall all succeeds"
path_absent "$HOME_R6/.secure-ai" "everything removed"
has_no_pattern "$HOME_R6/.zshrc" 'secure-ai PATH' "PATH block removed"

echo "=== R7: no argument asks for confirmation before uninstalling every tool ==="
REC="$T/record/r8"
echo n | run_uninstall "$REC" "$HOME_I12C"
rc=$?
exit_code_is "$rc" 1 "'n' aborts"
path_exists "$(shim_dir_of "$HOME_I12C")/claude" "claude shim kept after 'n'"
run_uninstall "$REC" "$HOME_I12C" </dev/null
rc=$?
exit_code_is "$rc" 1 "EOF aborts"
path_exists "$(shim_dir_of "$HOME_I12C")/opencode" "opencode shim kept on EOF"
echo Yes | run_uninstall "$REC" "$HOME_I12C"
rc=$?
exit_code_is "$rc" 0 "uninstall succeeds after 'Yes'"
has_pattern "$REC/stderr.txt" 'Uninstall all available tools \(claude-code, opencode\)\? \[y/N\]' "prompt lists the discovered tools"
path_absent "$HOME_I12C/.secure-ai" "everything removed"

echo "=== R8: uninstall edits a symlinked rc file in place, keeping its permissions ==="
REC="$T/record/r7"
HOME_R7="$T/home-r7"
mkdir -p "$HOME_R7" "$T/dotfiles-r7"
echo "export KEEP=1" > "$T/dotfiles-r7/zshrc"
chmod 644 "$T/dotfiles-r7/zshrc"
ln -s "$T/dotfiles-r7/zshrc" "$HOME_R7/.zshrc"
run_install "$REC" "$HOME_R7" "" claude-code
run_uninstall "$REC" "$HOME_R7" claude-code
rc=$?
exit_code_is "$rc" 0 "uninstall succeeds"
link_points_to "$HOME_R7/.zshrc" "$T/dotfiles-r7/zshrc" "rc symlink preserved"
content_is "$T/dotfiles-r7/zshrc" "export KEEP=1" "only the PATH block was removed"
if [ -n "$(find "$T/dotfiles-r7/zshrc" -perm 644)" ]; then pass "rc permissions preserved"; else fail "rc permissions preserved"; fi

echo "=== R9: an install/uninstall cycle leaves the rc file byte for byte as it was ==="
REC="$T/record/r9"
HOME_R9="$T/home-r9"
mkdir -p "$HOME_R9"
printf 'export KEEP=1\n\nalias ll="ls -l"\n' > "$HOME_R9/.zshrc"
cp "$HOME_R9/.zshrc" "$T/zshrc-r9.expected"
run_install "$REC" "$HOME_R9" "" claude-code
run_uninstall "$REC" "$HOME_R9" claude-code
if cmp -s "$HOME_R9/.zshrc" "$T/zshrc-r9.expected"; then pass "rc file identical"; else fail "rc file identical"; fi
run_install "$REC" "$HOME_R9" "" claude-code
run_uninstall "$REC" "$HOME_R9" claude-code
if cmp -s "$HOME_R9/.zshrc" "$T/zshrc-r9.expected"; then pass "still identical after a second cycle"; else fail "still identical after a second cycle"; fi

echo "=== I13: Docker daemon not running -> install stops before changing anything ==="
REC="$T/record/i11"
HOME_I11="$T/home-i11"
FAKE_DOCKER_DOWN=1 run_install "$REC" "$HOME_I11" "" claude-code
rc=$?
exit_code_is "$rc" 1 "install refuses"
has_pattern "$REC/stderr.txt" 'Docker daemon is not running' "explains the daemon is down"
path_absent "$HOME_I11/.secure-ai" "no shim created"
path_absent "$HOME_I11/.zshrc" "no rc file touched"
path_absent "$REC/build.args" "no image build attempted"

echo "=== I14: a failed image build shows the docker output ==="
REC="$T/record/i14"
FAKE_BUILD_FAIL=1 run_install "$REC" "$T/home-i14" "" claude-code
rc=$?
exit_code_is "$rc" 1 "install fails"
has_pattern "$REC/stderr.txt" 'fake build failure' "docker output replayed on failure"

finish_tests
