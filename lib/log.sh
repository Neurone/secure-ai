#!/usr/bin/env bash

# Logging helpers shared by sai and the sandbox wrappers. Everything goes to
# stderr so stdout stays clean for the wrapped tool's output and for report
# commands such as 'sai status'.

log_error() { printf '❌ Error: %s\n' "$*" >&2; }
log_warn() { printf '⚠️  Warning: %s\n' "$*" >&2; }
log_notice() { printf '💡 %s\n' "$*" >&2; }
log_info() { printf ' ▪ %s\n' "$*" >&2; }
log_success() { printf '✅ %s\n' "$*" >&2; }
log_build() { printf '🔨 %s\n' "$*" >&2; }
log_found() { printf '🔍 %s\n' "$*" >&2; }
log_step() { printf ' ▪ %s\n' "$*" >&2; }
log_removed() { printf '🔥 %s\n' "$*" >&2; }
log_kept() { printf '📁 %s\n' "$*" >&2; }
log_section() { printf '📦 %s\n' "$*" >&2; }
