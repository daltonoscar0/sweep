#!/bin/bash
# lib/common.sh -- config, logging, sizes, display paths, safe_rm, lock, day guard.
#
# Written for the bash 3.2 that ships with macOS: no associative arrays,
# no ${var,,}, no mapfile, no GNU-only flags. BSD stat/find/sed only.

# Displaying a literal tilde needs a variable: in bash 3.2 "${p/#$HOME/\~}"
# expands to a backslash followed by the tilde.
TILDE='~'
SWEEP_TAB=$(printf '\t')

SWEEP_CONFIG_KEYS="CODE_DIR LOW_SPACE_GB KEEP_HF HF_MAX_IDLE_DAYS \
DERIVED_DATA_MAX_AGE_DAYS DEVICE_SUPPORT_KEEP LOG_MAX_AGE_DAYS CACHE_MIN_MB \
CACHE_ACTIVE_HOURS CACHE_SKIP AUTO_PUSH PUSH_OWNERS MAX_PUSH_FILE_MB NOTIFY \
START_DELAY"

# Cache directory basenames that may be removed from inside CODE_DIR.
SWEEP_PROJECT_CACHE_NAMES="__pycache__ .pytest_cache .mypy_cache .ruff_cache \
.ipynb_checkpoints .hypothesis"

SWEEP_LABEL="com.daltonoscar0.sweep"

# ---------------------------------------------------------------------------
# paths

sweep_paths() {
  SWEEP_CONFIG_DIR="$HOME/.config/sweep"
  SWEEP_CONFIG="$SWEEP_CONFIG_DIR/config"
  SWEEP_STATE_DIR="$HOME/.local/state/sweep"
  SWEEP_STATE="$SWEEP_STATE_DIR/state"
  SWEEP_LOCK="$SWEEP_STATE_DIR/lock"
  SWEEP_LOG_DIR="$HOME/Library/Logs/sweep"
  SWEEP_PLIST="$HOME/Library/LaunchAgents/$SWEEP_LABEL.plist"
  SWEEP_BIN_LINK="$HOME/.local/bin/sweep"
}

# ---------------------------------------------------------------------------
# config

