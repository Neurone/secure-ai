#!/usr/bin/env bash
# Tests for 'sai config' (show and edit the container components), driven with
# the fake tools of lib/harness.sh.
#
# Usage: bash tests/test-config.sh

# shellcheck source=SCRIPTDIR/lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

overlay_of() { printf '%s\n' "$1/.secure-ai/$2/components.conf"; }

export FAKE_TAGS_V2="v2.0.14"

echo "=== C1: show every tool with the required markers ==="
REC="$T/record/c1"
run_config "$REC" "$T/home-c1"
rc=$?
exit_code_is "$rc" 0 "config succeeds"
has_line "$REC/stdout.txt" "claude-code" "claude-code listed"
has_line "$REC/stdout.txt" "opencode" "opencode listed"
section_of "$REC/stdout.txt" claude-code > "$REC/claude-code.section"
section_of "$REC/stdout.txt" opencode > "$REC/opencode.section"
has_line "$REC/claude-code.section" "    tzdata (required)" "claude-code: tzdata is required"
has_line "$REC/claude-code.section" "    curl" "claude-code: curl listed"
has_line "$REC/claude-code.section" "    cypress@15.15.0" "claude-code: npm package listed"
has_line "$REC/opencode.section" "    jq (required)" "opencode: jq is required"
has_line "$REC/opencode.section" "    (none)" "opencode: no npm package"
path_absent "$REC/build.args" "showing builds nothing"

echo "=== C2: show a single tool ==="
REC="$T/record/c2"
run_config "$REC" "$T/home-c1" opencode
rc=$?
exit_code_is "$rc" 0 "config opencode succeeds"
has_line "$REC/stdout.txt" "opencode" "opencode listed"
has_no_line "$REC/stdout.txt" "claude-code" "claude-code not listed"

echo "=== C3: add a comma separated list rebuilds with the new packages ==="
REC="$T/record/c3"
HOME_C3="$T/home-c3"
run_config "$REC" "$HOME_C3" claude-code add apt nc,htop
rc=$?
exit_code_is "$rc" 0 "add succeeds"
has_pattern "$REC/build.args" '^APT_PACKAGES=.* nc htop$' "rebuild passes the added packages"
has_pattern "$REC/build.args" '^NPM_PACKAGES=cypress@15.15.0$' "rebuild passes the npm packages"
has_pattern "$REC/build.args" '^APT_PACKAGES=tzdata ' "required packages stay in the list"
has_line "$(overlay_of "$HOME_C3" claude-code)" "add apt nc" "overlay records nc"
has_line "$(overlay_of "$HOME_C3" claude-code)" "add apt htop" "overlay records htop"
run_config "$REC" "$HOME_C3" claude-code
has_line "$REC/stdout.txt" "    nc (added)" "show marks the added package"

echo "=== C4: remove a default, then add it back ==="
REC="$T/record/c4"
HOME_C4="$T/home-c4"
run_config "$REC" "$HOME_C4" claude-code remove apt vim
rc=$?
exit_code_is "$rc" 0 "remove succeeds"
has_no_pattern "$REC/build.args" '^APT_PACKAGES=.*\bvim\b' "vim no longer in the build"
has_line "$(overlay_of "$HOME_C4" claude-code)" "remove apt vim" "overlay records the removal"
run_config "$REC" "$HOME_C4" claude-code
has_line "$REC/stdout.txt" "    vim (removed)" "show marks the removed default"
run_config "$REC" "$HOME_C4" claude-code add apt vim
rc=$?
exit_code_is "$rc" 0 "re-adding succeeds"
has_pattern "$REC/build.args" '^APT_PACKAGES=.*\bvim\b' "vim back in the build"
has_no_pattern "$(overlay_of "$HOME_C4" claude-code)" 'vim' "overlay no longer mentions vim"

echo "=== C5: remove an added package drops its overlay entry ==="
REC="$T/record/c5"
run_config "$REC" "$HOME_C3" claude-code remove apt nc
rc=$?
exit_code_is "$rc" 0 "remove succeeds"
has_no_pattern "$(overlay_of "$HOME_C3" claude-code)" 'nc' "overlay no longer mentions nc"
has_line "$(overlay_of "$HOME_C3" claude-code)" "add apt htop" "other additions kept"

