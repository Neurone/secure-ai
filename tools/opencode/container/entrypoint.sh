#!/bin/sh
# Entrypoint for the opencode sandbox image. Runs under the image's /bin/sh
# (dash), so it stays POSIX.
#
# opencode.sh bind-mounts the sandbox's own opencode directories (config/data/
# state/cache) whole, shared by every sandbox instance. Nothing in them is
# touched here: they are the sandbox's own, like a native install's.

# The "you are in a sandbox" banner plugin, baked into the image at
# /opt/sandbox-banner. It is declared through OPENCODE_CONFIG_CONTENT -- a
# config document opencode loads on top of the others (plugins from every
# config source are unioned, so the user's plugin list is never shadowed) --
# rather than written into the mounted config dir, so it is not persisted
# into the sandbox's configuration.
set -u

banner_src="${SECURE_OPENCODE_BANNER_SRC:-/opt/sandbox-banner}"
if [ ! -d "$banner_src" ]; then
  echo "Error: sandbox banner source $banner_src not found in the image; the sandbox indicator would be missing, refusing to start" >&2
  exit 1
fi

# Merge with a content config the caller set itself (`docker run -e
# OPENCODE_CONFIG_CONTENT=...`): the banner is appended to its plugin list
# instead of replacing it, and unparseable content fails loudly rather than
# silently dropping the configuration.
existing_content="${OPENCODE_CONFIG_CONTENT:-}"
[ -n "$existing_content" ] || existing_content='{}'
if ! merged_content="$(printf '%s' "$existing_content" \
    | jq -c --arg banner "$banner_src" \
        'if ((.plugins // []) | index($banner)) then . else .plugins = ((.plugins // []) + [$banner]) end')"; then
  echo "Error: could not merge the sandbox banner plugin into OPENCODE_CONFIG_CONTENT; refusing to start (jq reported the problem above)" >&2
  exit 1
fi
export OPENCODE_CONFIG_CONTENT="$merged_content"

# Several native opencode instances on one machine share one background
# service. Containers can't: each has its own network and PID namespace, and
# the service only sees the project directories mounted into its own
# container. Left alone, each new container would take over the shared
# registration in state/ and stop the service of the one before. So every
# instance runs with its own private server (--standalone), which leaves the
# registration alone, while config, data (sessions) and state stay shared.
# Only commands that offer the flag get it (their --help lists it as a flag of
# its own, not just in another flag's description), and not when the caller
# already picked a server.
wants_standalone=1
for arg in "$@"; do
  case "$arg" in
    --standalone | --standalone=* | --server | --server=*) wants_standalone=0 ;;
  esac
done

if [ "$wants_standalone" = 1 ]; then
  case "${1:-}" in
    "" | -*)
      set -- --standalone "$@"
      ;;
    *)
      if [ -d "$1" ]; then
        set -- --standalone "$@"
      elif opencode "$1" --help 2>/dev/null | grep -Eq '^[[:space:]]+--standalone[[:space:]]'; then
        subcommand="$1"
        shift
        set -- "$subcommand" --standalone "$@"
      fi
      ;;
  esac
fi

# An asynchronous command gets its stdin redirected from /dev/null by POSIX
# shells (both dash here and bash on a test host), which would cut the TUI off
# from the terminal: it writes its queries (background/foreground color,
# capabilities, mouse) to the pty but never reads the replies, which the tty
# line discipline then echoes back as raw escape sequences. fd 3 keeps the
# entrypoint's own stdin across that redirect; opencode reads it and closes
# the extra descriptor.
exec 3<&0
opencode "$@" <&3 3<&- &
child=$!
trap 'kill -TERM "$child" 2>/dev/null' TERM
trap 'kill -INT "$child" 2>/dev/null' INT

status=0
while :; do
  wait "$child"
  status=$?
  # A trapped signal makes wait return 128+signum before the child has
  # necessarily exited: re-wait while it is still running.
  if [ "$status" -gt 128 ] && kill -0 "$child" 2>/dev/null; then
    continue
  fi
  # The child may have exited in the same moment the signal was delivered:
  # try to recover its real exit status (127 means it is no longer waitable).
  if [ "$status" -gt 128 ]; then
    wait "$child" 2>/dev/null
    real_status=$?
    if [ "$real_status" -ne 127 ]; then
      status=$real_status
    fi
  fi
  break
done

exit "$status"