sweep_load_config() {
  local k
  # Values already in the environment win over the config file. That keeps the
  # test suite (and one-off overrides) in charge without touching ~/.config.
  # Snapshot them once: after the first load the variables exist either way.
  if [ "${SWEEP_ENV_SNAPSHOT:-0}" != 1 ]; then
    for k in $SWEEP_CONFIG_KEYS; do
      eval "if [ -n \"\${$k+x}\" ]; then SWEEP_ENV_$k=\"\$$k\"; fi"
    done
    SWEEP_ENV_SNAPSHOT=1
  fi

  CODE_DIR="$HOME/code"
  LOW_SPACE_GB=20
  KEEP_HF="distilroberta-base"
  HF_MAX_IDLE_DAYS=21
  DERIVED_DATA_MAX_AGE_DAYS=7
  DEVICE_SUPPORT_KEEP=2
  LOG_MAX_AGE_DAYS=14
  CACHE_MIN_MB=20
  CACHE_ACTIVE_HOURS=6
  CACHE_SKIP="com.apple.Safari com.apple.akd com.apple.accountsd"
  AUTO_PUSH=1
  PUSH_OWNERS="daltonoscar0"
  MAX_PUSH_FILE_MB=95
  NOTIFY=1
  START_DELAY=120

  if [ -f "$SWEEP_CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$SWEEP_CONFIG"
  fi

  for k in $SWEEP_CONFIG_KEYS; do
    eval "if [ -n \"\${SWEEP_ENV_$k+x}\" ]; then $k=\"\$SWEEP_ENV_$k\"; fi"
  done
  return 0
}

sweep_write_default_config() {
  mkdir -p "$SWEEP_CONFIG_DIR"
  if [ -e "$SWEEP_CONFIG" ]; then
    return 1
  fi
  cat > "$SWEEP_CONFIG" <<'CONFIG'
# ~/.config/sweep/config -- sourced by sweep as bash, so KEY=value only.
# sweep never overwrites this file. Delete a line to go back to the default.

CODE_DIR="$HOME/code"

LOW_SPACE_GB=20                 # below this many GB free, the low-space tier runs
KEEP_HF="distilroberta-base"    # space-separated substrings of HF repo ids never deleted
HF_MAX_IDLE_DAYS=21             # low-space tier: delete HF repos unused this long
DERIVED_DATA_MAX_AGE_DAYS=7     # Xcode DerivedData subfolders older than this go
DEVICE_SUPPORT_KEEP=2           # newest N iOS DeviceSupport folders kept
LOG_MAX_AGE_DAYS=14             # ~/Library/Logs files older than this go
CACHE_MIN_MB=20                 # app cache folders smaller than this are left alone
CACHE_ACTIVE_HOURS=6            # skip caches touched this recently (app probably open)
CACHE_SKIP="com.apple.Safari com.apple.akd com.apple.accountsd"  # never touch

AUTO_PUSH=1                     # 0 pauses all pushing; everything is still reported
PUSH_OWNERS="daltonoscar0"      # only auto-push repos whose GitHub owner is listed
MAX_PUSH_FILE_MB=95             # refuse to push commits containing a bigger blob

NOTIFY=1                        # one macOS notification per run, when there is news
START_DELAY=120                 # seconds to wait before starting (skipped by --now)
CONFIG
  return 0
}

# ---------------------------------------------------------------------------
# time

# Current epoch seconds. SWEEP_NOW overrides it so tests are deterministic.
sweep_now() {
  if [ -n "${SWEEP_NOW:-}" ]; then
    printf '%s\n' "$SWEEP_NOW"
  else
    date +%s
  fi
}

# A sweep "day" starts at 03:00 local time, so a 04:30 job and a 09:00 catch-up
# after a late wake belong to the same day.
sweep_day_key() {
  local ts="${1:-}"
  [ -n "$ts" ] || ts=$(sweep_now)
  date -r $((ts - 10800)) +%Y-%m-%d
}

sweep_stamp() {
  local ts="${1:-}"
  [ -n "$ts" ] || ts=$(sweep_now)
  date -r "$ts" '+%Y-%m-%d %H:%M'
}

sweep_mtime() {
  stat -f %m "$1" 2>/dev/null
}

sweep_atime() {
  stat -f %a "$1" 2>/dev/null
}

# Age of a path in whole days, measured against sweep_now.
sweep_age_days() {
  local mt
  mt=$(sweep_mtime "$1")
  [ -n "$mt" ] || { printf '0\n'; return 1; }
  printf '%s\n' $(( ( $(sweep_now) - mt ) / 86400 ))
}

# A file whose mtime is exactly the given epoch, for use with find -newer.
# Lets the age tests work off SWEEP_NOW instead of the real clock.
sweep_ref_file() {
  local ts="$1" f="$SWEEP_RUNDIR/ref.$1"
  if [ ! -e "$f" ]; then
    touch -t "$(date -r "$ts" +%Y%m%d%H%M.%S)" "$f" 2>/dev/null || touch "$f"
  fi
  printf '%s\n' "$f"
}

sweep_elapsed() {
  local secs="$1"
  if [ "$secs" -lt 60 ]; then
    printf '%ds\n' "$secs"
  else
    printf '%dm%02ds\n' $((secs / 60)) $((secs % 60))
  fi
}

# ---------------------------------------------------------------------------
# sizes and misc

sweep_have() { command -v "$1" >/dev/null 2>&1; }

sweep_size_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1+0; exit}'
}

sweep_file_kb() {
  local b
  b=$(stat -f %z "$1" 2>/dev/null) || return 1
  [ -n "$b" ] || return 1
  printf '%s\n' $(( (b + 1023) / 1024 ))
}

sweep_human() {
  awk -v k="${1:-0}" 'BEGIN {
    if (k >= 1048576) printf "%.1f GB", k/1048576;
    else if (k >= 1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k }'
}

sweep_free_kb() {
  if [ "${SWEEP_TESTING:-0}" = 1 ] && [ -n "${SWEEP_FAKE_FREE_KB:-}" ]; then
    # Simulated disk: starts at the fake value and grows as sweep removes things,
    # so the low-space tier's "stop once there is room" logic is testable.
    local freed=0
    if [ -n "${SWEEP_CLEANED:-}" ] && [ -f "$SWEEP_CLEANED" ]; then
      freed=$(awk -F'\t' '{s+=$2} END {print s+0}' "$SWEEP_CLEANED")
    fi
    printf '%s\n' $(( SWEEP_FAKE_FREE_KB + freed ))
    return 0
  fi
  df -k / | awk 'NR==2 {print $4+0}'
}

sweep_free_gb_lt() {  # free space is below N GB?
  local limit_kb=$(( $1 * 1048576 ))
  [ "$(sweep_free_kb)" -lt "$limit_kb" ]
}

# Show $HOME as ~ without the bash 3.2 backslash wart.
sweep_disp() {
  local p="$1"
  printf '%s\n' "${p/#$HOME/$TILDE}"
}

