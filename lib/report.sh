#!/bin/bash
# lib/report.sh -- the markdown report and the one notification.
#
# The top of the report is only for things that need Oscar. Everything sweep
# did on its own is below that, in decreasing order of interest.

# Kinds from lib/git.sh that belong in "Needs you", worst first.
SWEEP_NEEDS_KINDS="secret auth detached deleted_tracked no_remote push_rejected \
too_big behind large_untracked"

# FYI kinds, in the order they are printed, with the label each group gets.
sweep_fyi_groups() {
  printf '%s\n' \
    "big_file${SWEEP_TAB}Biggest files outside ~/Library (never deleted)" \
    "downloads${SWEEP_TAB}Downloads" \
    "docker${SWEEP_TAB}Docker" \
    "committed_cache${SWEEP_TAB}Caches that are committed to git" \
    "other_owner${SWEEP_TAB}Not yours to push" \
    "no_upstream${SWEEP_TAB}Branches with no upstream" \
    "dirty${SWEEP_TAB}Uncommitted work" \
    "push_off${SWEEP_TAB}Pushing is turned off" \
    "offline_push${SWEEP_TAB}Waiting for a network" \
    "empty_repo${SWEEP_TAB}Empty repos" \
    "tool_failed${SWEEP_TAB}Tools that did not finish" \
    "would_run${SWEEP_TAB}Skipped by the dry run"
}

sweep_count_kind() {  # file, kind
  awk -F'\t' -v k="$2" '$1 == k {n++} END {print n+0}' "$1"
}

sweep_needs_count() {
  local k n=0
  for k in $SWEEP_NEEDS_KINDS; do
    n=$(( n + $(sweep_count_kind "$SWEEP_GIT" "$k") ))
  done
  printf '%s\n' "$n"
}

sweep_push_count() {
  awk -F'\t' '$1 == "pushed" || $1 == "would_push" {n++} END {print n+0}' "$SWEEP_PUSH"
}

# ---------------------------------------------------------------------------

