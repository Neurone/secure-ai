#!/usr/bin/env bash

# 'sai config': shows the container components (the apt and npm packages
# installed in each tool's sandbox image) and edits them through the overlay
# in the tool's state directory (see lib/components.sh), rebuilding the image
# when something changed.

usage_for_config_command() {
  local tools_arg
  tools_arg="<$(secure_ai_tools_names)|all>"
  {
    echo "Usage: sai config [$tools_arg]"
    echo "       sai config $tools_arg add|a|remove|r <${COMPONENT_CATEGORIES// /|}> <packages...>"
    echo "       sai config $tools_arg reset"
  } >&2
}

# Prints the packages of category $2 in the entries $1, one per line, with
# their status.
print_category_components() {
  local entries="$1" category="$2" entry_category package status listed=0
  echo "  $category"
  while read -r entry_category package status; do
    [ "$entry_category" = "$category" ] || continue
    case "$status" in
      default) echo "    $package" ;;
      *) echo "    $package ($status)" ;;
    esac
    listed=1
  done <<< "$entries"
  if [ "$listed" -eq 0 ]; then
    echo "    (none)"
  fi
}

print_tool_components() {
  local tool_name="$1" entries category
  load_tool_definition "$tool_name"
  entries="$(component_entries)" || exit 1
  echo "$tool_name"
  for category in $COMPONENT_CATEGORIES; do
    print_category_components "$entries" "$category"
  done
}

# Rebuilds the image of the loaded tool $1 after a components change; a failure
# exits 1, as the change itself is already saved.
rebuild_after_components_change() {
  if ! tool_rebuild_image; then
    log_error "the components of $1 were changed but its image was not rebuilt. Retry with 'sai install $1'."
    exit 1
  fi
}

# Adds or removes packages of the tool $1 ($2 is add or remove, the rest goes
# to add_components / remove_components), then rebuilds its image if
# something changed. Needs Docker, checked by the callers.
edit_tool_components() {
  local tool_name="$1" action="$2"
  shift 2
  load_tool_definition "$tool_name"

  case "$action" in
    add) add_components "$@" ;;
    remove) remove_components "$@" ;;
  esac

  if [ "$COMPONENTS_CHANGED" -eq 0 ]; then
    log_info "Nothing to change for $tool_name."
    return 0
  fi
  rebuild_after_components_change "$tool_name"
}

# Prints, comma separated, the packages among $3... that can be removed from
# the loaded tool $1 (category $2). Each one that can't is reported: absent
# ones are skipped, required ones warned about.
removable_packages() {
  local tool_name="$1" category="$2" statuses package status removable=""
  shift 2
  statuses="$(component_statuses "$category" "$@")" || exit 1
  while read -r package status; do
    case "$status" in
      absent) log_info "Skipping $tool_name: '$package' is not in its $category list." ;;
      required) log_warn "cannot remove '$package' from $tool_name: it is required by the sandbox." ;;
      *) removable="${removable:+$removable,}$package" ;;
    esac
  done <<< "$statuses"
  printf '%s\n' "$removable"
}

# Like edit_tool_components for every selected tool, validating everything
# before anything is written. When removing, a tool only loses the packages
# removable_packages accepts.
# Usage: edit_all_tools_components <add|remove> <category> <packages...>
edit_all_tools_components() {
  local action="$1" category="$2"
  shift 2
  local tool_name packages edits=""

  for tool_name in "${SELECTED_TOOLS[@]}"; do
    load_tool_definition "$tool_name"
    if [ "$action" = "add" ]; then
      component_statuses "$category" "$@" > /dev/null
      packages="$(IFS=,; echo "$*")"
    else
      packages="$(removable_packages "$tool_name" "$category" "$@")" || exit 1
      [ -n "$packages" ] || continue
    fi
    edits="$edits$tool_name $packages"$'\n'
  done

  if [ -z "$edits" ]; then
    log_warn "no package could be removed from any tool."
    return 0
  fi
  while read -r tool_name packages; do
    [ -n "$tool_name" ] || continue
    edit_tool_components "$tool_name" "$action" "$category" "$packages"
  done <<< "$edits"
}

# Drops the customizations of every selected tool that has some, after one
# confirmation, and rebuilds their images.
reset_selected_tools_components() {
  local tool_name customized_tools=""

  require_docker_running
  for tool_name in "${SELECTED_TOOLS[@]}"; do
    load_tool_definition "$tool_name"
    if overlay_has_entries; then
      customized_tools="$customized_tools $tool_name"
    fi
  done
  if [ -z "$customized_tools" ]; then
    log_info "Nothing to change: no customizations."
    return 0
  fi

  confirm_or_abort "Reset the components of ${customized_tools# } to the defaults and rebuild the images?"
  for tool_name in $customized_tools; do
    load_tool_definition "$tool_name"
    reset_components
    rebuild_after_components_change "$tool_name"
  done
}

# Usage: sai config [<tool|all>]
#        sai config <tool|all> add|a|remove|r <category> <packages...>
#        sai config <tool|all> reset
cmd_config() {
  local requested_tool="${1:-all}" action="${2:-}"

  select_tools "$requested_tool" || { usage_for_config_command; exit 1; }
  require_supported_os

  case "$action" in
    "")
      local tool_name
      for tool_name in "${SELECTED_TOOLS[@]}"; do
        print_tool_components "$tool_name"
      done
      ;;
    add | a | remove | r)
      if [ "$#" -lt 4 ]; then
        usage_for_config_command
        exit 1
      fi
      case "$action" in
        a) action="add" ;;
        r) action="remove" ;;
      esac
      # Fail fast: the rebuild needs Docker, and nothing is written without it.
      require_docker_running
      if [ "$EXPLICIT_TOOL" -eq 1 ]; then
        edit_tool_components "${SELECTED_TOOLS[0]}" "$action" "${@:3}"
      else
        edit_all_tools_components "$action" "${@:3}"
      fi
      ;;
    reset)
      if [ "$#" -ne 2 ]; then
        usage_for_config_command
        exit 1
      fi
      reset_selected_tools_components
      ;;
    *)
      usage_for_config_command
      exit 1
      ;;
  esac
}