# Run a command with a time limit. macOS has no timeout(1).
sweep_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  # The watcher polls instead of sleeping for the whole timeout, so it goes
  # away on its own as soon as the command finishes and leaves nothing behind.
  (
    i=0
    while [ "$i" -lt "$secs" ]; do
      sleep 1
      kill -0 "$pid" 2>/dev/null || exit 0
      i=$((i + 1))
    done
    kill -TERM "$pid" 2>/dev/null
    sleep 3
    kill -KILL "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local watcher=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null || :
  return "$rc"
}

sweep_on_low_battery() {
  if [ "${SWEEP_TESTING:-0}" = 1 ] && [ -n "${SWEEP_FAKE_BATT:-}" ]; then
    [ "$SWEEP_FAKE_BATT" -lt 30 ] && return 0
    return 1
  fi
  sweep_have pmset || return 1
  local out pct
  out=$(pmset -g batt 2>/dev/null) || return 1
  case "$out" in
    *"'Battery Power'"*) ;;
    *) return 1 ;;
  esac
  pct=$(printf '%s\n' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)%.*/\1/p' | head -1)
  [ -n "$pct" ] || return 1
  [ "$pct" -lt 30 ]
}

# ---------------------------------------------------------------------------
# state (small KEY=value store in ~/.local/state/sweep/state)

sweep_state_get() {
  [ -f "$SWEEP_STATE" ] || return 1
  local v
  v=$(sed -n "s/^$1=//p" "$SWEEP_STATE" | tail -1)
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

sweep_state_set() {
  mkdir -p "$SWEEP_STATE_DIR"
  local tmp="$SWEEP_STATE.tmp.$$"
  : > "$tmp"
  if [ -f "$SWEEP_STATE" ]; then
    grep -v "^$1=" "$SWEEP_STATE" >> "$tmp" 2>/dev/null || :
  fi
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv -f "$tmp" "$SWEEP_STATE"
}

# ---------------------------------------------------------------------------
# lock (mkdir based, stale after two hours)

SWEEP_LOCK_HELD=0

sweep_lock_acquire() {
  mkdir -p "$SWEEP_STATE_DIR"
  if mkdir "$SWEEP_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$SWEEP_LOCK/pid"
    SWEEP_LOCK_HELD=1
    return 0
  fi
  local mt age
  mt=$(sweep_mtime "$SWEEP_LOCK")
  [ -n "$mt" ] || mt=0
  age=$(( $(sweep_now) - mt ))
  if [ "$age" -gt 7200 ]; then
    rm -rf "$SWEEP_LOCK"
    if mkdir "$SWEEP_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" > "$SWEEP_LOCK/pid"
      SWEEP_LOCK_HELD=1
      return 0
    fi
  fi
  return 1
}

sweep_lock_release() {
  if [ "$SWEEP_LOCK_HELD" = 1 ]; then
    rm -rf "$SWEEP_LOCK"
    SWEEP_LOCK_HELD=0
  fi
}

# ---------------------------------------------------------------------------
# once per day guard

sweep_day_done() {
  local last
  last=$(sweep_state_get last_run_day) || return 1
  [ "$last" = "$(sweep_day_key)" ]
}

sweep_mark_day_done() {
  sweep_state_set last_run_day "$(sweep_day_key)"
  sweep_state_set last_run_epoch "$(sweep_now)"
}

sweep_weekly_due() {
  local last age
  if ! last=$(sweep_state_get last_weekly_epoch); then
    return 0
  fi
  age=$(( $(sweep_now) - last ))
  [ "$age" -gt $(( 7 * 86400 )) ] && return 0
  [ "$(date -r "$(sweep_now)" +%w)" = 0 ]
}

# ---------------------------------------------------------------------------
# run scaffolding: temp dir, per-run log, record files

sweep_run_init() {
  SWEEP_DRY_RUN="${SWEEP_DRY_RUN:-0}"
  SWEEP_START_EPOCH=$(sweep_now)
  SWEEP_START_REAL=$(date +%s)
  SWEEP_DATE=$(date -r "$SWEEP_START_EPOCH" +%Y-%m-%d)
  mkdir -p "$SWEEP_LOG_DIR"
  SWEEP_RUN_LOG="$SWEEP_LOG_DIR/$SWEEP_DATE.log"
  SWEEP_REPORT="$SWEEP_LOG_DIR/$SWEEP_DATE.md"
  SWEEP_RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/sweep.XXXXXX") || return 1
  SWEEP_CLEANED="$SWEEP_RUNDIR/cleaned.tsv"
  SWEEP_GIT="$SWEEP_RUNDIR/git.tsv"
  SWEEP_PUSH="$SWEEP_RUNDIR/push.tsv"
  SWEEP_FYI="$SWEEP_RUNDIR/fyi.tsv"
  SWEEP_NOTES="$SWEEP_RUNDIR/notes.txt"
  : > "$SWEEP_CLEANED"; : > "$SWEEP_GIT"; : > "$SWEEP_PUSH"
  : > "$SWEEP_FYI"; : > "$SWEEP_NOTES"
  SWEEP_TIERS=""
  SWEEP_REPO_COUNT=0
}

sweep_run_cleanup() {
  [ -n "${SWEEP_RUNDIR:-}" ] && [ -d "${SWEEP_RUNDIR:-}" ] && rm -rf "$SWEEP_RUNDIR"
  sweep_lock_release
}

sweep_log() {
  [ -n "${SWEEP_RUN_LOG:-}" ] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$SWEEP_RUN_LOG"
}

sweep_note() {   # a free-text line for the report's setup notes
  printf '%s\n' "$*" >> "$SWEEP_NOTES"
}

sweep_record_clean() {  # category, kb, path
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SWEEP_CLEANED"
}

sweep_record_git() {    # kind, repo, message, command
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$SWEEP_GIT"
}

sweep_record_push() {   # status, repo, branch, commits, detail
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$SWEEP_PUSH"
}

sweep_record_fyi() {    # kind, text
  printf '%s\t%s\n' "$1" "$2" >> "$SWEEP_FYI"
}

sweep_record_fyi_once() {
  if ! grep -Fqx "$(printf '%s\t%s' "$1" "$2")" "$SWEEP_FYI" 2>/dev/null; then
    sweep_record_fyi "$1" "$2"
  fi
}

sweep_cleaned_kb() {
  awk -F'\t' '{s+=$2} END {print s+0}' "$SWEEP_CLEANED"
}

sweep_tier() {
  case " $SWEEP_TIERS " in
    *" $1 "*) ;;
    *) SWEEP_TIERS="${SWEEP_TIERS:+$SWEEP_TIERS }$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# safe_rm: the only thing in sweep that deletes

