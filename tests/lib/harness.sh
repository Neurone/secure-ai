#!/usr/bin/env bash
# Shared harness for the test suites in tests/: assertions, a temp dir with
# fake `docker`, `git`, `security`, `uname` and `shellcheck` executables (so no
# Docker daemon, network, macOS keychain or installed claude/opencode is
# needed), and
# helpers that run the wrappers and the sai commands in a controlled
# environment. Source it from a suite, then call finish_tests at the end.
#
# The fake tools are controlled via env vars (documented where they are
# written below). Each scenario gets its own record directory holding the args
# the fake docker saw, plus the command's stdout/stderr.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SAI="$REPO_DIR/sai"
# shellcheck disable=SC2034 # read by the test files that source this harness
CLAUDE_WRAPPER="$REPO_DIR/tools/claude-code/claude.sh"
# shellcheck disable=SC2034 # read by the test files that source this harness
OPENCODE_WRAPPER="$REPO_DIR/tools/opencode/opencode.sh"
REAL_UNAME="$(command -v uname)"
REAL_GIT="$(command -v git)"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to run these tests." >&2
  exit 1
fi
if [ -z "$REAL_GIT" ]; then
  echo "Error: real git not found in PATH (needed by the fake git for 'git config')." >&2
  exit 1
fi

# PATH with every directory that has its own native tool executable stripped
# out, so the "no native install" scenarios are not accidentally satisfied by
# a real install (or an earlier `sai install` run) on the host running the tests.
PATH_WITHOUT_NATIVE="$(
  IFS=':'
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    for native in claude claude-original opencode opencode-original; do
      [ -x "$dir/$native" ] && continue 2
    done
    printf '%s:' "$dir"
  done
)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Assert an exact line exists in a file.
has_line() {
  if grep -Fxq -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (missing line: $2)"; fi
}
# Assert an exact line does NOT exist in a file.
has_no_line() {
  if grep -Fxq -- "$2" "$1" 2>/dev/null; then fail "$3 (unexpected line: $2)"; else pass "$3"; fi
}
# Assert at least one line matches an extended regex.
has_pattern() {
  if grep -Eq -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (no match for: $2)"; fi
}
# Assert no line matches an extended regex.
has_no_pattern() {
  if grep -Eq -- "$2" "$1" 2>/dev/null; then fail "$3 (unexpected match: $2)"; else pass "$3"; fi
}
# Assert an exact line occurs exactly once.
occurs_once() {
  local n
  n="$(grep -Fxc -- "$2" "$1" 2>/dev/null || true)"
  if [ "$n" = "1" ]; then pass "$3"; else fail "$3 (expected exactly 1 occurrence, got ${n:-0})"; fi
}
# Assert a file's (entire) content equals a string.
content_is() {
  local actual
  actual="$(cat "$1" 2>/dev/null || echo __missing__)"
  if [ "$actual" = "$2" ]; then pass "$3"; else fail "$3 (content: '$actual', expected '$2')"; fi
}
# section_of <report-file> <name>: the lines of the report block that starts at
# the unindented line <name> (e.g. one tool's block in 'sai status').
section_of() {
  awk -v name="$2" '/^[^ ]/ { printing = ($0 == name) } printing' "$1"
}
# Assert the last exit code ($1) equals the expected one ($2).
exit_code_is() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (exit code $1, expected $2)"; fi
}
# Assert a path exists (symlinks count, even dangling ones).
path_exists() {
  if [ -e "$1" ] || [ -L "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi
}
# Assert a path does not exist (symlinks count, even dangling ones).
path_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then fail "$2 (unexpected: $1)"; else pass "$2"; fi
}
# Assert a symlink points at the given target.
link_points_to() {
  if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then pass "$3"; else fail "$3 ($1 -> '$(readlink "$1" 2>/dev/null)', expected '$2')"; fi
}

finish_tests() {
  echo
  if [ "$FAILURES" -eq 0 ]; then
    echo "All tests passed."
  else
    echo "$FAILURES test(s) FAILED."
    exit 1
  fi
}

