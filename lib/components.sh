#!/usr/bin/env bash

# Container components: the apt and npm packages installed in each tool's
# sandbox image. The defaults are tracked in tools/<tool>/components.conf:
#   <category> <package> [required]
# and each user's changes live in an overlay, $TOOL_STATE_DIR/components.conf:
#   add <category> <package>
#   remove <category> <package>
# The effective list is (defaults + adds) - removes; 'required' packages are
# never removed. Everything here needs TOOL_DIR and TOOL_STATE_DIR, set by the
# tool's tool.sh, and lib/log.sh and lib/common.sh (require_file) loaded.
#
# An entry is a "<category> <package> <status>" line, with status one of
# required, default, added or removed (a default dropped by the overlay).

COMPONENT_CATEGORIES="apt npm"
# The first character is never '-' so a package can't be taken for an option;
# a leading '@' allows scoped npm packages.
COMPONENT_PACKAGE_REGEX='^@?[A-Za-z0-9][A-Za-z0-9.+:@/_=~-]*$'

# Set by add_components / remove_components / reset_components: 1 when the
# overlay was modified.
COMPONENTS_CHANGED=0
# Set by read_package_arguments: the validated packages, one per line.
COMPONENT_PACKAGE_LIST=""
# Set by resolve_removals: the "<package> <status>" lines to remove.
COMPONENT_REMOVALS=""
# Set by component_build_args, for `docker build`.
COMPONENT_BUILD_ARGS=()

# Exits with $2, prefixed by the file position $1 when it is not empty.
fail_component() {
  log_error "${1:+$1: }$2"
  exit 1
}

is_component_category() {
  local known_category
  for known_category in $COMPONENT_CATEGORIES; do
    [ "$1" = "$known_category" ] && return 0
  done
  return 1
}

require_component_category() {
  is_component_category "$2" ||
    fail_component "$1" "unknown category '$2' (expected one of: ${COMPONENT_CATEGORIES// /, })"
}

require_component_package() {
  [[ $2 =~ $COMPONENT_PACKAGE_REGEX ]] || fail_component "$1" "invalid package name '$2'"
}

# Prints the non-blank, comment-free lines of file $1 as "<line number> <line>".
conf_lines() {
  awk '{ sub(/#.*/, "") } NF { print FNR, $0 }' "$1"
}

# True when the multi-line text $1 holds the line $2.
contains_line() {
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

component_overlay_file() {
  printf '%s\n' "$TOOL_STATE_DIR/components.conf"
}

# Prints the entries of the tool: its defaults, then the overlay's additions.
# Exits 1 on a malformed line in either file.
component_entries() {
  local defaults_file="$TOOL_DIR/components.conf"
  local overlay_file
  overlay_file="$(component_overlay_file)"
  local line_number category package flag extra action
  local defaults="" adds="" removes="" entries=""

  require_file "$defaults_file" "components file"
  while read -r line_number category package flag extra; do
    require_component_category "$defaults_file:$line_number" "$category"
    require_component_package "$defaults_file:$line_number" "$package"
    if [ -n "$extra" ] || { [ -n "$flag" ] && [ "$flag" != "required" ]; }; then
      fail_component "$defaults_file:$line_number" "expected '<category> <package> [required]'"
    fi
    defaults="$defaults$category $package ${flag:-default}"$'\n'
  done < <(conf_lines "$defaults_file")

  if [ -f "$overlay_file" ]; then
    while read -r line_number action category package extra; do
      require_component_category "$overlay_file:$line_number" "$category"
      require_component_package "$overlay_file:$line_number" "$package"
      case "$action" in
        add) adds="$adds$category $package"$'\n' ;;
        remove) removes="$removes$category $package"$'\n' ;;
        *) fail_component "$overlay_file:$line_number" "expected 'add|remove <category> <package>'" ;;
      esac
      [ -z "$extra" ] || fail_component "$overlay_file:$line_number" "expected 'add|remove <category> <package>'"
    done < <(conf_lines "$overlay_file")
  fi

  while read -r category package flag; do
    [ -n "$category" ] || continue
    if contains_line "$removes" "$category $package"; then
      if [ "$flag" = "required" ]; then
        log_warn "$overlay_file removes the required package '$package'; keeping it."
      else
        flag="removed"
      fi
    fi
    entries="$entries$category $package $flag"$'\n'
  done <<< "$defaults"

  while read -r category package; do
    [ -n "$category" ] || continue
    [ -n "$(component_status "$entries" "$category" "$package")" ] ||
      entries="$entries$category $package added"$'\n'
  done <<< "$adds"

  printf '%s' "$entries"
}

