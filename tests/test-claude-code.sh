#!/usr/bin/env bash
# Tests for the Claude Code sandbox: tools/claude-code/claude.sh (the wrapper)
# and its container entrypoint, driven with the fake tools of lib/harness.sh.
# The sandbox must stay isolated from any native claude: several scenarios
# assert that nothing of it is read, run or mounted.
#
# Usage: bash tests/test-claude-code.sh

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# run_claude <record-dir> <home-dir> <extra-path-dir-or-empty> [wrapper args...]
run_claude() { run_wrapper "$CLAUDE_WRAPPER" "$@"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

mkdir -p "$T/hooks"

# A host that has Claude Code configured: ~/.claude with entries, a
# settings.json declaring a hook, ~/.claude.json and a ~/.gitconfig.
CONFIGURED_HOME="$T/home-configured"
mkdir -p "$CONFIGURED_HOME/.claude/agents"
printf '#!/bin/sh\nexit 0\n' > "$T/hooks/compliance.sh"
chmod +x "$T/hooks/compliance.sh"
cat > "$CONFIGURED_HOME/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "$T/hooks/compliance.sh" } ] }
    ]
  }
}
EOF
echo "# memory" > "$CONFIGURED_HOME/.claude/CLAUDE.md"
echo '{"theme":"dark"}' > "$CONFIGURED_HOME/.claude.json"
cat > "$CONFIGURED_HOME/.gitconfig" <<EOF
[user]
	name = Test User
[credential]
	helper = osxkeychain
EOF

# A host with no Claude Code state at all.
BARE_HOME="$T/home-bare"
mkdir -p "$BARE_HOME"

# ---------------------------------------------------------------------------
# W1: nothing configured on the host
# ---------------------------------------------------------------------------
section "W1: bare host"
REC="$T/record/w1"
BARE_CONFIG_DIR="$BARE_HOME/.secure-ai/claude-code/config"
run_claude "$REC" "$BARE_HOME" ""
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
path_absent "$REC/build.args" "no image build (image present)"
has_line "$REC/run.args" "-v secure-claude-code-local:/home/node/.local" "binary volume mounted"
has_line "$REC/run.args" "-v $BARE_CONFIG_DIR:$BARE_CONFIG_DIR" "sandbox config dir mounted at the same path"
has_line "$REC/run.args" "-e CLAUDE_CONFIG_DIR=$BARE_CONFIG_DIR" "CLAUDE_CONFIG_DIR points at it"
path_exists "$BARE_CONFIG_DIR" "config dir created on the host (not left for Docker to create as root)"
has_no_pattern "$REC/run.args" 'HOST_CLAUDE_VERSION' "no host version passed"
has_no_pattern "$REC/run.args" ':/home/node/\.claude' "nothing mounted at the container's default ~/.claude"
has_no_pattern "$REC/run.args" ':/home/node/\.gitconfig' "no gitconfig mounted"
has_line "$REC/run.args" "-e TZ=Europe/Rome" "TZ forwarded"
has_line "$REC/run.args" "claude-code-sandbox" "image reference"

# ---------------------------------------------------------------------------
# W1b: Docker daemon not running
# ---------------------------------------------------------------------------
section "W1b: Docker daemon not running"
REC="$T/record/w1b"
FAKE_DOCKER_DOWN=1 run_claude "$REC" "$BARE_HOME" ""
rc=$?
exit_code_is "$rc" 1 "wrapper stops"
has_pattern "$REC/stderr.txt" 'Docker daemon is not running' "explains the daemon is down"
path_absent "$REC/run.args" "no container started"

# ---------------------------------------------------------------------------
# W1c: Linux host
# ---------------------------------------------------------------------------
section "W1c: Linux host does not query the macOS keychain"
REC="$T/record/w1c"
FAKE_UNAME_S=Linux run_claude "$REC" "$BARE_HOME" ""
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
path_absent "$REC/security.calls" "keychain not queried"

# ---------------------------------------------------------------------------
# W2: isolation from a native claude and its data
# ---------------------------------------------------------------------------
section "W2: configured host with a native claude"
REC="$T/record/w2"
rm -f "$NATIVE_CALLS"
run_claude "$REC" "$CONFIGURED_HOME" "$T/native"
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
has_no_pattern "$REC/run.args" "$CONFIGURED_HOME/\\.claude" "nothing from the host ~/.claude (settings, agents, CLAUDE.md...) mounted"
has_no_pattern "$REC/run.args" "$CONFIGURED_HOME/\\.claude\\.json" "host ~/.claude.json not mounted"
has_no_pattern "$REC/run.args" "$T/hooks" "host hook scripts not mounted"
has_no_pattern "$REC/run.args" 'HOST_CLAUDE_VERSION' "no host version passed"
path_absent "$NATIVE_CALLS" "the native claude is never executed"
has_no_pattern "$REC/security.calls" 'find-generic-password' "no credentials read from the keychain"
has_pattern "$REC/run.args" '^-v /[^:]+:/home/node/\.gitconfig:ro$' "filtered gitconfig mounted read-only"
if jq -e '(keys == ["companyAnnouncements"]) and (.companyAnnouncements | length == 1)' "$REC/settings.arg" >/dev/null 2>&1; then
  pass "--settings carries only the sandbox announcement (no statusLine, no host hooks)"
else
  fail "--settings carries only the sandbox announcement (no statusLine, no host hooks)"
fi