echo "=== C6: an npm package can be removed by name ==="
REC="$T/record/c6"
HOME_C6="$T/home-c6"
run_config "$REC" "$HOME_C6" claude-code remove npm cypress
rc=$?
exit_code_is "$rc" 0 "remove succeeds"
has_line "$(overlay_of "$HOME_C6" claude-code)" "remove npm cypress@15.15.0" "overlay stores the full package"
has_line "$REC/build.args" "NPM_PACKAGES=" "npm list is empty in the build"

echo "=== C7: scoped npm packages are accepted ==="
REC="$T/record/c7"
HOME_C7="$T/home-c7"
run_config "$REC" "$HOME_C7" opencode add npm @scope/pkg@1.2.3
rc=$?
exit_code_is "$rc" 0 "add succeeds"
has_line "$REC/build.args" "NPM_PACKAGES=@scope/pkg@1.2.3" "scoped package passed to the build"
run_config "$REC" "$HOME_C7" opencode remove npm @scope/pkg
rc=$?
exit_code_is "$rc" 0 "remove by name succeeds"
has_no_pattern "$(overlay_of "$HOME_C7" opencode)" 'scope' "overlay no longer mentions it"

echo "=== C8: shortcuts ==="
REC="$T/record/c8"
HOME_C8="$T/home-c8"
FAKE_DOCKER_RECORD="$REC" run_sai "$REC" "$HOME_C8" c opencode a apt nc
rc=$?
exit_code_is "$rc" 0 "'sai c opencode a apt nc' succeeds"
has_line "$(overlay_of "$HOME_C8" opencode)" "add apt nc" "alias 'a' adds"
FAKE_DOCKER_RECORD="$REC" run_sai "$REC" "$HOME_C8" c opencode r apt nc
rc=$?
exit_code_is "$rc" 0 "'sai c opencode r apt nc' succeeds"
has_no_pattern "$(overlay_of "$HOME_C8" opencode)" 'nc' "alias 'r' removes"

echo "=== C9: required packages cannot be removed ==="
REC="$T/record/c9"
HOME_C9="$T/home-c9"
run_config "$REC" "$HOME_C9" opencode remove apt jq
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC/stderr.txt" "'jq' is required" "explains why"
path_absent "$(overlay_of "$HOME_C9" opencode)" "overlay not written"
path_absent "$REC/build.args" "no rebuild"

echo "=== C10: removing an absent package is refused ==="
REC="$T/record/c10"
run_config "$REC" "$HOME_C9" opencode remove apt nonsense
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC/stderr.txt" "'nonsense' is not in the apt list" "explains why"
run_config "$REC" "$HOME_C4" claude-code remove apt vim
run_config "$REC" "$HOME_C4" claude-code remove apt vim
rc=$?
exit_code_is "$rc" 1 "an already removed package is refused too"

echo "=== C11: unknown category and invalid names are refused ==="
REC="$T/record/c11"
run_config "$REC" "$HOME_C9" opencode add pip requests
rc=$?
exit_code_is "$rc" 1 "unknown category refused"
has_pattern "$REC/stderr.txt" "unknown category 'pip'" "names the category"
run_config "$REC" "$HOME_C9" opencode add apt 'a;b'
rc=$?
exit_code_is "$rc" 1 "invalid package name refused"
has_pattern "$REC/stderr.txt" "invalid package name 'a;b'" "names the package"
run_config "$REC" "$HOME_C9" opencode add apt -oOption
rc=$?
exit_code_is "$rc" 1 "a name starting with '-' refused"
path_absent "$(overlay_of "$HOME_C9" opencode)" "overlay not written"
path_absent "$REC/build.args" "no rebuild"

echo "=== C12: Docker down -> nothing written ==="
REC="$T/record/c12"
HOME_C12="$T/home-c12"
FAKE_DOCKER_DOWN=1 run_config "$REC" "$HOME_C12" claude-code add apt nc
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC/stderr.txt" 'Docker daemon is not running' "explains the daemon is down"
path_absent "$(overlay_of "$HOME_C12" claude-code)" "overlay not written"