mkdir -p "$T/bin" "$T/native" "$T/project" "$T/record"

# --- fake docker -----------------------------------------------------------
# Env:
#   FAKE_DOCKER_RECORD  record dir (required)
#   FAKE_IMAGE_STATE    "present" (default) or "absent" for `image inspect`
#   FAKE_IMAGE_VERSION  version label printed by `image inspect --format`
#                       (opencode); without it that query fails
#   FAKE_BUILD_FAIL     "1" to make `docker build` fail
#   FAKE_DOCKER_DOWN    "1" to make `docker info` fail (daemon not running)
# `run` writes one line per argument to run.args, merging `-v X` and `-e Y`
# pairs, saves the value given to --settings in settings.arg, and records
# whether the mounted gitconfig copy still has a [credential] section.
cat > "$T/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  image)
    if [ "${2:-}" != "inspect" ]; then
      echo "fake docker: unhandled: $*" >&2
      exit 1
    fi
    if [ "${FAKE_IMAGE_STATE:-present}" != "present" ]; then
      echo "Error: No such image" >&2
      exit 1
    fi
    case " $* " in
      *" --format "*)
        if [ -n "${FAKE_IMAGE_VERSION:-}" ]; then
          printf '%s\n' "$FAKE_IMAGE_VERSION"
          exit 0
        fi
        echo "Error: No such image" >&2
        exit 1
        ;;
    esac
    exit 0
    ;;
  info)
    [ "${FAKE_DOCKER_DOWN:-0}" = "1" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
    exit 0
    ;;
  build)
    printf '%s\n' "$@" >> "${FAKE_DOCKER_RECORD:?}/build.args"
    if [ "${FAKE_BUILD_FAIL:-0}" = "1" ]; then
      echo "fake build failure" >&2
      exit 1
    fi
    exit 0
    ;;
  tag)
    printf '%s\n' "$@" >> "${FAKE_DOCKER_RECORD:?}/tag.args"
    exit 0
    ;;
  run)
    {
      prev=""
      expecting_settings=0
      for arg in "$@"; do
        if [ "$expecting_settings" = 1 ]; then
          printf '%s' "$arg" > "${FAKE_DOCKER_RECORD:?}/settings.arg"
          expecting_settings=0
          continue
        fi
        if [ "$arg" = "--settings" ]; then
          expecting_settings=1
          continue
        fi
        if [ -n "$prev" ]; then
          if [ "$prev" = "-v" ] || [ "$prev" = "-e" ]; then
            printf '%s\n' "$prev $arg"
            prev=""
          else
            printf '%s\n' "$prev"
            prev="$arg"
          fi
        else
          prev="$arg"
        fi
      done
      [ -n "$prev" ] && printf '%s\n' "$prev"
    } > "${FAKE_DOCKER_RECORD:?}/run.args"
    # While the wrapper is still alive, capture whether the mounted gitconfig
    # copy still contains a [credential] section (it must not).
    while IFS= read -r line; do
      case "$line" in
        "-v "*:/home/node/.gitconfig:ro)
          src="${line#-v }"
          src="${src%%:*}"
          if grep -q '^\[credential\]' "$src" 2>/dev/null; then
            echo 1 > "${FAKE_DOCKER_RECORD:?}/gitconfig-credential-count"
          else
            echo 0 > "${FAKE_DOCKER_RECORD:?}/gitconfig-credential-count"
          fi
          ;;
      esac
    done < "${FAKE_DOCKER_RECORD:?}/run.args"
    exit 0
    ;;
  *)
    echo "fake docker: unhandled: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$T/bin/docker"

