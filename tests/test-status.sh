#!/usr/bin/env bash
# Tests for 'sai status', driven with the fake tools of lib/harness.sh.
#
# Usage: bash tests/test-status.sh

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

shim_dir_of() { printf '%s\n' "$1/.secure-ai/bin"; }

section "T1: nothing installed"
REC="$T/record/t1"
run_status "$REC" "$T/home-t1" ""
rc=$?
exit_code_is "$rc" 0 "status succeeds"
has_no_pattern "$REC/stdout.txt" 'shim: +installed' "no tool reported as installed"
has_pattern "$REC/stdout.txt" 'PATH entry in startup files: +none' "no PATH entry"
has_pattern "$REC/stdout.txt" 'Shim dir on current PATH: +no' "shim dir not on PATH"

section "T2: one tool installed, the other not"
REC="$T/record/t2"
HOME_T2="$T/home-t2"
run_install "$REC" "$HOME_T2" "$T/native" claude-code
mkdir -p "$HOME_T2/.secure-ai/claude-code/config"
run_status "$REC" "$HOME_T2" ""
rc=$?
exit_code_is "$rc" 0 "status succeeds"
section_of "$REC/stdout.txt" claude-code > "$REC/claude-code.section"
section_of "$REC/stdout.txt" opencode > "$REC/opencode.section"
has_pattern "$REC/claude-code.section" "shim: +installed.*$REPO_DIR/tools/claude-code/claude.sh" "claude shim installed"
has_pattern "$REC/claude-code.section" "original: +.*claude-original -> $T/native/claude" "native original shown"
has_pattern "$REC/claude-code.section" 'image: +claude-code-sandbox.*present' "image present"
has_pattern "$REC/claude-code.section" 'state: +.*claude-code \(exists\)' "state dir exists"
has_pattern "$REC/opencode.section" 'shim: +not installed' "opencode shim not installed"
has_pattern "$REC/opencode.section" 'original: +none' "opencode has no original"
has_pattern "$REC/opencode.section" 'state: +.*opencode \(absent\)' "opencode state dir absent"
has_pattern "$REC/stdout.txt" 'PATH entry in startup files: +.*\.zshrc' "PATH entry found in .zshrc"
has_pattern "$REC/stdout.txt" 'Shim dir on current PATH: +no' "shim dir not on this PATH"

section "T3: shim dir on the current PATH"
REC="$T/record/t3"
run_status "$REC" "$HOME_T2" "$(shim_dir_of "$HOME_T2")"
has_pattern "$REC/stdout.txt" 'Shim dir on current PATH: +yes' "shim dir on PATH"

section "T4: a single tool can be selected"
REC="$T/record/t4"
run_status "$REC" "$HOME_T2" "" claude-code
rc=$?
exit_code_is "$rc" 0 "status succeeds"
has_pattern "$REC/stdout.txt" '^claude-code$' "selected tool listed"
has_no_pattern "$REC/stdout.txt" '^opencode$' "other tool not listed"

section "T5: unknown tool -> usage"
REC="$T/record/t5"
run_status "$REC" "$HOME_T2" "" nonsense
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC/stderr.txt" 'Usage: sai status' "usage printed"

section "T6: image not built"
REC="$T/record/t6"
FAKE_IMAGE_STATE=absent run_status "$REC" "$HOME_T2" "" claude-code
has_pattern "$REC/stdout.txt" 'image: +claude-code-sandbox.*not built' "reports the missing image"

section "T7: dangling <tool>-original"
REC="$T/record/t7"
HOME_T7="$T/home-t7"
DANGLING_NATIVE="$T/native-dangling-t7"
mkdir -p "$DANGLING_NATIVE"
write_fake_native "$DANGLING_NATIVE/claude" claude
run_install "$REC" "$HOME_T7" "$DANGLING_NATIVE" claude-code
rm -f "$DANGLING_NATIVE/claude"
run_status "$REC" "$HOME_T7" "" claude-code
has_pattern "$REC/stdout.txt" 'original: +broken' "dangling original flagged"

section "T8: shim pointing somewhere else is stale"
REC="$T/record/t8"
HOME_T8="$T/home-t8"
mkdir -p "$(shim_dir_of "$HOME_T8")"
ln -s "$T/elsewhere/claude.sh" "$(shim_dir_of "$HOME_T8")/claude"
run_status "$REC" "$HOME_T8" "" claude-code
has_pattern "$REC/stdout.txt" "shim: +stale.*$T/elsewhere/claude.sh" "stale shim flagged with its target"

section "T9: a foreign file at the shim path is a conflict"
REC="$T/record/t9"
HOME_T9="$T/home-t9"
mkdir -p "$(shim_dir_of "$HOME_T9")"
echo "mine" > "$(shim_dir_of "$HOME_T9")/claude"
run_status "$REC" "$HOME_T9" "" claude-code
has_pattern "$REC/stdout.txt" 'shim: +conflict' "foreign file flagged"
content_is "$(shim_dir_of "$HOME_T9")/claude" "mine" "foreign file untouched"

section "T10: status changes nothing"
REC="$T/record/t10"
snapshot_of() { (cd "$1" && find . -exec ls -ld {} + | sort && cat .zshrc); }
snapshot_of "$HOME_T2" > "$REC.before"
run_status "$REC" "$HOME_T2" ""
snapshot_of "$HOME_T2" > "$REC.after"
if cmp -s "$REC.before" "$REC.after"; then pass "home directory untouched"; else fail "home directory changed"; fi
path_absent "$REC/build.args" "no image build"

finish_tests