# ---------------------------------------------------------------------------
# W3: image build only when the image is absent
# ---------------------------------------------------------------------------
section "W3: image absent -> build"
REC="$T/record/w3"
FAKE_IMAGE_STATE=absent run_claude "$REC" "$BARE_HOME" ""
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
has_pattern "$REC/build.args" 'claude-code-sandbox' "image built under the sandbox name"
has_pattern "$REC/build.args" '^APT_PACKAGES=tzdata ' "build passes the apt packages from components.conf"
path_exists "$REC/run.args" "container run proceeded"

# ---------------------------------------------------------------------------
# W4: no CA bundle exported -> empty arg arrays must not trip `set -u`
# (bash 3.2, the macOS default, rejects expanding an empty array)
# ---------------------------------------------------------------------------
section "W4: CA export fails"
REC="$T/record/w4"
FAKE_CERTS_FAIL=1 run_claude "$REC" "$BARE_HOME" ""
rc=$?
exit_code_is "$rc" 0 "wrapper still succeeds"
path_exists "$REC/run.args" "container run proceeded"
has_no_pattern "$REC/run.args" 'ca-certificates\.crt' "no CA bundle mount"

# ---------------------------------------------------------------------------
# W5: the config dir is the sandbox's own: kept across runs, never rewritten
# ---------------------------------------------------------------------------
section "W5: config dir persistence"
STATE_HOME="$T/home-state"
STATE_CONFIG_DIR="$STATE_HOME/.secure-ai/claude-code/config"
mkdir -p "$STATE_CONFIG_DIR"
echo '{"model":"opus"}' > "$STATE_CONFIG_DIR/settings.json"
REC="$T/record/w5"
run_claude "$REC" "$STATE_HOME" ""
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
content_is "$STATE_CONFIG_DIR/settings.json" '{"model":"opus"}' "existing sandbox settings left untouched"
has_line "$REC/run.args" "-v $STATE_CONFIG_DIR:$STATE_CONFIG_DIR" "same dir mounted again"

# ---------------------------------------------------------------------------
# W6: wrappers started together share one config dir
# ---------------------------------------------------------------------------
section "W6: concurrent wrappers share one config dir"
RACE_HOME="$T/home-race"
RACE_CONFIG_DIR="$RACE_HOME/.secure-ai/claude-code/config"
mkdir -p "$RACE_HOME"
run_claude "$T/record/w6a" "$RACE_HOME" "" &
run_claude "$T/record/w6b" "$RACE_HOME" "" &
run_claude "$T/record/w6c" "$RACE_HOME" "" &
wait
for run in w6a w6b w6c; do
  has_line "$T/record/$run/run.args" "-v $RACE_CONFIG_DIR:$RACE_CONFIG_DIR" "$run mounts the shared config dir"
done

# ---------------------------------------------------------------------------
# E1: docker-entrypoint.sh (login hint, then hand over to claude)
# ---------------------------------------------------------------------------
# Runs the entrypoint with CLAUDE_CONFIG_DIR pointing at a fixture dir and a
# fake `claude` that records every call it receives.
ENTRYPOINT="$REPO_DIR/tools/claude-code/container/docker-entrypoint.sh"
mkdir -p "$T/entrypoint-bin"
cat > "$T/entrypoint-bin/claude" <<'FAKE'
#!/usr/bin/env bash
# Env: FAKE_CLAUDE_CALLS (call log file)
echo "call $*" >> "${FAKE_CLAUDE_CALLS:?}"
FAKE
chmod +x "$T/entrypoint-bin/claude"

# run_entrypoint <record-dir> <config-dir> [claude args...]
run_entrypoint() {
  local record="$1" config_dir="$2"
  shift 2
  mkdir -p "$record" "$config_dir"
  rm -f "$record"/claude.calls "$record"/stdout.txt "$record"/stderr.txt
  env CLAUDE_CONFIG_DIR="$config_dir" \
      FAKE_CLAUDE_CALLS="$record/claude.calls" \
      PATH="$T/entrypoint-bin:$PATH" \
      sh "$ENTRYPOINT" "$@" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

section "E1a: saved login -> no hint, arguments passed through"
REC="$T/record/e1a"
E_CONFIG="$T/econfig-a"
mkdir -p "$E_CONFIG"
echo '{"own":true}' > "$E_CONFIG/.credentials.json"
run_entrypoint "$REC" "$E_CONFIG" -p hello
rc=$?
exit_code_is "$rc" 0 "entrypoint succeeds"
has_no_pattern "$REC/stderr.txt" 'sign in' "no login hint when credentials exist"
content_is "$REC/claude.calls" "call -p hello" "claude called once, with the arguments only (no update, no version query)"
content_is "$E_CONFIG/.credentials.json" '{"own":true}' "credentials untouched"

section "E1b: no login yet -> hint, claude still starts"
REC="$T/record/e1b"
run_entrypoint "$REC" "$T/econfig-b"
rc=$?
exit_code_is "$rc" 0 "entrypoint still starts claude"
has_pattern "$REC/stderr.txt" 'sign in inside the container' "hint printed"
path_exists "$REC/claude.calls" "claude launched"

section "E1c: CLAUDE_CONFIG_DIR missing -> fail fast"
REC="$T/record/e1c"
mkdir -p "$REC"
env -u CLAUDE_CONFIG_DIR FAKE_CLAUDE_CALLS="$REC/claude.calls" PATH="$T/entrypoint-bin:$PATH" \
  sh "$ENTRYPOINT" >"$REC/stdout.txt" 2>"$REC/stderr.txt"
rc=$?
if [ "$rc" != 0 ]; then pass "entrypoint refuses to run"; else fail "entrypoint refuses to run (exit code 0)"; fi
path_absent "$REC/claude.calls" "claude not launched"

finish_tests
