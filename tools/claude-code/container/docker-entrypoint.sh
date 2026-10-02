#!/bin/sh
set -e

# CLAUDE_CONFIG_DIR is the host directory claude.sh mounts for the sandbox's
# own settings and login, shared by every container; it has nothing to do with
# a native claude install. The hint only fires while no login has been saved
# there yet.
CREDENTIALS_FILE="${CLAUDE_CONFIG_DIR:?}/.credentials.json"

if [ ! -f "$CREDENTIALS_FILE" ]; then
  echo "No saved login found: sign in inside the container; it will be remembered for the next runs." >&2
fi

exec claude "$@"