# --- fake git ---------------------------------------------------------------
# Env:
#   FAKE_GIT_FAIL   "1" to make ls-remote fail (simulated offline)
#   FAKE_TAGS_V2    space-separated v2 tags to report (one ls-remote line each)
#   FAKE_TAGS_V3    space-separated v3 tags to report
# Every ls-remote call is appended to git.calls in the record dir, so tests can
# count the network round trips. Every other subcommand (the wrappers use
# `git config` for the filtered gitconfig copy) delegates to the real git.
cat > "$T/bin/git" <<FAKE
#!/usr/bin/env bash
case "\${1:-}" in
  ls-remote)
    [ -n "\${FAKE_DOCKER_RECORD:-}" ] && echo "\$*" >> "\$FAKE_DOCKER_RECORD/git.calls"
    if [ "\${FAKE_GIT_FAIL:-0}" = "1" ]; then
      echo "fatal: unable to access repo (simulated offline)" >&2
      exit 128
    fi
    for arg in "\$@"; do
      case "\$arg" in
        refs/tags/v2.*) [ -n "\${FAKE_TAGS_V2:-}" ] && printf 'deadbeef\trefs/tags/%s\n' \$FAKE_TAGS_V2 ;;
        refs/tags/v3.*) [ -n "\${FAKE_TAGS_V3:-}" ] && printf 'deadbeef\trefs/tags/%s\n' \$FAKE_TAGS_V3 ;;
      esac
    done
    exit 0
    ;;
  *)
    exec $REAL_GIT "\$@"
    ;;
esac
FAKE
chmod +x "$T/bin/git"

# --- fake security (macOS keychain) ------------------------------------------
# Env:
#   FAKE_CERTS_FAIL      "1" to make the certificate export fail
# Every call is appended to security.calls in the record dir, so tests can
# assert which keychain queries a wrapper made (only certificates are fine).
cat > "$T/bin/security" <<'FAKE'
#!/usr/bin/env bash
[ -n "${FAKE_DOCKER_RECORD:-}" ] && echo "$*" >> "$FAKE_DOCKER_RECORD/security.calls"
case "${1:-}" in
  find-certificate)
    [ "${FAKE_CERTS_FAIL:-0}" = "1" ] && exit 1
    printf -- '-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n'
    exit 0
    ;;
  *)
    echo "fake security: unhandled: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$T/bin/security"

# --- fake uname ----------------------------------------------------------------
# Reports $FAKE_UNAME_S (default Darwin) for `uname -s` so the OS-specific
# branches run identically on any host running the tests.
cat > "$T/bin/uname" <<FAKE
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then echo "\${FAKE_UNAME_S:-Darwin}"; else exec "$REAL_UNAME" "\$@"; fi
FAKE
chmod +x "$T/bin/uname"

# --- fake shellcheck -------------------------------------------------------------
# Env:
#   FAKE_SHELLCHECK_FAIL  "1" to report findings (exit 1)
# Saves its arguments, one per line, to shellcheck.args in the record dir, so
# tests can assert which scripts `sai test lint` checks.
cat > "$T/bin/shellcheck" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_DOCKER_RECORD:?}/shellcheck.args"
if [ "${FAKE_SHELLCHECK_FAIL:-0}" = "1" ]; then
  echo "fake shellcheck: findings" >&2
  exit 1
fi
FAKE
chmod +x "$T/bin/shellcheck"

# --- fake native installs --------------------------------------------------------
# They log every execution in native-calls, to prove the sandbox never runs them.
NATIVE_CALLS="$T/native-calls"
write_fake_native() {
  local path="$1" name="$2"
  printf '#!/usr/bin/env bash\necho called >> "%s"\necho "native %s"\n' "$NATIVE_CALLS" "$name" > "$path"
  chmod +x "$path"
}
write_fake_native "$T/native/claude" claude
write_fake_native "$T/native/opencode" opencode

# ---------------------------------------------------------------------------
# Run helpers
# ---------------------------------------------------------------------------