# Prints the packages of category $2 in the entries $1 that end up in the image.
entries_to_install() {
  printf '%s' "$1" | awk -v category="$2" '$1 == category && $3 != "removed" { print $2 }'
}

# Sets COMPONENT_BUILD_ARGS to the --build-arg flags carrying each category's
# packages (APT_PACKAGES, NPM_PACKAGES), space-separated.
component_build_args() {
  local entries category packages
  entries="$(component_entries)" || exit 1
  COMPONENT_BUILD_ARGS=()
  for category in $COMPONENT_CATEGORIES; do
    packages="$(entries_to_install "$entries" "$category" | paste -sd ' ' -)"
    COMPONENT_BUILD_ARGS+=(--build-arg "$(printf '%s' "$category" | tr '[:lower:]' '[:upper:]')_PACKAGES=$packages")
  done
}

# Prints each package of the arguments on its own line, splitting comma
# separated lists and dropping duplicates.
split_package_list() {
  printf '%s\n' "$@" | tr ',' '\n' | awk 'NF && !seen[$0]++'
}

# npm package name without its @version: cypress@15.0.0 -> cypress,
# @scope/pkg@1.0.0 -> @scope/pkg.
npm_package_name() {
  local scope="" name="$1"
  case "$name" in
    @*)
      scope="@"
      name="${name#@}"
      ;;
  esac
  printf '%s%s\n' "$scope" "${name%%@*}"
}

# Prints the status of package $3 of category $2 in the entries $1, nothing if
# it is not listed.
component_status() {
  printf '%s' "$1" | awk -v category="$2" -v package="$3" '$1 == category && $2 == package { print $3 }'
}

# Prints "<package> <status>" for the package of category $2 in the entries $1
# that $3 names: an exact match, or for npm the name before '@version'.
find_installed_component() {
  local entries="$1" category="$2" query="$3"
  local entry_category package status name_match=""
  while read -r entry_category package status; do
    [ "$entry_category" = "$category" ] || continue
    [ "$status" != "removed" ] || continue
    if [ "$package" = "$query" ]; then
      echo "$package $status"
      return 0
    fi
    if [ "$category" = "npm" ] && [ -z "$name_match" ] && [ "$(npm_package_name "$package")" = "$query" ]; then
      name_match="$package $status"
    fi
  done <<< "$entries"
  [ -z "$name_match" ] || echo "$name_match"
}

# Checks category $1 and the packages in the remaining arguments (comma
# separated lists allowed), exiting 1 on the first problem, and sets
# COMPONENT_PACKAGE_LIST.
read_package_arguments() {
  local category="$1" package
  shift
  require_component_category "" "$category"
  COMPONENT_PACKAGE_LIST="$(split_package_list "$@")"
  [ -n "$COMPONENT_PACKAGE_LIST" ] || fail_component "" "no package given"
  while read -r package; do
    require_component_package "" "$package"
  done <<< "$COMPONENT_PACKAGE_LIST"
}

append_overlay_entry() {
  local overlay_file
  overlay_file="$(component_overlay_file)"
  mkdir -p "$TOOL_STATE_DIR"
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$overlay_file"
}

