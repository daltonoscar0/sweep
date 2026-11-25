#!/bin/bash
# lib/clean.sh -- the cleanup tiers.
#
#   light      (every run)  app caches, old logs, project caches, DerivedData
#   weekly     (Sundays, or 7+ days since the last one) package manager caches,
#                           iOS DeviceSupport, unavailable simulators
#   low-space  (only when free space is still short) Hugging Face models, plus
#                           a report of the big things sweep will not touch
#
# Nothing here removes anything itself: every deletion goes through
# sweep_safe_rm, which enforces the allowlist and honours --dry-run.

# ---------------------------------------------------------------------------
# 1. app caches

# Empty the contents of each big, idle, non-skipped folder in ~/Library/Caches.
# The folder itself stays: some apps only create their cache dir at launch.
sweep_clean_app_caches() {
  local root="$HOME/Library/Caches"
  [ -d "$root" ] || return 0

  local ref entry base kb skip s child recent
  ref=$(sweep_ref_file $(( $(sweep_now) - CACHE_ACTIVE_HOURS * 3600 )))

  for entry in "$root"/*; do
    [ -d "$entry" ] || continue
    [ -L "$entry" ] && continue
    base=$(basename "$entry")

    skip=0
    for s in $CACHE_SKIP; do
      [ "$base" = "$s" ] && skip=1
    done
    [ "$skip" -eq 1 ] && continue

    kb=$(sweep_size_kb "$entry")
    [ -n "$kb" ] || kb=0
    [ "$kb" -lt $(( CACHE_MIN_MB * 1024 )) ] && continue

    # Anything touched recently means the app is probably running.
    recent=$(find "$entry" -newer "$ref" -print 2>/dev/null | head -1)
    if [ -n "$recent" ]; then
      sweep_log "skipped (active within ${CACHE_ACTIVE_HOURS}h) $(sweep_disp "$entry")"
      continue
    fi

    for child in "$entry"/* "$entry"/.[!.]* "$entry"/..?*; do
      [ -e "$child" ] || continue
      sweep_safe_rm "$child" "App caches" || :
    done
  done
  return 0
}

# ---------------------------------------------------------------------------
# 2. old logs

sweep_clean_logs() {
  local root="$HOME/Library/Logs"
  [ -d "$root" ] || return 0
  local ref f
  ref=$(sweep_ref_file $(( $(sweep_now) - LOG_MAX_AGE_DAYS * 86400 )))
  # -path prune keeps sweep's own reports and launchd logs out of it.
  find "$root" -path "$SWEEP_LOG_DIR" -prune -o \
       -type f ! -newer "$ref" -print 2>/dev/null |
  while IFS= read -r f; do
    sweep_safe_rm "$f" "Logs" || :
  done
  return 0
}

# ---------------------------------------------------------------------------
# 3. caches inside your projects

# Pruning virtual environments matters: a .venv-extract/lib/python3.12/
# site-packages tree is full of __pycache__ that belongs to installed packages,
# and walking into it is both slow and wrong.
sweep_project_cache_dirs() {
  [ -d "${CODE_DIR:-}" ] || return 0
  find "$CODE_DIR" \
      \( -name node_modules -o -name 'venv*' -o -name '.venv*' \
         -o -name site-packages -o -name .git \) -prune -o \
      -type d \( -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache \
         -o -name .ruff_cache -o -name .ipynb_checkpoints -o -name .hypothesis \) \
      -print 2>/dev/null
}

# Is anything inside this directory tracked by git?
sweep_dir_is_tracked() {
  local out
  out=$(cd "$1" 2>/dev/null && git ls-files 2>/dev/null | head -1) || return 1
  [ -n "$out" ]
}

sweep_clean_project_caches() {
  [ -d "${CODE_DIR:-}" ] || return 0
  local d
  sweep_project_cache_dirs |
  while IFS= read -r d; do
    if sweep_dir_is_tracked "$d"; then
      # Deleting these would stage a deletion in a repo. Report instead.
      sweep_log "kept (tracked by git) $(sweep_disp "$d")"
      sweep_record_fyi_once committed_cache "\`$(sweep_disp "$d")\` is committed; \`git rm -r --cached\` it and add it to .gitignore"
      continue
    fi
    sweep_safe_rm "$d" "Project caches" || :
  done
  return 0
}

# ---------------------------------------------------------------------------
# 4. Xcode DerivedData
#
# ~/Library/Developer/Xcode/Archives is never in the allowlist, so it cannot be
# removed even by mistake: it holds the symbols for builds you shipped.

sweep_clean_derived_data() {
  local root="$HOME/Library/Developer/Xcode/DerivedData"
  [ -d "$root" ] || return 0
  local ref d recent
  ref=$(sweep_ref_file $(( $(sweep_now) - DERIVED_DATA_MAX_AGE_DAYS * 86400 )))
  for d in "$root"/*; do
    [ -e "$d" ] || continue
    [ -L "$d" ] && continue
    # Two levels is enough to spot a recent build without walking gigabytes.
    recent=$(find "$d" -maxdepth 2 -newer "$ref" -print 2>/dev/null | head -1)
    [ -n "$recent" ] && continue
    sweep_safe_rm "$d" "Xcode DerivedData" || :
  done
  return 0
}

# ---------------------------------------------------------------------------
# 5. package manager caches (weekly)

# Run an external cleanup command, with a time limit, measuring the directory
# it is supposed to shrink. A failure is reported, never fatal.
sweep_run_tool() {  # label, cache_dir_or_empty, command...
  local label="$1" dir="$2"; shift 2
  sweep_have "$1" || return 0
  # The test suite must never shell out to brew, pnpm or Xcode on a real Mac.
  if [ "${SWEEP_TESTING:-0}" = 1 ]; then
    sweep_log "skipped under test: $*"
    return 0
  fi

  if [ "${SWEEP_DRY_RUN:-0}" = 1 ]; then
    sweep_record_fyi would_run "\`$*\` (weekly tier; a dry run does not run it)"
    return 0
  fi

  local before=0 after=0 delta
  if [ -n "$dir" ] && [ -d "$dir" ]; then before=$(sweep_size_kb "$dir"); fi
  if sweep_timeout 300 "$@" >> "$SWEEP_RUN_LOG" 2>&1; then
    sweep_log "ran: $*"
  else
    sweep_log "did not finish cleanly: $*"
    sweep_record_fyi tool_failed "\`$*\` did not finish cleanly (details in the run log)"
  fi
  if [ -n "$dir" ] && [ -d "$dir" ]; then after=$(sweep_size_kb "$dir"); fi
  delta=$(( before - after ))
  [ "$delta" -gt 0 ] && sweep_record_clean "Developer caches" "$delta" "$label"
  return 0
}

sweep_clean_dev_caches() {
  # npm has no "prune" that frees much, so empty the cache directory itself.
  local cacache="$HOME/.npm/_cacache" child
  if [ -d "$cacache" ]; then
    for child in "$cacache"/* "$cacache"/.[!.]*; do
      [ -e "$child" ] || continue
      sweep_safe_rm "$child" "Developer caches" || :
    done
  fi

  sweep_run_tool "uv cache"   "$HOME/.cache/uv"  uv cache prune
  sweep_run_tool "pip cache"  "$HOME/.cache/pip" pip cache purge
  sweep_run_tool "Homebrew"   ""                 brew cleanup -s --prune=all
  sweep_run_tool "pnpm store" ""                 pnpm store prune
  return 0
}

# ---------------------------------------------------------------------------
# 6. iOS DeviceSupport and dead simulators (weekly)

sweep_clean_device_support() {
  local root="$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  if [ -d "$root" ]; then
    local d mt line
    for d in "$root"/*; do
      [ -d "$d" ] || continue
      [ -L "$d" ] && continue
      mt=$(sweep_mtime "$d"); [ -n "$mt" ] || mt=0
      printf '%s\t%s\n' "$mt" "$d"
    done | sort -rn | tail -n +$(( DEVICE_SUPPORT_KEEP + 1 )) |
    while IFS="$SWEEP_TAB" read -r mt d; do
      [ -n "$d" ] || continue
      sweep_safe_rm "$d" "iOS DeviceSupport" || :
    done
  fi

  if [ "${SWEEP_DRY_RUN:-0}" = 1 ]; then
    sweep_have xcrun && sweep_record_fyi would_run \
      "\`xcrun simctl delete unavailable\` (weekly tier; a dry run does not run it)"
    return 0
  fi
  if [ "${SWEEP_TESTING:-0}" = 1 ]; then
    sweep_log "skipped under test: xcrun simctl delete unavailable"
    return 0
  fi
  if sweep_have xcrun && xcode-select -p >/dev/null 2>&1; then
    if sweep_timeout 300 xcrun simctl delete unavailable >> "$SWEEP_RUN_LOG" 2>&1; then
      sweep_log "ran: xcrun simctl delete unavailable"
    else
      sweep_log "did not finish cleanly: xcrun simctl delete unavailable"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 7. Hugging Face caches (low-space tier only)

# APFS does not reliably update access times, so "last used" is the newest of:
# the mtime of refs/* (written on every resolve), the mtime of snapshots/*, and
# the atime of the blobs. Any one of them alone gets this wrong.
sweep_hf_last_used() {
  local d="$1" newest=0 t p
  for p in "$d"/refs/* "$d"/refs/*/* "$d"/snapshots/* "$d"/snapshots/*/*; do
    [ -e "$p" ] || continue
    t=$(sweep_mtime "$p")
    [ -n "$t" ] && [ "$t" -gt "$newest" ] && newest=$t
  done
  for p in "$d"/blobs/*; do
    [ -e "$p" ] || continue
    t=$(sweep_atime "$p")
    [ -n "$t" ] && [ "$t" -gt "$newest" ] && newest=$t
  done
  if [ "$newest" -eq 0 ]; then
    t=$(sweep_mtime "$d")
    [ -n "$t" ] && newest=$t
  fi
  printf '%s\n' "$newest"
}

sweep_clean_huggingface() {
  local hub="$HOME/.cache/huggingface/hub"
  [ -d "$hub" ] || return 0

  local list="$SWEEP_RUNDIR/hf.tsv" d keep k last idle now
  now=$(sweep_now)
  : > "$list"

  for d in "$hub"/models--* "$hub"/datasets--*; do
    [ -d "$d" ] || continue
    [ -L "$d" ] && continue

    keep=0
    for k in $KEEP_HF; do
      case "$d" in *"$k"*) keep=1 ;; esac
    done
    if [ "$keep" -eq 1 ]; then
      sweep_log "kept (KEEP_HF) $(sweep_disp "$d")"
      continue
    fi

    last=$(sweep_hf_last_used "$d")
    idle=$(( (now - last) / 86400 ))
    if [ "$idle" -lt "$HF_MAX_IDLE_DAYS" ]; then
      sweep_log "kept (used ${idle}d ago) $(sweep_disp "$d")"
      continue
    fi
    printf '%s\t%s\n' "$last" "$d" >> "$list"
  done

  # Idle longest first, and stop as soon as there is enough room again.
  sort -n "$list" |
  while IFS="$SWEEP_TAB" read -r last d; do
    [ -n "$d" ] || continue
    if ! sweep_free_gb_lt "$LOW_SPACE_GB"; then
      sweep_log "stopping Hugging Face cleanup: back above ${LOW_SPACE_GB} GB free"
      break
    fi
    sweep_safe_rm "$d" "Hugging Face caches" || :
  done
  return 0
}

# ---------------------------------------------------------------------------
# 8. the big things sweep will not delete for you (low-space tier, report only)

sweep_report_big_things() {
  local n=0 line size path total

  while IFS= read -r line; do
    size=${line%% *}
    path=${line#* }
    [ -n "$path" ] || continue
    n=$((n + 1))
    sweep_record_fyi big_file "$(sweep_human $(( size / 1024 ))) \`$(sweep_disp "$path")\`"
    [ "$n" -ge 10 ] && break
  done <<EOF
$(find "$HOME" \
    \( -path "$HOME/Library" -o -path "$HOME/.Trash" -o -name node_modules \
       -o -name 'venv*' -o -name '.venv*' \) -prune -o \
    -type f -size +1G -print0 2>/dev/null |
  xargs -0 stat -f '%z %N' 2>/dev/null | sort -rn | head -10)
EOF

  if [ -d "$HOME/Downloads" ]; then
    total=$(find "$HOME/Downloads" -mindepth 1 -maxdepth 1 -mtime +90 -print0 2>/dev/null |
      xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')
    n=$(find "$HOME/Downloads" -mindepth 1 -maxdepth 1 -mtime +90 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -gt 0 ]; then
      sweep_record_fyi downloads "$n item$([ "$n" -eq 1 ] || printf s) in \`~/Downloads\` older than 90 days, $(sweep_human "${total:-0}") in total. sweep never touches Downloads."
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Docker: size only, every run. sweep never prunes Docker.

sweep_fyi_docker() {
  [ "${SWEEP_TESTING:-0}" = 1 ] && return 0
  sweep_have docker || return 0
  local out images build
  out=$(sweep_timeout 20 docker system df 2>/dev/null) || return 0
  [ -n "$out" ] || return 0
  images=$(printf '%s\n' "$out" | awk '$1=="Images" {print $(NF-1), $NF}')
  build=$(printf '%s\n' "$out" | awk '$1=="Build" {print $(NF-1), $NF}')
  if [ -n "$images$build" ]; then
    sweep_record_fyi docker "Docker is holding images (${images:-?} reclaimable) and build cache (${build:-?} reclaimable). sweep never prunes Docker; \`docker system prune -a\` is yours to run."
  fi
  return 0
}