# run_wrapper <wrapper> <record-dir> <home-dir> <extra-path-dir-or-empty> [wrapper args...]
# Runs a wrapper from the fixture project dir with a controlled environment.
# FAKE_* / OPENCODE_CONFIG env vars set by the caller are forwarded. The XDG
# variables point at decoy dirs: the sandboxes must ignore them. stdin is
# never a terminal, so the wrappers can never block on a prompt.
run_wrapper() {
  local wrapper="$1" record="$2" home_dir="$3" extra_path="$4"
  shift 4
  mkdir -p "$record"
  rm -f "$record"/run.args "$record"/build.args "$record"/tag.args "$record"/settings.arg \
        "$record"/git.calls "$record"/security.calls "$record"/gitconfig-credential-count \
        "$record"/stdout.txt "$record"/stderr.txt
  (
    cd "$T/project" || exit 99
    env HOME="$home_dir" \
        SHELL=/bin/zsh \
        TZ=Europe/Rome \
        XDG_CONFIG_HOME="$T/xdg-decoy/config" XDG_DATA_HOME="$T/xdg-decoy/data" \
        XDG_STATE_HOME="$T/xdg-decoy/state" XDG_CACHE_HOME="$T/xdg-decoy/cache" \
        OPENCODE_CONFIG="${OPENCODE_CONFIG:-}" \
        FAKE_DOCKER_RECORD="$record" \
        PATH="$T/bin:${extra_path:+$extra_path:}$PATH_WITHOUT_NATIVE" \
        bash "$wrapper" "$@" >"$record/stdout.txt" 2>"$record/stderr.txt" </dev/null
  )
}

# run_install <record-dir> <home-dir> <extra-path-dir-or-empty> <sai install args...>
run_install() {
  local record="$1" home_dir="$2" extra_path="$3"
  shift 3
  mkdir -p "$record" "$home_dir"
  rm -f "$record"/build.args "$record"/tag.args "$record"/stdout.txt "$record"/stderr.txt
  env HOME="$home_dir" \
      SHELL=/bin/zsh \
      FAKE_DOCKER_RECORD="$record" \
      PATH="$T/bin:${extra_path:+$extra_path:}$PATH_WITHOUT_NATIVE" \
      bash "$SAI" install "$@" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

# run_uninstall <record-dir> <home-dir> <sai uninstall args...>
run_uninstall() {
  local record="$1" home_dir="$2"
  shift 2
  mkdir -p "$record" "$home_dir"
  env HOME="$home_dir" \
      SHELL=/bin/zsh \
      PATH="$T/bin:$PATH_WITHOUT_NATIVE" \
      bash "$SAI" uninstall "$@" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

# run_status <record-dir> <home-dir> <extra-path-dir-or-empty> <sai status args...>
run_status() {
  local record="$1" home_dir="$2" extra_path="$3"
  shift 3
  mkdir -p "$record" "$home_dir"
  env HOME="$home_dir" \
      SHELL=/bin/zsh \
      FAKE_DOCKER_RECORD="$record" \
      PATH="$T/bin:${extra_path:+$extra_path:}$PATH_WITHOUT_NATIVE" \
      bash "$SAI" status "$@" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

# run_config <record-dir> <home-dir> <sai config args...>
# FAKE_* env vars set by the caller are forwarded; the fake git needs
# FAKE_TAGS_V2 for the opencode image build.
run_config() {
  local record="$1" home_dir="$2"
  shift 2
  mkdir -p "$record" "$home_dir"
  rm -f "$record"/build.args "$record"/tag.args "$record"/stdout.txt "$record"/stderr.txt
  env HOME="$home_dir" \
      SHELL=/bin/zsh \
      FAKE_DOCKER_RECORD="$record" \
      PATH="$T/bin:$PATH_WITHOUT_NATIVE" \
      bash "$SAI" config "$@" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

# run_sai <record-dir> <home-dir> <sai args...>
# Runs any sai command line as-is, e.g. to test the dispatcher itself.
run_sai() {
  local record="$1" home_dir="$2"
  shift 2
  mkdir -p "$record" "$home_dir"
  env HOME="$home_dir" \
      SHELL=/bin/zsh \
      PATH="$T/bin:$PATH_WITHOUT_NATIVE" \
      bash "$SAI" "$@" >"$record/stdout.txt" 2>"$record/stderr.txt"
}
