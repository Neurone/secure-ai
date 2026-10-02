#!/usr/bin/env bash
# Tests for the sai dispatcher: usage, help, shortcuts, unknown commands,
# missing library files and the linter step of 'sai test'.
#
# Usage: bash tests/test-sai.sh

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

echo "=== D1: no command -> usage ==="
REC="$T/record/d1"
run_sai "$REC" "$T/home-d1"
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC/stderr.txt" 'Usage: sai <command>' "usage printed on stderr"

echo "=== D2: unknown command -> usage ==="
REC="$T/record/d2"
run_sai "$REC" "$T/home-d2" nonsense
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC/stderr.txt" 'Usage: sai <command>' "usage printed on stderr"

echo "=== D3: help lists every command ==="
for help_arg in help -h --help; do
  REC="$T/record/d3"
  run_sai "$REC" "$T/home-d3" "$help_arg"
  rc=$?
  exit_code_is "$rc" 0 "$help_arg succeeds"
  for command_name in install uninstall status test help; do
    has_pattern "$REC/stdout.txt" "^  $command_name(,| |\$)" "$help_arg lists '$command_name'"
  done
done

echo "=== D4: unknown test suite ==="
REC="$T/record/d4"
run_sai "$REC" "$T/home-d4" test nonsense
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC/stderr.txt" "unknown test suite 'nonsense'" "says which suite is unknown"
has_pattern "$REC/stderr.txt" 'Usage: sai test \[lint\|.*install' "lists the linter and the valid suites"

echo "=== D5: shortcuts reach their commands ==="
REC="$T/record/d5"
run_sai "$REC" "$T/home-d5" s
rc=$?
exit_code_is "$rc" 0 "'s' succeeds"
has_pattern "$REC/stdout.txt" '^claude-code$' "'s' prints the status report"
run_sai "$REC" "$T/home-d5" t nonsense
rc=$?
exit_code_is "$rc" 1 "'t nonsense' refused"
has_pattern "$REC/stderr.txt" "unknown test suite 'nonsense'" "'t' reaches the test command"
run_sai "$REC" "$T/home-d5" i nonsense </dev/null
rc=$?
exit_code_is "$rc" 1 "'i nonsense' refused"
has_pattern "$REC/stderr.txt" 'Usage: sai install' "'i' reaches the install command"
run_sai "$REC" "$T/home-d5" u nonsense </dev/null
rc=$?
exit_code_is "$rc" 1 "'u nonsense' refused"
has_pattern "$REC/stderr.txt" 'Usage: sai uninstall' "'u' reaches the uninstall command"
run_sai "$REC" "$T/home-d5" h
rc=$?
exit_code_is "$rc" 0 "'h' prints help"
has_pattern "$REC/stdout.txt" 'Usage: sai <command>' "'h' reaches the help"

echo "=== D6: a missing library file is reported through the log functions ==="
REC="$T/record/d6"
mkdir -p "$T/sai-copy"
cp "$SAI" "$T/sai-copy/"
cp -R "$REPO_DIR/lib" "$T/sai-copy/"
rm "$T/sai-copy/lib/components.sh"
bash "$T/sai-copy/sai" help >"$REC.stdout" 2>"$REC.stderr"
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC.stderr" 'Error: could not find required file at .*/lib/components\.sh$' "reported like any other error"

echo "=== D7: sai test lint runs shellcheck on every script ==="
REC="$T/record/d7"
FAKE_DOCKER_RECORD="$REC" run_sai "$REC" "$T/home-d7" test lint
rc=$?
exit_code_is "$rc" 0 "passes when shellcheck is clean"
has_line "$REC/shellcheck.args" "-x" "follows sourced files"
has_line "$REC/shellcheck.args" "$REPO_DIR/sai" "checks the sai entry point"
has_line "$REC/shellcheck.args" "$REPO_DIR/lib/commands/test.sh" "checks the libraries"
has_line "$REC/shellcheck.args" "$REPO_DIR/tools/opencode/container/entrypoint.sh" "checks the container scripts"
has_line "$REC/shellcheck.args" "$REPO_DIR/tests/lib/harness.sh" "checks the tests"
has_no_pattern "$REC/shellcheck.args" '/\.git/' "skips the .git directory"
has_no_pattern "$REC/stdout.txt" '^##### (sai|install|status|config|claude-code|opencode)$' "runs no test suite"
has_line "$REC/stdout.txt" "All suites passed." "reports success"

echo "=== D8: sai test lint fails when shellcheck reports findings ==="
REC="$T/record/d8"
FAKE_SHELLCHECK_FAIL=1 FAKE_DOCKER_RECORD="$REC" run_sai "$REC" "$T/home-d8" test lint
rc=$?
exit_code_is "$rc" 1 "refused"
has_line "$REC/stdout.txt" "FAILED suites: lint" "names the linter as failed"
has_pattern "$REC/stderr.txt" 'fake shellcheck: findings' "shows shellcheck's output"

echo "=== D9: sai test lint fails loudly without shellcheck ==="
REC="$T/record/d9"
mkdir -p "$REC" "$T/bin-no-shellcheck"
for tool in basename dirname find grep sort; do
  ln -s "$(command -v "$tool")" "$T/bin-no-shellcheck/$tool"
done
env HOME="$T/home-d9" PATH="$T/bin-no-shellcheck" "$BASH" "$SAI" test lint >"$REC/stdout.txt" 2>"$REC/stderr.txt"
rc=$?
exit_code_is "$rc" 1 "refused"
has_pattern "$REC/stderr.txt" 'Error: shellcheck not found in PATH' "says shellcheck is missing"
has_line "$REC/stdout.txt" "FAILED suites: lint" "names the linter as failed"

finish_tests