echo "=== C13: adding a package already in the list does not rebuild ==="
REC="$T/record/c13"
run_config "$REC" "$HOME_C9" claude-code add apt curl
rc=$?
exit_code_is "$rc" 0 "succeeds"
has_pattern "$REC/stderr.txt" 'Nothing to change' "says nothing changed"
path_absent "$REC/build.args" "no rebuild"
path_absent "$(overlay_of "$HOME_C9" claude-code)" "overlay not written"

echo "=== C14: a failed rebuild keeps the overlay and points to 'sai install' ==="
REC="$T/record/c14"
HOME_C14="$T/home-c14"
FAKE_BUILD_FAIL=1 run_config "$REC" "$HOME_C14" claude-code add apt nc
rc=$?
exit_code_is "$rc" 1 "fails"
has_pattern "$REC/stderr.txt" 'fake build failure' "docker output replayed"
has_pattern "$REC/stderr.txt" "Retry with 'sai install claude-code'" "tells how to retry"
has_line "$(overlay_of "$HOME_C14" claude-code)" "add apt nc" "overlay kept"

echo "=== C15: usage errors ==="
REC="$T/record/c15"
run_config "$REC" "$T/home-c15" nonsense
rc=$?
exit_code_is "$rc" 1 "unknown tool refused"
has_pattern "$REC/stderr.txt" 'Usage: sai config' "usage printed"
run_config "$REC" "$T/home-c15" opencode add apt
rc=$?
exit_code_is "$rc" 1 "add without a package refused"
run_config "$REC" "$T/home-c15" opencode frobnicate apt nc
rc=$?
exit_code_is "$rc" 1 "unknown action refused"

echo "=== C16: a malformed overlay is reported with its position ==="
REC="$T/record/c16"
HOME_C16="$T/home-c16"
mkdir -p "$HOME_C16/.secure-ai/opencode"
printf '# my packages\nadd apt nc\nfrobnicate apt vim\n' > "$(overlay_of "$HOME_C16" opencode)"
run_config "$REC" "$HOME_C16" opencode
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC/stderr.txt" 'components\.conf:3: expected' "points at the bad line"

echo "=== C17: an overlay removing a required package cannot drop it ==="
REC="$T/record/c17"
HOME_C17="$T/home-c17"
mkdir -p "$HOME_C17/.secure-ai/opencode"
echo "remove apt jq" > "$(overlay_of "$HOME_C17" opencode)"
run_config "$REC" "$HOME_C17" opencode
rc=$?
exit_code_is "$rc" 0 "show succeeds"
has_pattern "$REC/stderr.txt" "removes the required package 'jq'" "warns"
has_line "$REC/stdout.txt" "    jq (required)" "jq stays required"

echo "=== C18: reset asks for confirmation, drops the overlay and rebuilds with the defaults ==="
REC="$T/record/c18"
HOME_C18="$T/home-c18"
run_config "$REC" "$HOME_C18" claude-code add apt nc </dev/null
run_config "$REC" "$HOME_C18" claude-code remove apt vim </dev/null
echo y | run_config "$REC" "$HOME_C18" claude-code reset
rc=$?
exit_code_is "$rc" 0 "reset succeeds after 'y'"
has_pattern "$REC/stderr.txt" 'Reset the components of claude-code to the defaults and rebuild the images\? \[y/N\]' "asks first"
path_absent "$(overlay_of "$HOME_C18" claude-code)" "overlay removed"
has_pattern "$REC/build.args" '^APT_PACKAGES=.*\bvim\b' "rebuild brings the removed default back"
has_no_pattern "$REC/build.args" '^APT_PACKAGES=.*\bnc\b' "rebuild drops the added package"

echo "=== C19: declining or EOF at the reset confirmation changes nothing ==="
REC="$T/record/c19"
HOME_C19="$T/home-c19"
run_config "$REC" "$HOME_C19" claude-code add apt nc </dev/null
echo n | run_config "$REC" "$HOME_C19" claude-code reset
rc=$?
exit_code_is "$rc" 1 "'n' aborts"
has_pattern "$REC/stderr.txt" 'Aborted' "says it aborted"
path_absent "$REC/build.args" "no rebuild"
run_config "$REC" "$HOME_C19" claude-code reset </dev/null
rc=$?
exit_code_is "$rc" 1 "EOF aborts"
has_line "$(overlay_of "$HOME_C19" claude-code)" "add apt nc" "overlay kept"

