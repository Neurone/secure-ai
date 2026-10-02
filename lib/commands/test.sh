#!/usr/bin/env bash

# 'sai test': runs the linter (shellcheck on every shell script) and the
# suites in tests/ (tests/test-<name>.sh), all of them or just the one named.

# Prints the names of the available checks, one per line: the linter, then the
# test suites.
list_test_suites() {
  local suite_file suite_name
  echo "lint"
  for suite_file in "$REPO_DIR"/tests/test-*.sh; do
    suite_name="$(basename "$suite_file" .sh)"
    echo "${suite_name#test-}"
  done
}

# Prints the path of every shell script of the repository, one per line: the
# sai entry point and all the *.sh files.
list_shell_scripts() {
  {
    echo "$REPO_DIR/sai"
    find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o -name '*.sh' -print
  } | sort
}

# Runs shellcheck on every shell script, following sourced files (-x) like the
# editor setup in .vscode/settings.json does.
run_lint() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    log_error "shellcheck not found in PATH. Install it to lint the scripts (e.g. 'brew install shellcheck' or 'apt install shellcheck')."
    return 1
  fi
  local script
  local -a scripts=()
  while IFS= read -r script; do
    scripts+=("$script")
  done < <(list_shell_scripts)
  shellcheck -x "${scripts[@]}"
}

# Runs the check named $1: the linter or a test suite.
run_test_suite() {
  case "$1" in
    lint) run_lint ;;
    *) bash "$REPO_DIR/tests/test-$1.sh" ;;
  esac
}

# Usage: sai test [lint|suite]
cmd_test() {
  local requested_suite="${1:-}" suite
  local -a suites=() failed_suites=()
  while IFS= read -r suite; do
    suites+=("$suite")
  done < <(list_test_suites)

  if [ -n "$requested_suite" ]; then
    if ! printf '%s\n' "${suites[@]}" | grep -qxF -- "$requested_suite"; then
      log_error "unknown test suite '$requested_suite'."
      echo "Usage: sai test [$(IFS='|'; echo "${suites[*]}")]" >&2
      exit 1
    fi
    suites=("$requested_suite")
  fi

  for suite in "${suites[@]}"; do
    echo "##### $suite"
    run_test_suite "$suite" || failed_suites+=("$suite")
    echo
  done

  if [ "${#failed_suites[@]}" -gt 0 ]; then
    echo "FAILED suites: ${failed_suites[*]}"
    exit 1
  fi
  echo "All suites passed."
}
