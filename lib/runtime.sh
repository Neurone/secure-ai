#!/usr/bin/env bash

# Building blocks shared by the sandbox wrappers (tools/*/<tool>.sh). Each
# function fills a global the wrapper then hands to `docker run`, because bash
# 3.2 (the macOS default) has no namerefs.

OS="$(uname -s)"

# Sets TMPDIR_RUN to a fresh directory removed when the wrapper exits.
init_run_tmpdir() {
  TMPDIR_RUN="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_RUN"' EXIT
}

# Timezone. The base images have no local timezone configured, so without this
# the container clock defaults to UTC while the host shows local time.
# Sets TZ_ARGS.
detect_timezone_args() {
  local tz_value="${TZ:-}"
  if [ -z "$tz_value" ] && [ -f /etc/timezone ]; then
    tz_value="$(< /etc/timezone)"
  fi
  if [ -z "$tz_value" ] && [ -e /etc/localtime ]; then
    tz_value="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')"
  fi
  TZ_ARGS=()
  if [ -n "$tz_value" ]; then
    TZ_ARGS=(-e "TZ=$tz_value")
  else
    log_warn "could not determine host timezone; container clock will show UTC"
  fi
}

# CA certificates. The images have no ca-certificates package, so without this
# every HTTPS request inside the container fails with curl exit 77 ("error
# setting certificate file"). The host's trust store is mounted in rather
# than installing a generic one, so the container also trusts whatever
# corporate root CA (e.g. a TLS-inspecting proxy) the host already trusts.
# Needs TMPDIR_RUN and OS. Sets CA_BUNDLE_ARGS.
collect_ca_bundle_args() {
  local ca_bundle_tmp="$TMPDIR_RUN/ca-certificates.crt"
  local candidate
  CA_BUNDLE_ARGS=()
  case "$OS" in
    Darwin)
      if { security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain
           security find-certificate -a -p /Library/Keychains/System.keychain; } >"$ca_bundle_tmp" 2>/dev/null \
         && [ -s "$ca_bundle_tmp" ]; then
        CA_BUNDLE_ARGS=(-v "$ca_bundle_tmp:/etc/ssl/certs/ca-certificates.crt:ro")
      else
        rm -f "$ca_bundle_tmp"
        log_warn "could not export CA certificates from the macOS keychain; HTTPS requests inside the container may fail"
      fi
      ;;
    *)
      for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem; do
        if [ -s "$candidate" ]; then
          CA_BUNDLE_ARGS=(-v "$candidate:/etc/ssl/certs/ca-certificates.crt:ro")
          break
        fi
      done
      if [ "${#CA_BUNDLE_ARGS[@]}" -eq 0 ]; then
        log_warn "no host CA bundle found; HTTPS requests inside the container may fail"
      fi
      ;;
  esac
}

# On SELinux hosts (Fedora/RHEL and derivatives) bind mounts are inaccessible
# without relabelling. The suffix is only for the mounts that must be writable
# by the container (the project directory and the tool's own state
# directories): the flag relabels the host files recursively, so it must never
# be put on anything else. Needs OS. Sets MOUNT_SUFFIX.
detect_selinux_mount_suffix() {
  MOUNT_SUFFIX=""
  if [ "$OS" = "Linux" ] && command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    MOUNT_SUFFIX=":z"
  fi
}

# Removes every credential section from the git config file $1, including the
# per-URL ones such as [credential "https://github.com"] that
# `gh auth setup-git` writes: --remove-section only drops the exact name given.
remove_credential_sections() {
  local gitconfig_file="$1" section
  while IFS= read -r section; do
    git config --file "$gitconfig_file" --remove-section "$section"
  done < <(git config --file "$gitconfig_file" --get-regexp '^credential\.' | awk '{ sub(/\.[^.]*$/, "", $1); print $1 }' | sort -u)
}

# Carries the host git identity and aliases into the container. A filtered
# copy is mounted rather than the original: credential helpers configured on
# the host (osxkeychain, libsecret, gh) do not exist inside the image and would
# make any authenticating git command fail. Needs TMPDIR_RUN. Appends to
# MOUNT_ARGS.
append_filtered_gitconfig_mount() {
  local gitconfig_tmp="$TMPDIR_RUN/gitconfig"
  if [ -f "$HOME/.gitconfig" ]; then
    cp "$HOME/.gitconfig" "$gitconfig_tmp"
    remove_credential_sections "$gitconfig_tmp"
    MOUNT_ARGS+=(-v "$gitconfig_tmp:/home/node/.gitconfig:ro")
  fi
}

# Everything the wrappers share before their own `docker run` additions: the
# per-run temp dir, timezone, CA bundle and SELinux detection, then
#   MOUNT_ARGS      the project mount (at the same path as on the host) and
#                   the filtered gitconfig; wrappers append their own mounts
#   COMMON_RUN_ARGS the base `docker run` flags
# --user keeps files created in the project mount owned by the invoking user
# (which matters on Linux, where there is no UID remapping layer).
# --group-add 0 grants access to /home/node, whose contents are owned by
# node:0 with group permissions mirroring the owner's.
# Arrays are only expanded when non-empty: bash 3.2 (macOS default) treats
# expanding an empty array under set -u as an unbound-variable error.
prepare_sandbox_run() {
  local project_dir
  project_dir="$(pwd)"

  init_run_tmpdir
  detect_timezone_args
  collect_ca_bundle_args
  detect_selinux_mount_suffix

  MOUNT_ARGS=(-v "$project_dir:$project_dir$MOUNT_SUFFIX")
  append_filtered_gitconfig_mount

  COMMON_RUN_ARGS=(
    -it --rm
    --user "$(id -u):$(id -g)"
    --group-add 0
    -e HOME=/home/node
    -w "$project_dir"
  )
  if [ "${#TZ_ARGS[@]}" -gt 0 ]; then COMMON_RUN_ARGS+=("${TZ_ARGS[@]}"); fi
  if [ "${#CA_BUNDLE_ARGS[@]}" -gt 0 ]; then COMMON_RUN_ARGS+=("${CA_BUNDLE_ARGS[@]}"); fi
}