echo "=== C20: reset without customizations asks nothing and rebuilds nothing ==="
REC="$T/record/c20"
run_config "$REC" "$T/home-c20" claude-code reset </dev/null
rc=$?
exit_code_is "$rc" 0 "succeeds"
has_pattern "$REC/stderr.txt" 'Nothing to change' "says nothing changed"
has_no_pattern "$REC/stderr.txt" '\[y/N\]' "no prompt"
path_absent "$REC/build.args" "no rebuild"

echo "=== C21: reset needs Docker and a valid command line ==="
REC="$T/record/c21"
FAKE_DOCKER_DOWN=1 run_config "$REC" "$HOME_C19" claude-code reset </dev/null
rc=$?
exit_code_is "$rc" 1 "refused with Docker down"
has_line "$(overlay_of "$HOME_C19" claude-code)" "add apt nc" "overlay kept"
run_config "$REC" "$HOME_C19" reset </dev/null
rc=$?
exit_code_is "$rc" 1 "reset without a tool refused"
run_config "$REC" "$HOME_C19" claude-code reset extra </dev/null
rc=$?
exit_code_is "$rc" 1 "reset with extra arguments refused"

echo "=== C22: reset repairs a malformed overlay ==="
REC="$T/record/c22"
HOME_C22="$T/home-c22"
mkdir -p "$HOME_C22/.secure-ai/opencode"
echo "frobnicate apt vim" > "$(overlay_of "$HOME_C22" opencode)"
echo y | run_config "$REC" "$HOME_C22" opencode reset
rc=$?
exit_code_is "$rc" 0 "reset succeeds"
path_absent "$(overlay_of "$HOME_C22" opencode)" "malformed overlay removed"

echo "=== C23: 'all reset' resets only the customized tools, after a single confirmation ==="
REC="$T/record/c23"
HOME_C23="$T/home-c23"
run_config "$REC" "$HOME_C23" claude-code add apt nc </dev/null
run_config "$REC" "$HOME_C23" opencode add apt htop </dev/null
echo y | run_config "$REC" "$HOME_C23" all reset
rc=$?
exit_code_is "$rc" 0 "succeeds after one 'y'"
has_pattern "$REC/stderr.txt" 'Reset the components of claude-code opencode to the defaults' "names the customized tools"
path_absent "$(overlay_of "$HOME_C23" claude-code)" "claude-code overlay removed"
path_absent "$(overlay_of "$HOME_C23" opencode)" "opencode overlay removed"
has_pattern "$REC/build.args" 'claude-code-sandbox' "claude-code image rebuilt"
has_line "$REC/build.args" "OPENCODE_TAG=v2.0.14" "opencode image rebuilt"
run_config "$REC" "$HOME_C23" claude-code add apt nc </dev/null
echo y | run_config "$REC" "$HOME_C23" all reset
has_no_pattern "$REC/build.args" 'OPENCODE_TAG' "a tool without customizations is not rebuilt"
run_config "$REC" "$HOME_C23" claude-code add apt nc </dev/null
echo n | run_config "$REC" "$HOME_C23" all reset
rc=$?
exit_code_is "$rc" 1 "'n' aborts"
has_line "$(overlay_of "$HOME_C23" claude-code)" "add apt nc" "overlay kept after 'n'"
run_config "$REC" "$T/home-c23-clean" all reset </dev/null
rc=$?
exit_code_is "$rc" 0 "nothing customized: succeeds without a prompt"
has_pattern "$REC/stderr.txt" 'Nothing to change' "says nothing changed"

echo "=== C24: 'all add' adds to every tool and rebuilds each image ==="
REC="$T/record/c24"
HOME_C24="$T/home-c24"
run_config "$REC" "$HOME_C24" all add apt nc,htop
rc=$?
exit_code_is "$rc" 0 "succeeds"
has_line "$(overlay_of "$HOME_C24" claude-code)" "add apt nc" "claude-code overlay records nc"
has_line "$(overlay_of "$HOME_C24" opencode)" "add apt htop" "opencode overlay records htop"
has_pattern "$REC/build.args" 'claude-code-sandbox' "claude-code image rebuilt"
has_line "$REC/build.args" "OPENCODE_TAG=v2.0.14" "opencode image rebuilt"