sweep_write_report() {
  local free_before="$1" free_after="$2"
  local freed dur needs npush md kind repo msg cmd label k line n

  freed=$(sweep_cleaned_kb)
  dur=$(( $(date +%s) - SWEEP_START_REAL ))
  [ "$dur" -ge 0 ] || dur=0
  needs=$(sweep_needs_count)
  npush=$(sweep_push_count)
  md="$SWEEP_REPORT"

  {
    printf '# sweep %s%s\n\n' "$(sweep_stamp "$SWEEP_START_EPOCH")" \
      "$([ "${SWEEP_DRY_RUN:-0}" = 1 ] && printf ' (dry run, nothing was deleted or pushed)')"

    printf 'Free space %s before, %s after; removed %s. Tiers: %s. %s repos checked. Took %s.\n' \
      "$(sweep_human "$free_before")" "$(sweep_human "$free_after")" \
      "$(sweep_human "$freed")" "$(printf '%s' "${SWEEP_TIERS:-none}" | sed 's/ /, /g')" \
      "${SWEEP_REPO_COUNT:-0}" "$(sweep_elapsed "$dur")"

    if [ "$(sweep_count_kind "$SWEEP_GIT" offline)" -gt 0 ]; then
      printf '\n> Offline: github.com could not be reached, so nothing was fetched or pushed. The git section below is from local state only.\n'
    fi

    # --- 1. needs you ----------------------------------------------------
    printf '\n## Needs you\n\n'
    if [ "$needs" -eq 0 ]; then
      printf '_Nothing. Every repo under `%s` is on GitHub and backed up._\n' "$(sweep_disp "$CODE_DIR")"
    else
      for k in $SWEEP_NEEDS_KINDS; do
        awk -F'\t' -v k="$k" '$1 == k' "$SWEEP_GIT" |
        while IFS="$SWEEP_TAB" read -r kind repo msg cmd; do
          [ -n "$msg" ] || continue
          # The two trailing spaces are a markdown hard break, so the
          # command lands on its own line whether this is rendered or catted.
          if [ "$repo" = "-" ]; then
            printf -- '- %s  \n' "$msg"
          else
            printf -- '- **%s** -- %s  \n' "$repo" "$msg"
          fi
          [ -n "$cmd" ] && printf '  `%s`\n' "$cmd"
        done
      done
    fi

    # --- 2. pushed -------------------------------------------------------
    if [ "$npush" -gt 0 ]; then
      printf '\n## Pushed\n\n'
      awk -F'\t' '$1 == "pushed" || $1 == "would_push"' "$SWEEP_PUSH" |
      while IFS="$SWEEP_TAB" read -r kind repo msg cmd label; do
        printf -- '- **%s** `%s`, %s commit(s)%s%s\n' "$repo" "$msg" "$cmd" \
          "$([ -n "$label" ] && printf ' -- %s' "$label")" \
          "$([ "$kind" = would_push ] && printf ' _(dry run: not pushed)_')"
      done
    fi

    # --- 3. cleaned ------------------------------------------------------
    if [ "$freed" -gt 0 ]; then
      printf '\n## Cleaned\n\n'
      printf '| what | %s |\n|---|---|\n' \
        "$([ "${SWEEP_DRY_RUN:-0}" = 1 ] && printf 'would free' || printf 'freed')"
      awk -F'\t' '{kb[$1] += $2} END {for (c in kb) printf "%d\t%s\n", kb[c], c}' "$SWEEP_CLEANED" |
        sort -rn |
      while IFS="$SWEEP_TAB" read -r n label; do
        [ -n "$label" ] || continue
        printf '| %s | %s |\n' "$label" "$(sweep_human "$n")"
      done
      printf '| **total** | **%s** |\n' "$(sweep_human "$freed")"
    fi

    # --- 4. fyi ----------------------------------------------------------
    if [ -s "$SWEEP_FYI" ]; then
      printf '\n## FYI\n'
      while IFS="$SWEEP_TAB" read -r k label; do
        [ -n "$k" ] || continue
        [ "$(sweep_count_kind "$SWEEP_FYI" "$k")" -gt 0 ] || continue
        printf '\n**%s**\n\n' "$label"
        awk -F'\t' -v kind="$k" '$1 == kind {print $2}' "$SWEEP_FYI" |
        while IFS= read -r line; do
          printf -- '- %s\n' "$line"
        done
      done <<EOF
$(sweep_fyi_groups)
EOF
    fi

    # --- 5. setup notes --------------------------------------------------
    printf '\n## Setup notes\n\n'
    if [ -s "$SWEEP_NOTES" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && printf -- '- %s\n' "$line"
      done < "$SWEEP_NOTES"
    fi
    printf -- '- sweep never empties the Trash: a background job cannot see it without Full Disk Access. Turn on Finder > Settings > Advanced > "Remove items from the Trash after 30 days" instead.\n'
    printf -- '- Pushing from a background job needs `~/.ssh/config` to contain `Host github.com` with `AddKeysToAgent yes` and `UseKeychain yes`.\n'
    printf -- '- Every path deleted this run is listed in `%s`. Pause pushing with `AUTO_PUSH=0` in `%s`, or stop sweep altogether with `sweep uninstall`.\n' \
      "$(sweep_disp "$SWEEP_RUN_LOG")" "$(sweep_disp "$SWEEP_CONFIG")"
  } > "$md"

  cp -f "$md" "$SWEEP_LOG_DIR/latest.md"
  SWEEP_NEEDS="$needs"
  SWEEP_PUSHED="$npush"
  SWEEP_FREED_KB="$freed"
  return 0
}

# ---------------------------------------------------------------------------
# one notification, and only when there is something worth saying

sweep_notify() {
  [ "${NOTIFY:-1}" = 1 ] || return 0
  [ "${SWEEP_DRY_RUN:-0}" = 1 ] && return 0

  local freed="${SWEEP_FREED_KB:-0}" npush="${SWEEP_PUSHED:-0}" needs="${SWEEP_NEEDS:-0}"
  local parts="" msg
  if [ "$freed" -lt 512000 ] && [ "$npush" -eq 0 ] && [ "$needs" -eq 0 ]; then
    return 0
  fi

  [ "$freed" -gt 0 ] && parts="Freed $(sweep_human "$freed")"
  if [ "$npush" -gt 0 ]; then
    parts="${parts:+$parts, }pushed $npush repo$([ "$npush" -gt 1 ] && printf s)"
  fi
  if [ "$needs" -gt 0 ]; then
    parts="${parts:+$parts, }$needs need$([ "$needs" -eq 1 ] && printf s) you"
  fi
  msg="${parts:-Nothing to do}. Run: sweep report"

  if [ "${SWEEP_TESTING:-0}" = 1 ]; then
    printf '%s\n' "$msg" >> "$HOME/notifications.txt"
    return 0
  fi
  sweep_have osascript || return 0
  osascript -e "display notification \"$msg\" with title \"sweep\"" >/dev/null 2>&1 || :
  return 0
}

# ---------------------------------------------------------------------------
# keep a month of reports

sweep_prune_reports() {
  [ -d "${SWEEP_LOG_DIR:-}" ] || return 0
  local f
  find "$SWEEP_LOG_DIR" -maxdepth 1 -type f \( -name '2*.md' -o -name '2*.log' \) \
       -mtime +30 2>/dev/null |
  while IFS= read -r f; do
    case "$f" in
      "$SWEEP_LOG_DIR"/*) rm -f -- "$f" ;;
    esac
  done
  return 0
}