# The roots under which deletion is permitted. Anything else is refused even if
# a tier asks for it.
sweep_safe_roots() {
  printf '%s\n' \
    "$HOME/Library/Caches" \
    "$HOME/Library/Logs" \
    "$HOME/Library/Developer/Xcode/DerivedData" \
    "$HOME/Library/Developer/Xcode/iOS DeviceSupport" \
    "$HOME/.npm/_cacache" \
    "$HOME/.cache/huggingface" \
    "$HOME/.cache/uv" \
    "$HOME/.cache/pip"
}

sweep_path_allowed() {
  local p="$1" root base name
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ "$p" = "$root" ] && return 1   # a root itself is never removed
    case "$p" in
      "$root"/*) return 0 ;;
    esac
  done <<EOF
$(sweep_safe_roots)
EOF

  # Project caches inside CODE_DIR, by basename only.
  if [ -n "${CODE_DIR:-}" ]; then
    case "$p" in
      "$CODE_DIR"/*)
        base=$(basename "$p")
        for name in $SWEEP_PROJECT_CACHE_NAMES; do
          [ "$base" = "$name" ] && return 0
        done
        ;;
    esac
  fi
  return 1
}

# safe_rm PATH CATEGORY
# Returns 0 only when the path was accepted (removed, or counted in dry-run).
sweep_safe_rm() {
  local p="${1:-}" category="${2:-other}" kb

  [ -n "$p" ] || return 1
  case "$p" in
    /*) ;;
    *) sweep_log "refused (not absolute): $p"; return 1 ;;
  esac
  case "/$p/" in
    *"/../"*) sweep_log "refused (..): $p"; return 1 ;;
  esac

  # strip trailing slashes; "/" becomes empty and is refused
  while [ "$p" != "${p%/}" ]; do p="${p%/}"; done
  if [ -z "$p" ]; then sweep_log "refused (root): /"; return 1; fi

  if [ "$p" = "$HOME" ]; then sweep_log "refused (\$HOME): $p"; return 1; fi
  if [ -L "$p" ]; then sweep_log "refused (symlink): $p"; return 1; fi
  if [ ! -e "$p" ]; then return 1; fi
  if ! sweep_path_allowed "$p"; then
    sweep_log "refused (outside allowlist): $p"
    return 1
  fi

  kb=$(sweep_size_kb "$p")
  [ -n "$kb" ] || kb=0
  sweep_record_clean "$category" "$kb" "$p"

  if [ "${SWEEP_DRY_RUN:-0}" = 1 ]; then
    sweep_log "would remove [$category] $(sweep_human "$kb") $(sweep_disp "$p")"
    return 0
  fi
  if rm -rf -- "$p" 2>/dev/null; then
    sweep_log "removed [$category] $(sweep_human "$kb") $(sweep_disp "$p")"
    return 0
  fi
  sweep_log "failed to remove $(sweep_disp "$p")"
  return 1
}
