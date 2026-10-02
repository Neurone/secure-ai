#!/usr/bin/env bash
# Tests for the opencode sandbox: tools/opencode/opencode.sh (the wrapper), its
# image build/version logic and its container entrypoint, driven with the fake
# tools of lib/harness.sh. The sandbox must stay isolated from any native
# opencode: S1 and S7 assert that nothing of it reaches the container.
#
# Usage: bash tests/test-opencode.sh

# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# run_oc <record-dir> [wrapper args...]
# WRAPPER_HOME overrides the default $T/home fixture home.
run_oc() {
  local record="$1"
  shift
  run_wrapper "$OPENCODE_WRAPPER" "$record" "${WRAPPER_HOME:-$T/home}" "" "$@"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

mkdir -p \
  "$T/home/.config/opencode/agents" \
  "$T/home/.config/opencode/cfgplugin" \
  "$T/home/.local/share/opencode/log" \
  "$T/home/.local/state/opencode/locks" \
  "$T/home/.cache/opencode/npm" \
  "$T/plugins"

# The tests run the wrapper on a faked Darwin host (lib/harness.sh), so no
# SELinux relabelling applies.
MOUNT_SUFFIX=""

# --- native opencode fixtures: nothing here may reach the container ----------
# Global config declaring plugins: an external dir, a {package, options}
# object entry inside the config dir, and a path that does not exist.
cat > "$T/home/.config/opencode/opencode.json" <<EOF
{
  "plugins": [
    "$T/plugins/ext-global",
    {"package": "$T/home/.config/opencode/cfgplugin", "options": {"opt": 1}},
    "$T/plugins/missing-plugin"
  ]
}
EOF
echo "cfg plugin" > "$T/home/.config/opencode/cfgplugin/index.js"
echo "service pw" > "$T/home/.config/opencode/service.json"
# The CLI/TUI settings file (theme, keybinds, plugin list).
cat > "$T/home/.config/opencode/cli.json" <<'EOF'
{
  "theme": "tokyo-night"
}
EOF
echo "agent" > "$T/home/.config/opencode/agents/agent1.md"

# Data dir: the credentials file and the session database.
echo "creds" > "$T/home/.local/share/opencode/auth.json"
echo "db" > "$T/home/.local/share/opencode/opencode.db"
echo "wal" > "$T/home/.local/share/opencode/opencode.db-wal"
echo "log" > "$T/home/.local/share/opencode/log/session1.log"

# State dir: the background-service registration (with its pty handoff
# sidecar), the file locks, and an ordinary state file.
echo "service pw" > "$T/home/.local/state/opencode/service.json"
echo "pty" > "$T/home/.local/state/opencode/service.json.pty-handoff"
echo "kv" > "$T/home/.local/state/opencode/kv.json"
echo "lock" > "$T/home/.local/state/opencode/locks/l1"

echo "npm cache" > "$T/home/.cache/opencode/npm/pkgsomeplugin"

cat > "$T/home/.gitconfig" <<'EOF'
[user]
	name = Test User
	email = test@example.com
[credential]
	helper = osxkeychain
EOF

# --- project fixture, JSONC (comments + trailing commas) ---------------------
# It declares plugins by absolute path too, which the wrapper must not mount.
cat > "$T/project/opencode.jsonc" <<EOF
{
  // project-level config
  "plugin": [
    "$T/plugins/ext-global",
    "$T/plugins/proj-ext", /* block comment mid-array */
    "./relative-plugin.js", // relative entries need no mount
    "@scope/npm-plugin", // npm names install into the cache dir; nothing to mount
  ],
  "provider": {
    "lmstudio": {
      "options": {
        "baseURL": "http://host.docker.internal:1234/v1 // not a comment /* nor this */",
      },
    },
  },
}
EOF
echo "main" > "$T/project/main.txt"

# --- external plugins (absolute paths outside config + project dirs) --------
mkdir -p "$T/plugins/ext-global" "$T/plugins/proj-ext"
echo "global ext" > "$T/plugins/ext-global/index.js"
echo "proj ext" > "$T/plugins/proj-ext/index.js"
echo "cfg ext" > "$T/plugins/ext-config.js"

# --- OPENCODE_CONFIG fixture: extra config file outside both dirs -----------
cat > "$T/custom-oc.json" <<EOF
{
  "plugin": ["$T/plugins/ext-config.js"]
}
EOF

# ---------------------------------------------------------------------------
# S1: up-to-date image -> plain run, full mount allowlist, nothing native
# ---------------------------------------------------------------------------
echo "=== S1: up-to-date image, full mount allowlist ==="
REC="$T/record/s1"
SANDBOX="$T/home/.secure-ai/opencode"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG='' run_oc "$REC" --version
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
if [ -e "$REC/build.args" ]; then fail "no image build"; else pass "no image build"; fi
has_line "$REC/run.args" "-v $T/project:$T/project$MOUNT_SUFFIX" "project dir mounted"
has_line "$REC/run.args" "-v $SANDBOX/config:/home/node/.config/opencode$MOUNT_SUFFIX" "sandbox config dir mounted whole"
has_line "$REC/run.args" "-v $SANDBOX/data:/home/node/.local/share/opencode$MOUNT_SUFFIX" "sandbox data dir mounted whole"
has_line "$REC/run.args" "-v $SANDBOX/state:/home/node/.local/state/opencode$MOUNT_SUFFIX" "sandbox state dir mounted whole"
has_line "$REC/run.args" "-v $SANDBOX/cache:/home/node/.cache/opencode$MOUNT_SUFFIX" "sandbox cache dir mounted whole"
for d in config data state cache; do
  if [ -d "$SANDBOX/$d" ]; then pass "sandbox $d dir created on the host"; else fail "sandbox $d dir created on the host"; fi
done
# Isolation: the native opencode dirs, the XDG decoys, plugin paths declared
# in configs and OPENCODE_CONFIG never reach the container.
has_no_pattern "$REC/run.args" "$T/home/\.(config|local|cache)" "no native opencode dir mounted"
has_no_pattern "$REC/run.args" "$T/xdg-decoy" "host XDG_* variables ignored"
has_no_pattern "$REC/run.args" "$T/plugins" "plugin paths from configs not mounted"
has_no_pattern "$REC/run.args" 'OPENCODE_CONFIG=' "OPENCODE_CONFIG not forwarded"
has_no_pattern "$REC/stderr.txt" 'lugin' "no plugin manifest or warnings"
has_line "$REC/run.args" "-e TZ=Europe/Rome" "TZ forwarded"
has_line "$REC/run.args" "-e HOME=/home/node" "HOME overridden"
has_line "$REC/run.args" "-e OPENCODE_LMSTUDIO_BASEURL=http://host.docker.internal:1234/v1" "OPENCODE_LMSTUDIO_BASEURL set"
has_line "$REC/run.args" "--add-host=host.docker.internal:host-gateway" "host.docker.internal add-host"
has_line "$REC/run.args" "opencode-sandbox:current" "image reference"
has_line "$REC/run.args" "--version" "arguments passed through"
has_pattern "$REC/run.args" '^-v /[^:]+:/home/node/\.gitconfig:ro$' "filtered gitconfig mounted read-only"
content_is "$REC/gitconfig-credential-count" "0" "gitconfig credential section stripped"
# The mount list is the allowlist: exactly the expected set, nothing else.
has_pattern "$REC/run.args" '^-v .*ca-certificates\.crt:/etc/ssl/certs/ca-certificates\.crt:ro$' "host CA bundle mounted (from the macOS keychain)"
EXPECTED_MOUNTS=7
ACTUAL_MOUNTS=$(grep -c '^-v ' "$REC/run.args")
if [ "$ACTUAL_MOUNTS" = "$EXPECTED_MOUNTS" ]; then
  pass "mount list is exactly the expected allowlist ($ACTUAL_MOUNTS mounts)"
else
  fail "mount list is exactly the expected allowlist (got $ACTUAL_MOUNTS, expected $EXPECTED_MOUNTS)"
fi

# ---------------------------------------------------------------------------
# S2: newer upstream release -> build then run (numeric tag sort check)
# ---------------------------------------------------------------------------
echo "=== S2: newer upstream release, build then run ==="
REC="$T/record/s2"
FAKE_TAGS_V2="v2.0.9 v2.0.15 v2.1.0" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG='' run_oc "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_line "$REC/build.args" "OPENCODE_TAG=v2.1.0" "highest tag picked (numeric sort, not lexical)"
has_pattern "$REC/build.args" '^APT_PACKAGES=jq tzdata ' "build passes the apt packages from components.conf"
has_line "$REC/tag.args" "opencode-sandbox:v2.1.0" "built image tagged with release tag"
has_line "$REC/tag.args" "opencode-sandbox:current" ":current repointed"
if [ -e "$REC/run.args" ]; then pass "container run proceeded"; else fail "container run proceeded"; fi

# ---------------------------------------------------------------------------
# S3: offline, cached image available -> continue with cache
# ---------------------------------------------------------------------------
echo "=== S3: offline with cached image ==="
REC="$T/record/s3"
FAKE_TAGS_V2='' FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=1 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG='' run_oc "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "could not resolve the latest stable" "offline warning printed"
has_pattern "$REC/stderr.txt" "Continuing with cached build" "fell back to cached image"
if [ -e "$REC/run.args" ]; then pass "container run proceeded"; else fail "container run proceeded"; fi

# ---------------------------------------------------------------------------
# S4: offline, no image -> clean error
# ---------------------------------------------------------------------------
echo "=== S4: offline, no image ==="
REC="$T/record/s4"
FAKE_TAGS_V2='' FAKE_IMAGE_STATE=absent FAKE_GIT_FAIL=1 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG='' run_oc "$REC"
rc=$?
if [ "$rc" = 1 ]; then pass "exit 1"; else fail "exit 1 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "no previously built opencode-sandbox image" "clean error message"
if [ -e "$REC/run.args" ]; then fail "no container run"; else pass "no container run"; fi

# ---------------------------------------------------------------------------
# S5: online but no stable tag on the line, cached image -> continue
# ---------------------------------------------------------------------------
echo "=== S5: no stable v2 tag, cached image ==="
REC="$T/record/s5"
FAKE_TAGS_V2='' FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG='' run_oc "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "could not resolve the latest stable" "warning printed"
has_pattern "$REC/stderr.txt" "Continuing with cached build" "fell back to cached image"
if [ -e "$REC/run.args" ]; then pass "container run proceeded"; else fail "container run proceeded"; fi

# ---------------------------------------------------------------------------
# S6: newer major available -> notice only
# ---------------------------------------------------------------------------
echo "=== S6: newer major available, notice only ==="
REC="$T/record/s6"
FAKE_TAGS_V2="v2.0.14" FAKE_TAGS_V3="v3.1.0" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG='' run_oc "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "opencode v3\.1\.0 is available upstream" "newer-major notice printed"
if [ -e "$REC/build.args" ]; then fail "no build for the newer major"; else pass "no build for the newer major"; fi

echo "=== S6b: a launch asks upstream for its tags once, whatever the lines it looks at ==="
content_is <(wc -l < "$REC/git.calls" | tr -d ' ') "1" "one ls-remote round trip"

# ---------------------------------------------------------------------------
# S7: a host OPENCODE_CONFIG belongs to the native install -> ignored entirely
# ---------------------------------------------------------------------------
echo "=== S7: OPENCODE_CONFIG ignored ==="
REC="$T/record/s7"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG="$T/custom-oc.json" run_oc "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_no_pattern "$REC/run.args" 'custom-oc\.json' "OPENCODE_CONFIG file not mounted"
has_no_pattern "$REC/run.args" 'OPENCODE_CONFIG=' "OPENCODE_CONFIG not forwarded"
has_no_pattern "$REC/run.args" "$T/plugins" "its plugins not mounted"

# ---------------------------------------------------------------------------
# S8: build failure, cached image -> fallback
# ---------------------------------------------------------------------------
echo "=== S8: build failure with cached image ==="
REC="$T/record/s8"
FAKE_TAGS_V2="v2.0.15" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=1 \
  OPENCODE_CONFIG='' run_oc "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "falling back to the last successful local build" "build-failure fallback warning"
if [ -e "$REC/run.args" ]; then pass "container run proceeded"; else fail "container run proceeded"; fi

# ---------------------------------------------------------------------------
# S9: build failure, no image -> clean error
# ---------------------------------------------------------------------------
echo "=== S9: build failure, no image ==="
REC="$T/record/s9"
FAKE_TAGS_V2="v2.0.15" FAKE_IMAGE_STATE=absent FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=1 \
  OPENCODE_CONFIG='' run_oc "$REC"
rc=$?
if [ "$rc" = 1 ]; then pass "exit 1"; else fail "exit 1 (got $rc)"; fi
has_pattern "$REC/stderr.txt" "no previously built opencode-sandbox image" "clean error message"
if [ -e "$REC/run.args" ]; then fail "no container run"; else pass "no container run"; fi

# ---------------------------------------------------------------------------
# S15: the sandbox dirs are the sandbox's own: kept across runs, and shared by
# wrappers started together
# ---------------------------------------------------------------------------
echo "=== S15: sandbox dirs persist and are shared ==="
PERSIST_HOME="$T/home-persist"
PERSIST_SANDBOX="$PERSIST_HOME/.secure-ai/opencode"
mkdir -p "$PERSIST_SANDBOX/config" "$PERSIST_SANDBOX/state"
echo '{"theme":"x"}' > "$PERSIST_SANDBOX/config/cli.json"
echo "model" > "$PERSIST_SANDBOX/state/model.json"
REC="$T/record/s15"
FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
  OPENCODE_CONFIG='' WRAPPER_HOME="$PERSIST_HOME" run_oc "$REC"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
content_is "$PERSIST_SANDBOX/config/cli.json" '{"theme":"x"}' "existing sandbox config left untouched"
content_is "$PERSIST_SANDBOX/state/model.json" "model" "existing sandbox state left untouched"

RACE_HOME="$T/home-race"
mkdir -p "$RACE_HOME"
for run in a b c; do
  FAKE_TAGS_V2="v2.0.14" FAKE_IMAGE_VERSION="v2.0.14" FAKE_GIT_FAIL=0 FAKE_BUILD_FAIL=0 \
    OPENCODE_CONFIG='' WRAPPER_HOME="$RACE_HOME" run_oc "$T/record/s15$run" &
done
wait
for run in a b c; do
  for d in config data state cache; do
    has_pattern "$T/record/s15$run/run.args" "^-v $RACE_HOME/\.secure-ai/opencode/$d:" "wrapper $run mounts the shared $d dir"
  done
done

# ---------------------------------------------------------------------------
# S16: container entrypoint: sandbox state left alone, banner declaration
# through OPENCODE_CONFIG_CONTENT, argument passthrough, stdin inheritance,
# signal forwarding, status propagation
# ---------------------------------------------------------------------------
echo "=== S16: entrypoint state, banner, run loop, signals ==="
ENTRYPOINT="$REPO_DIR/tools/opencode/container/entrypoint.sh"
T16="$T/entry"
mkdir -p "$T16/home/.config/opencode" \
         "$T16/home/.local/share/opencode" \
         "$T16/home/.local/state/opencode/locks" \
         "$T16/home/.cache/opencode" \
         "$T16/bin" "$T16/banner-src" "$T16/nohome/home" \
         "$T16/record/s16" "$T16/record/s16content" \
         "$T16/record/s16sig" "$T16/record/s16nobanner" "$T16/record/s16stdin"

# The state dir as left by an earlier sandbox run: the service registration
# in both channel forms, its sidecars, the locks, and an ordinary file. The
# entrypoint must leave all of it alone (it is shared with other instances).
echo "host reg"  > "$T16/home/.local/state/opencode/service.json"
echo "host reg2" > "$T16/home/.local/state/opencode/service-2.json"
echo "sidecar"   > "$T16/home/.local/state/opencode/service.json.pty-handoff"
echo "tmp"       > "$T16/home/.local/state/opencode/service.json.tmp"
echo "lock"      > "$T16/home/.local/state/opencode/locks/l1"
echo "kv"        > "$T16/home/.local/state/opencode/kv.json"
# The config dir: the service CONFIG (hostname/port/password) and the CLI
# settings file.
echo "pw" > "$T16/home/.config/opencode/service.json"
printf '{"theme":"host-theme"}\n' > "$T16/home/.config/opencode/cli.json"
# The banner as baked into the image; the test points the entrypoint at it.
echo "idx" > "$T16/banner-src/index.js"
echo "tui" > "$T16/banner-src/tui.js"

cat > "$T16/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
# `<command> --help` is how the entrypoint finds out whether a command has the
# --standalone flag; FAKE_OPENCODE_NO_STANDALONE_FLAG=1 makes it lack it.
if [ "${2:-}" = "--help" ]; then
  [ "${FAKE_OPENCODE_NO_STANDALONE_FLAG:-0}" = 1 ] || echo "  --standalone    Run with a private server"
  # Every real command's help mentions the flag in this description too.
  echo "  --print-logs    Print logs to stderr (server logs require --standalone)"
  exit 0
fi
echo "opencode-args: $*"
printf 'running' > "${FAKE_OPENCODE_MARKER:-/dev/null}"
if [ -n "${FAKE_OPENCODE_REGISTER:-}" ]; then
  echo "container reg" > "$FAKE_OPENCODE_REGISTER"
fi
if [ -n "${FAKE_OPENCODE_ENV_RECORD:-}" ]; then
  env | grep '^OPENCODE_CONFIG_CONTENT=' > "$FAKE_OPENCODE_ENV_RECORD"
fi
if [ "${FAKE_OPENCODE_STDIN:-}" = 1 ]; then
  IFS= read -r line && echo "child-stdin:$line"
fi
if [ "${FAKE_OPENCODE_EXIT:-}" = 1 ]; then
  exit "${FAKE_OPENCODE_EXIT_CODE:-0}"
fi
trap 'echo "child-term"; exit 143' TERM
trap 'echo "child-int"; exit 130' INT
while :; do sleep 1; done
FAKE
chmod +x "$T16/bin/opencode"

# A normal run: the child re-registers the service (as the real opencode
# would), then exits; the entrypoint must propagate 0 and leave the state as
# the child left it.
FAKE_OPENCODE_EXIT=1 FAKE_OPENCODE_EXIT_CODE=0 \
FAKE_OPENCODE_MARKER="$T16/child-marker" \
FAKE_OPENCODE_REGISTER="$T16/home/.local/state/opencode/service.json" \
FAKE_OPENCODE_ENV_RECORD="$T16/record/s16/content-env" \
SECURE_OPENCODE_BANNER_SRC="$T16/banner-src" \
  env HOME="$T16/home" PATH="$T16/bin:$PATH" \
  sh "$ENTRYPOINT" run --print-logs >"$T16/record/s16/stdout.txt" 2>"$T16/record/s16/stderr.txt"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0"; else fail "exit 0 (got $rc)"; fi
has_line "$T16/record/s16/stdout.txt" "opencode-args: run --standalone --print-logs" "arguments passed through to opencode, with a private server"
content_is "$T16/home/.local/state/opencode/service.json" "container reg" "service registration left as the child wrote it (no cleanup)"
for f in service-2.json service.json.pty-handoff service.json.tmp locks/l1; do
  if [ -e "$T16/home/.local/state/opencode/$f" ]; then
    pass "state file untouched: $f"
  else
    fail "state file untouched: $f"
  fi
done
content_is "$T16/home/.local/state/opencode/kv.json" "kv" "ordinary state file kept"
content_is "$T16/home/.config/opencode/service.json" "pw" "service config (config dir) kept"
content_is "$T16/home/.config/opencode/cli.json" '{"theme":"host-theme"}' "cli.json untouched"
# The config dir is the host's (mounted whole): the banner must not be
# written into it, or a native opencode would show the sandbox banner too.
if [ -e "$T16/home/.config/opencode/plugins/sandbox-banner" ] || [ -e "$T16/home/.config/opencode/plugins/.sandbox-banner" ]; then
  fail "no banner file written into the config dir"
else
  pass "no banner file written into the config dir"
fi
content_is "$T16/record/s16/content-env" "OPENCODE_CONFIG_CONTENT={\"plugins\":[\"$T16/banner-src\"]}" "banner declared through OPENCODE_CONFIG_CONTENT"
has_no_pattern "$T16/record/s16/stderr.txt" "Error" "no errors on a clean start"

# The child must inherit the entrypoint's stdin: a POSIX shell redirects an
# asynchronous command from /dev/null, which would leave the TUI unable to
# read a single terminal reply (the tty then echoes the replies back as raw
# escape sequences, and mouse reports with them).
FAKE_OPENCODE_EXIT=1 FAKE_OPENCODE_EXIT_CODE=0 FAKE_OPENCODE_STDIN=1 \
SECURE_OPENCODE_BANNER_SRC="$T16/banner-src" \
  env HOME="$T16/home" PATH="$T16/bin:$PATH" \
  sh "$ENTRYPOINT" run <<< "hello-stdin" \
  >"$T16/record/s16stdin/stdout.txt" 2>"$T16/record/s16stdin/stderr.txt"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0 with a piped stdin"; else fail "exit 0 with a piped stdin (got $rc)"; fi
has_line "$T16/record/s16stdin/stdout.txt" "child-stdin:hello-stdin" "child inherits the entrypoint's stdin"

# A content config the caller set itself (`docker run -e
# OPENCODE_CONFIG_CONTENT=...`) must survive: the banner is appended to its
# plugin list, never substituted for it.
FAKE_OPENCODE_EXIT=1 FAKE_OPENCODE_MARKER='' \
FAKE_OPENCODE_ENV_RECORD="$T16/record/s16content/content-env" \
SECURE_OPENCODE_BANNER_SRC="$T16/banner-src" \
  env HOME="$T16/home" PATH="$T16/bin:$PATH" \
      OPENCODE_CONFIG_CONTENT='{"plugins":["/host/plugin"],"theme":"x"}' \
  sh "$ENTRYPOINT" serve >"$T16/record/s16content/stdout.txt" 2>"$T16/record/s16content/stderr.txt"
rc=$?
if [ "$rc" = 0 ]; then pass "exit 0 with a caller-provided OPENCODE_CONFIG_CONTENT"; else fail "exit 0 with a caller-provided OPENCODE_CONFIG_CONTENT (got $rc)"; fi
expected_content="OPENCODE_CONFIG_CONTENT={\"plugins\":[\"/host/plugin\",\"$T16/banner-src\"],\"theme\":\"x\"}"
content_is "$T16/record/s16content/content-env" "$expected_content" "caller content config kept, banner appended"
has_no_pattern "$T16/record/s16content/stderr.txt" "Error" "no errors when merging the banner"

# Signal forwarding: the entrypoint is running with a child that stays up
# until signalled; SIGTERM on the entrypoint must reach the child, and the
# child's status (143) must come back as the entrypoint's exit code.
rm -f "$T16/child-marker"
FAKE_OPENCODE_MARKER="$T16/child-marker" \
FAKE_OPENCODE_REGISTER="$T16/home/.local/state/opencode/service.json" \
SECURE_OPENCODE_BANNER_SRC="$T16/banner-src" \
  env HOME="$T16/home" PATH="$T16/bin:$PATH" \
  sh "$ENTRYPOINT" run --slow >"$T16/record/s16sig/stdout.txt" 2>"$T16/record/s16sig/stderr.txt" &
entry_pid=$!
i=0
while [ ! -f "$T16/child-marker" ] && [ "$i" -lt 100 ]; do
  i=$((i + 1))
  sleep 0.1
done
if [ -f "$T16/child-marker" ]; then pass "child came up"; else fail "child came up"; fi
kill -TERM "$entry_pid"
wait "$entry_pid"
rc=$?
if [ "$rc" = 143 ]; then
  pass "SIGTERM forwarded, child status 143 propagated"
else
  fail "SIGTERM forwarded, child status 143 propagated (got $rc)"
fi
has_pattern "$T16/record/s16sig/stdout.txt" "child-term" "child received the signal"
content_is "$T16/home/.local/state/opencode/service.json" "container reg" "no cleanup of the child's registration after the signal"

# A banner source that is not there (a corrupted image): the sandbox
# indicator would be missing, so the entrypoint refuses to start.
FAKE_OPENCODE_EXIT=1 \
  env HOME="$T16/nohome/home" PATH="$T16/bin:$PATH" \
  SECURE_OPENCODE_BANNER_SRC="$T16/no-such-banner" \
  sh "$ENTRYPOINT" run >"$T16/record/s16nobanner/stdout.txt" 2>"$T16/record/s16nobanner/stderr.txt"
rc=$?
if [ "$rc" = 1 ]; then pass "exit 1 when the banner source is missing"; else fail "exit 1 when the banner source is missing (got $rc)"; fi
has_pattern "$T16/record/s16nobanner/stderr.txt" "sandbox banner source" "clear refusal message"

# Each instance runs a private server (--standalone) when the command has the
# flag, so concurrent containers don't take over each other's background
# service; the caller's own choice of server is respected.
echo "=== S17: private server per instance ==="
entrypoint_args_for() {
  local record="$T16/record/s17"
  mkdir -p "$record"
  FAKE_OPENCODE_EXIT=1 SECURE_OPENCODE_BANNER_SRC="$T16/banner-src" \
    env HOME="$T16/home" PATH="$T16/bin:$PATH" \
    sh "$ENTRYPOINT" "$@" 2>"$record/stderr.txt" | grep '^opencode-args:'
}
content_is <(entrypoint_args_for) "opencode-args: --standalone" "no arguments: the TUI gets a private server"
content_is <(entrypoint_args_for -c) "opencode-args: --standalone -c" "root flags: flag put in front"
content_is <(entrypoint_args_for "$T16/banner-src") "opencode-args: --standalone $T16/banner-src" "directory argument: flag put in front"
content_is <(entrypoint_args_for run hello) "opencode-args: run --standalone hello" "run: flag put after the subcommand"
content_is <(FAKE_OPENCODE_NO_STANDALONE_FLAG=1 entrypoint_args_for auth list) "opencode-args: auth list" "command without the flag: left alone"
content_is <(entrypoint_args_for --server http://example.test) "opencode-args: --server http://example.test" "explicit --server: left alone"
content_is <(entrypoint_args_for run --standalone) "opencode-args: run --standalone" "explicit --standalone: not repeated"

finish_tests