# Drops the "<action> <category> <package>" lines of the overlay, if any.
delete_overlay_entry() {
  local overlay_file tmp_file
  overlay_file="$(component_overlay_file)"
  [ -f "$overlay_file" ] || return 0
  tmp_file="$(mktemp "${overlay_file}.XXXXXX")"
  awk -v action="$1" -v category="$2" -v package="$3" \
    '!($1 == action && $2 == category && $3 == package)' "$overlay_file" > "$tmp_file"
  # Overwrite in place rather than mv, as remove_path_block_from_rc_file does.
  cat "$tmp_file" > "$overlay_file"
  rm -f "$tmp_file"
}

# True when the overlay holds at least one add/remove line.
overlay_has_entries() {
  local overlay_file
  overlay_file="$(component_overlay_file)"
  [ -f "$overlay_file" ] && [ -n "$(conf_lines "$overlay_file")" ]
}

# Deletes the overlay, so the effective list is the defaults again. Sets
# COMPONENTS_CHANGED.
reset_components() {
  rm -f "$(component_overlay_file)"
  COMPONENTS_CHANGED=1
}

# Usage: add_components <category> <package...>
# Packages may also be comma separated. Sets COMPONENTS_CHANGED. A package
# that was a removed default just loses its overlay entry.
add_components() {
  local category="$1"
  shift
  local entries package status
  COMPONENTS_CHANGED=0

  read_package_arguments "$category" "$@"
  entries="$(component_entries)" || exit 1
  while read -r package; do
    status="$(component_status "$entries" "$category" "$package")"
    case "$status" in
      required | default | added) ;;
      removed)
        delete_overlay_entry remove "$category" "$package"
        COMPONENTS_CHANGED=1
        ;;
      *)
        delete_overlay_entry remove "$category" "$package"
        append_overlay_entry add "$category" "$package"
        COMPONENTS_CHANGED=1
        ;;
    esac
  done <<< "$COMPONENT_PACKAGE_LIST"
}

# Usage: component_statuses <category> <package...>
# Prints "<package> <status>" for each package among the arguments: its status
# in the loaded tool's list (required, default or added; see
# find_installed_component for how npm names match), or absent. Exits 1 on
# invalid arguments.
component_statuses() {
  local category="$1"
  shift
  local entries package match status
  read_package_arguments "$category" "$@"
  entries="$(component_entries)" || exit 1
  while read -r package; do
    match="$(find_installed_component "$entries" "$category" "$package")"
    status="absent"
    [ -z "$match" ] || status="${match#* }"
    echo "$package $status"
  done <<< "$COMPONENT_PACKAGE_LIST"
}

# Usage: resolve_removals <category> <package...>
# Sets COMPONENT_REMOVALS to what removing the packages would drop. Exits 1
# for a required package or one not in the list.
resolve_removals() {
  local category="$1"
  shift
  local entries package match status
  COMPONENT_REMOVALS=""

  read_package_arguments "$category" "$@"
  entries="$(component_entries)" || exit 1
  while read -r package; do
    match="$(find_installed_component "$entries" "$category" "$package")"
    [ -n "$match" ] || fail_component "" "'$package' is not in the $category list"
    status="${match#* }"
    [ "$status" != "required" ] || fail_component "" "'${match% *}' is required by the sandbox and cannot be removed"
    contains_line "$COMPONENT_REMOVALS" "$match" || COMPONENT_REMOVALS="$COMPONENT_REMOVALS$match"$'\n'
  done <<< "$COMPONENT_PACKAGE_LIST"
}

# Usage: remove_components <category> <package...>
# Packages may also be comma separated; an npm package can be named without
# its version. Exits 1 for a required package or one not in the list (see
# resolve_removals). Sets COMPONENTS_CHANGED.
remove_components() {
  local category="$1" package status
  COMPONENTS_CHANGED=0

  resolve_removals "$@"

  while read -r package status; do
    [ -n "$package" ] || continue
    if [ "$status" = "added" ]; then
      delete_overlay_entry add "$category" "$package"
    else
      append_overlay_entry remove "$category" "$package"
    fi
    # shellcheck disable=SC2034 # read by lib/commands/config.sh
    COMPONENTS_CHANGED=1
  done <<< "$COMPONENT_REMOVALS"
}