echo "=== C25: 'all remove' removes a package listed by every tool ==="
REC="$T/record/c25"
run_config "$REC" "$HOME_C24" all remove apt nc
rc=$?
exit_code_is "$rc" 0 "succeeds"
has_no_pattern "$(overlay_of "$HOME_C24" claude-code)" 'nc' "claude-code overlay no longer mentions nc"
has_line "$(overlay_of "$HOME_C24" opencode)" "add apt htop" "other additions kept"

echo "=== C26: 'all remove' skips, with a message, the tools that don't list the package ==="
REC="$T/record/c26"
HOME_C26="$T/home-c26"
run_config "$REC" "$HOME_C26" all remove npm cypress
rc=$?
exit_code_is "$rc" 0 "succeeds"
has_line "$(overlay_of "$HOME_C26" claude-code)" "remove npm cypress@15.15.0" "removed where it is listed"
path_absent "$(overlay_of "$HOME_C26" opencode)" "opencode untouched"
has_pattern "$REC/stderr.txt" "Skipping opencode: 'cypress' is not in its npm list" "says which tool was skipped"
has_pattern "$REC/build.args" 'claude-code-sandbox' "claude-code image rebuilt"
has_no_pattern "$REC/build.args" 'OPENCODE_TAG' "opencode image not rebuilt"

echo "=== C27: 'all remove' removes where it can and warns where the package is required ==="
REC="$T/record/c27"
HOME_C27="$T/home-c27"
run_config "$REC" "$HOME_C27" all remove apt jq
rc=$?
exit_code_is "$rc" 0 "succeeds"
has_line "$(overlay_of "$HOME_C27" claude-code)" "remove apt jq" "removed from claude-code, where it is a default"
path_absent "$(overlay_of "$HOME_C27" opencode)" "opencode untouched"
has_pattern "$REC/stderr.txt" "Warning: cannot remove 'jq' from opencode" "warns about the tool that requires it"
has_no_pattern "$REC/build.args" 'OPENCODE_TAG' "opencode image not rebuilt"

echo "=== C28: 'all remove' of a package no tool lists only warns ==="
REC="$T/record/c28"
run_config "$REC" "$T/home-c28" all remove apt nonsense
rc=$?
exit_code_is "$rc" 0 "succeeds"
has_pattern "$REC/stderr.txt" 'no package could be removed from any tool' "warns"
path_absent "$REC/build.args" "no rebuild"

echo "=== C29: 'all' validates every tool before writing anything ==="
REC="$T/record/c29"
HOME_C29="$T/home-c29"
mkdir -p "$HOME_C29/.secure-ai/opencode"
echo "frobnicate apt vim" > "$(overlay_of "$HOME_C29" opencode)"
run_config "$REC" "$HOME_C29" all add apt nc
rc=$?
exit_code_is "$rc" 1 "refused because of opencode's overlay"
path_absent "$(overlay_of "$HOME_C29" claude-code)" "claude-code overlay not written"
path_absent "$REC/build.args" "no rebuild"
run_config "$REC" "$T/home-c29b" all add apt 'a;b'
rc=$?
exit_code_is "$rc" 1 "invalid package name refused"
path_absent "$(overlay_of "$T/home-c29b" claude-code)" "nothing written"
FAKE_DOCKER_DOWN=1 run_config "$REC" "$T/home-c29b" all add apt nc
rc=$?
exit_code_is "$rc" 1 "refused with Docker down"
path_absent "$(overlay_of "$T/home-c29b" claude-code)" "nothing written without Docker"

echo "=== C30: 'reset' needs an explicit tool or 'all'; 'all remove' validates names ==="
REC="$T/record/c30"
run_config "$REC" "$T/home-c30" reset </dev/null
rc=$?
exit_code_is "$rc" 1 "'reset' alone refused"
has_pattern "$REC/stderr.txt" 'sai config <.*\|all> reset' "usage shows the explicit target"
run_config "$REC" "$T/home-c30" all remove apt 'a;b'
rc=$?
exit_code_is "$rc" 1 "invalid package name refused"
has_pattern "$REC/stderr.txt" "invalid package name 'a;b'" "names the package"
path_absent "$REC/build.args" "no rebuild"

finish_tests
