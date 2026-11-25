#!/bin/bash
# lib/git.sh -- find every repo under CODE_DIR, say what is not backed up, and
# push the ones that are safe to push.
#
# Rules that are not negotiable:
#   * sweep never stages, commits, stashes, rebases, pulls or forces anything.
#     The only write operation in this file is "git push" (plus "push -u"), and
#     only for owners listed in PUSH_OWNERS.
#   * a push that would publish a secret, or a blob over MAX_PUSH_FILE_MB, does
#     not happen; it is reported instead.
#   * everything else is classified and reported for Oscar to decide.

SWEEP_NET=0
SWEEP_AUTH_FAILED=0
SWEEP_EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# ---------------------------------------------------------------------------
# network

sweep_network_up() {
  if [ "${SWEEP_TESTING:-0}" = 1 ] && [ -n "${SWEEP_FAKE_NETWORK:-}" ]; then
    [ "$SWEEP_FAKE_NETWORK" = 1 ]
    return
  fi
  if sweep_have nc; then
    nc -z -G 3 -w 3 github.com 443 >/dev/null 2>&1 && return 0
  fi
  if sweep_have curl; then
    curl -sS -m 5 -o /dev/null https://github.com >/dev/null 2>&1 && return 0
  fi
  return 1
}

# A 04:30 run can easily start before wifi is back. Give it five minutes.
sweep_wait_for_network() {
  sweep_network_up && return 0
  [ "${SWEEP_TESTING:-0}" = 1 ] && return 1
  local i=0
  while [ "$i" -lt 10 ]; do
    sleep 30
    i=$((i + 1))
    sweep_network_up && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# discovery

# Repos up to three directories deep, so ~/code/archive/ml/* and
# ~/code/morphology/external/tknzn4Irish are both included.
sweep_find_repos() {
  [ -d "${CODE_DIR:-}" ] || return 0
  find "$CODE_DIR" -maxdepth 4 \
      \( -name node_modules -o -name 'venv*' -o -name '.venv*' \
         -o -name site-packages \) -prune -o \
      -name .git -print 2>/dev/null |
    sed 's|/\.git$||' |
    sort
}

sweep_repo_label() {
  local r="$1" n
  n=${r#"$CODE_DIR"/}
  [ "$n" = "$r" ] && n=$(basename "$r")
  printf '%s\n' "$n"
}

sweep_remote_url() {
  local r="$1" url first
  url=$(git -C "$r" remote get-url origin 2>/dev/null) && [ -n "$url" ] && {
    printf '%s\n' "$url"; return 0; }
  first=$(git -C "$r" remote 2>/dev/null | head -1)
  [ -n "$first" ] || return 1
  git -C "$r" remote get-url "$first" 2>/dev/null
}

# The GitHub owner, or nothing at all. Anything that is not a github.com URL
# has no owner as far as sweep is concerned, and so is never pushed.
sweep_repo_owner() {
  local r="$1" url="$2" p
  if [ "${SWEEP_TESTING:-0}" = 1 ]; then
    if [ -f "$r/.git/sweep-test-owner" ]; then
      head -1 "$r/.git/sweep-test-owner"
      return 0
    fi
    if [ -n "${SWEEP_TEST_OWNER_OVERRIDE:-}" ]; then
      printf '%s\n' "$SWEEP_TEST_OWNER_OVERRIDE"
      return 0
    fi
  fi
  case "$url" in
    git@github.com:*)       p=${url#git@github.com:} ;;
    ssh://git@github.com/*) p=${url#ssh://git@github.com/} ;;
    https://github.com/*)   p=${url#https://github.com/} ;;
    http://github.com/*)    p=${url#http://github.com/} ;;
    *) return 1 ;;
  esac
  p=${p%%/*}
  [ -n "$p" ] || return 1
  printf '%s\n' "$p"
}

sweep_owner_allowed() {
  local owner="$1" o
  [ -n "$owner" ] || return 1
  for o in ${PUSH_OWNERS:-}; do
    [ "$owner" = "$o" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# secret scanning
#
# Only the pattern's name and the file:line ever reach the report. The matched
# text is never printed, logged or stored.

sweep_secret_patterns() {
  printf '%s\n' \
    "Hugging Face token${SWEEP_TAB}hf_[A-Za-z0-9]{30,}" \
    "Anthropic API key${SWEEP_TAB}sk-ant-[A-Za-z0-9_-]{20,}" \
    "OpenAI-style API key${SWEEP_TAB}sk-[A-Za-z0-9]{32,}" \
    "GitHub personal access token${SWEEP_TAB}ghp_[A-Za-z0-9]{30,}" \
    "GitHub fine-grained token${SWEEP_TAB}github_pat_" \
    "AWS access key id${SWEEP_TAB}AKIA[0-9A-Z]{16}" \
    "private key block${SWEEP_TAB}-----BEGIN [A-Z ]*PRIVATE KEY-----"
}

# The commit before the oldest commit that is not yet on any remote. That is
# the base of the diff a push would publish.
sweep_push_base() {
  local r="$1" oldest base
  oldest=$(git -C "$r" rev-list HEAD --not --remotes 2>/dev/null | tail -1)
  if [ -z "$oldest" ]; then
    printf '%s\n' "HEAD"
    return 0
  fi
  if base=$(git -C "$r" rev-parse --verify --quiet "$oldest^" 2>/dev/null) && [ -n "$base" ]; then
    printf '%s\n' "$base"
  else
    printf '%s\n' "$SWEEP_EMPTY_TREE"
  fi
}

# Added lines of the pending diff, as "path:line:content", for grepping.
sweep_added_lines() {
  local r="$1" base="$2"
  git -C "$r" diff --no-color --unified=0 "$base" HEAD 2>/dev/null | awk '
    /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
    /^--- /    { next }
    /^@@ /     { n = $3; sub(/^\+/, "", n); split(n, a, ","); l = a[1] + 0; next }
    /^\+/      { print f ":" l ":" substr($0, 2); l++ ; next }
  '
}

# Echoes one line per finding: "<pattern name>\t<path:line>".
sweep_scan_secrets() {
  local r="$1" base="$2"
  local added="$SWEEP_RUNDIR/added.txt" pname pre hit f

  sweep_added_lines "$r" "$base" > "$added"

  while IFS="$SWEEP_TAB" read -r pname pre; do
    [ -n "$pname" ] || continue
    hit=$(grep -a -E -- "$pre" "$added" 2>/dev/null | cut -d: -f1,2 | sort -u | head -3)
    if [ -n "$hit" ]; then
      printf '%s\t%s\n' "$pname" "$(printf '%s' "$hit" | tr '\n' ' ')"
    fi
  done <<EOF
$(sweep_secret_patterns)
EOF

  # Files that should never be published, by name.
  for f in $(git -C "$r" diff --name-only --diff-filter=AM "$base" HEAD 2>/dev/null); do
    case "$(basename "$f")" in
      .env|*.pem) printf 'a credential file by name\t%s\n' "$f" ;;
    esac
  done
  return 0
}

# Blobs in the pending commits that GitHub (or the config) would refuse.
sweep_big_blobs() {
  local r="$1"; shift
  local limit=$(( MAX_PUSH_FILE_MB * 1024 * 1024 ))
  git -C "$r" rev-list --objects "$@" 2>/dev/null |
    git -C "$r" cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null |
    awk -v lim="$limit" '$1 == "blob" && $3 + 0 > lim {
      size = $3; $1 = ""; $2 = ""; $3 = "";
      sub(/^ +/, "");
      if ($0 == "") $0 = "(a file with no name in this commit)";
      printf "%s (%.0f MB)\n", $0, size / 1048576
    }' | head -5
}

# ---------------------------------------------------------------------------
# push

sweep_push_reason() {  # the git output -> plain words, and a hint
  local out="$1" newurl
  case "$out" in
    *"This repository moved"*|*"repository has moved"*)
      newurl=$(printf '%s\n' "$out" |
        sed -n 's|^remote: *\(git@github.com:[^ ]*\)|\1|p;s|^remote: *\(https://github.com/[^ ]*\)|\1|p' |
        head -1)
      printf 'the repo has moved or been renamed. New location: %s\n' "${newurl:-see the run log}"
      return 0 ;;
  esac
  case "$out" in
    *"protected branch"*|*GH006*|*"refusing to allow"*|*"Changes must be made through a pull request"*|*"Required status check"*)
      printf 'the branch is protected, so a push is refused. Open a pull request from a side branch.\n'
      return 0 ;;
    *GH001*|*"exceeds GitHub's file size limit"*|*"large files detected"*)
      printf 'a file in those commits is over GitHub 100 MB limit.\n'
      return 0 ;;
    *"fetch first"*|*"non-fast-forward"*|*"stale info"*|*"behind its remote"*)
      printf 'the remote has commits you do not have. Pull with --rebase first, then sweep will push tomorrow.\n'
      return 0 ;;
    *"Permission denied"*|*"Authentication failed"*|*"could not read Username"*|*"Host key verification failed"*|*"Repository not found"*|*"access rights"*)
      printf 'auth failed: sweep could not authenticate to GitHub from a background job.\n'
      return 0 ;;
  esac
  printf 'the push was rejected. The last line git printed was: %s\n' \
    "$(printf '%s\n' "$out" | grep -v '^remote:' | tail -1)"
}

sweep_is_auth_failure() {
  case "$1" in
    *"Permission denied"*|*"Authentication failed"*|*"could not read Username"*|*"Host key verification failed"*|*"Repository not found"*|*"access rights"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# one repo

sweep_git_repo() {
  local r="$1"
  local name branch url owner upstream counts behind ahead head_short
  local dirty archive

  if ! git -C "$r" rev-parse --git-dir >/dev/null 2>&1; then
    sweep_log "not a git repo, skipped: $r"
    return 0
  fi
  name=$(sweep_repo_label "$r")
  if ! git -C "$r" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    sweep_record_fyi empty_repo "**$(sweep_repo_label "$r")** has no commits yet; sweep left it alone."
    return 0
  fi
  branch=$(git -C "$r" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
  url=$(sweep_remote_url "$r") || url=""

  # --- fetch -------------------------------------------------------------
  if [ -n "$url" ] && [ "$SWEEP_NET" = 1 ] && [ "$SWEEP_AUTH_FAILED" = 0 ]; then
    local fout
    fout=$(sweep_timeout 60 git -C "$r" fetch --prune --quiet 2>&1) || {
      sweep_log "fetch failed in $name: $fout"
      if sweep_is_auth_failure "$fout"; then
        SWEEP_AUTH_FAILED=1
        sweep_record_git auth "$name" \
          "sweep could not authenticate to GitHub, so it stopped trying for this run." \
          "ssh -T git@github.com"
      fi
    }
  fi

  # --- detached HEAD -----------------------------------------------------
  if [ -z "$branch" ]; then
    head_short=$(git -C "$r" rev-parse --short HEAD 2>/dev/null || echo '?')
    sweep_record_git detached "$name" \
      "detached HEAD at $head_short. Commits made here belong to no branch and git will eventually discard them." \
      "git -C $(sweep_disp "$r") switch -c rescue-$head_short"
  fi

  # --- no remote ---------------------------------------------------------
  if [ -z "$url" ]; then
    sweep_record_git no_remote "$name" \
      "no remote at all, so nothing in it is backed up anywhere." \
      "cd $(sweep_disp "$r") && gh repo create daltonoscar0/$(basename "$r") --private --source . --push"
  fi

  # --- tracked files deleted in the working tree -------------------------
  local dellist="$SWEEP_RUNDIR/deleted.txt" ndel
  git -C "$r" ls-files --deleted > "$dellist" 2>/dev/null
  if [ -s "$dellist" ]; then
    archive=$(find "$r" -maxdepth 2 -name '*-archive-*.tar.gz' 2>/dev/null | head -1)
    local dir count hint extra
    awk -F/ '{ if (NF > 1) { d = $1; for (i = 2; i < NF; i++) d = d "/" $i } else d = "."; print d }' \
      "$dellist" | sort | uniq -c | sort -rn | head -5 |
    while read -r count dir; do
      [ -n "$dir" ] || continue
      extra=""
      if [ -n "$archive" ]; then
        extra=" An archive ($(basename "$archive")) is sitting in the repo, so they were probably archived rather than lost."
      fi
      [ "$dir" = "." ] && hint="." || hint="$dir"
      sweep_record_git deleted_tracked "$name" \
        "$count tracked file(s) missing from \`$hint\`. A \`git add -A\` here would delete them from GitHub too.$extra" \
        "git -C $(sweep_disp "$r") restore $hint"
    done
  fi

  # --- big untracked files ----------------------------------------------
  local f bytes mb ext
  git -C "$r" ls-files --others --exclude-standard -z 2>/dev/null |
  while IFS= read -r -d '' f; do
    [ -f "$r/$f" ] || continue
    bytes=$(stat -f %z "$r/$f" 2>/dev/null) || continue
    [ "$bytes" -gt $(( 50 * 1024 * 1024 )) ] || continue
    mb=$(( bytes / 1048576 ))
    ext=${f##*/}
    case "$ext" in
      *.*) ext="*.${ext##*.}" ;;
      *)   ext="$f" ;;
    esac
    sweep_record_git large_untracked "$name" \
      "\`$f\` is ${mb} MB and untracked. GitHub refuses anything over 100 MB, so decide before it ends up in a commit." \
      "echo '$ext' >> $(sweep_disp "$r")/.gitignore"
  done

  # --- committed caches --------------------------------------------------
  git -C "$r" ls-files -- '*__pycache__*' '*.pyc' '*.DS_Store' '.DS_Store' 2>/dev/null |
    sed 's|/__pycache__/.*|/__pycache__|' | sort -u | head -5 |
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sweep_record_fyi_once committed_cache \
      "\`$(sweep_disp "$r/$f")\` is committed; \`git rm -r --cached\` it and add it to .gitignore"
  done

  # --- uncommitted changes ----------------------------------------------
  dirty=$(git -C "$r" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "${dirty:-0}" -gt 0 ]; then
    sweep_record_fyi dirty "**$name** has $dirty uncommitted change(s). sweep only ever pushes commits, so these stay yours to deal with."
  fi

  # --- upstream, ahead, behind ------------------------------------------
  upstream=$(git -C "$r" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream=""
  behind=0
  ahead=0
  if [ -n "$upstream" ]; then
    counts=$(git -C "$r" rev-list --left-right --count "$upstream...HEAD" 2>/dev/null)
    behind=$(printf '%s\n' "$counts" | awk '{print $1 + 0; exit}')
    ahead=$(printf '%s\n' "$counts" | awk '{print $2 + 0; exit}')
  elif [ -n "$branch" ] && [ -n "$url" ]; then
    ahead=$(git -C "$r" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
    sweep_record_fyi no_upstream "**$name** branch \`$branch\` has no upstream. sweep will push it with \`-u\` when the owner is yours."
  fi
  [ -n "$behind" ] || behind=0
  [ -n "$ahead" ] || ahead=0

  if [ "$behind" -gt 0 ]; then
    sweep_record_git behind "$name" \
      "$behind commit(s) on \`$upstream\` that you do not have locally. sweep never pulls, so this is yours." \
      "git -C $(sweep_disp "$r") pull --rebase"
  fi

  # --- push --------------------------------------------------------------
  sweep_maybe_push "$r" "$name" "$branch" "$url" "$upstream" "$ahead" "$behind"
  return 0
}

sweep_maybe_push() {
  local r="$1" name="$2" branch="$3" url="$4" upstream="$5" ahead="$6" behind="$7"
  local owner base secrets big out rc pname where reason

  [ -n "$branch" ] || return 0                 # detached: never push
  [ -n "$url" ] || return 0                    # no remote to push to
  # With an upstream there has to be something ahead. Without one, pushing is
  # what puts the branch on GitHub in the first place, so it always goes.
  if [ -n "$upstream" ] && [ "$ahead" -eq 0 ]; then return 0; fi

  if [ "${AUTO_PUSH:-1}" != 1 ]; then
    sweep_record_fyi push_off "**$name** has $ahead commit(s) to push, but AUTO_PUSH=0."
    return 0
  fi

  owner=$(sweep_repo_owner "$r" "$url") || owner=""
  if ! sweep_owner_allowed "$owner"; then
    sweep_record_fyi other_owner \
      "**$name** has $ahead commit(s) not on its remote, but the remote belongs to ${owner:-nobody sweep recognises} rather than you, so sweep will not push it."
    return 0
  fi

  if [ "$behind" -gt 0 ]; then
    sweep_log "not pushing $name: behind by $behind"
    return 0
  fi

  if [ "$SWEEP_NET" != 1 ]; then
    sweep_record_fyi offline_push "**$name** has $ahead commit(s) to push; sweep was offline."
    return 0
  fi
  if [ "$SWEEP_AUTH_FAILED" = 1 ]; then
    sweep_log "not pushing $name: auth already failed this run"
    return 0
  fi

  base=$(sweep_push_base "$r")

  # A blob GitHub would refuse.
  if [ -n "$upstream" ]; then
    big=$(sweep_big_blobs "$r" "$upstream..HEAD")
  else
    big=$(sweep_big_blobs "$r" HEAD --not --remotes)
  fi
  if [ -n "$big" ]; then
    sweep_record_git too_big "$name" \
      "not pushed: those commits contain a blob over ${MAX_PUSH_FILE_MB} MB ($(printf '%s' "$big" | tr '\n' ';' | sed 's/;$//')). Rewriting history is the only way out, so sweep leaves it to you." \
      "git -C $(sweep_disp "$r") log --oneline $([ -n "$upstream" ] && printf '%s..HEAD' "$upstream" || printf 'HEAD --not --remotes')"
    return 0
  fi

  # A secret in what would be published.
  secrets=$(sweep_scan_secrets "$r" "$base")
  if [ -n "$secrets" ]; then
    while IFS="$SWEEP_TAB" read -r pname where; do
      [ -n "$pname" ] || continue
      sweep_record_git secret "$name" \
        "NOT PUSHED: what looks like a $pname is in the diff, at $where. sweep shows the place, never the value." \
        "git -C $(sweep_disp "$r") log -p -S'<the value>' -- $(printf '%s' "$where" | cut -d: -f1)"
    done <<EOF
$secrets
EOF
    return 0
  fi

  if [ "${SWEEP_DRY_RUN:-0}" = 1 ]; then
    sweep_record_push would_push "$name" "$branch" "$ahead" \
      "$([ -z "$upstream" ] && printf 'with -u (no upstream yet)' || printf 'to %s' "$upstream")"
    sweep_log "would push $name $branch ($ahead commits)"
    return 0
  fi

  if [ -z "$upstream" ]; then
    out=$(sweep_timeout 60 git -C "$r" push -u origin "$branch" 2>&1)
    rc=$?
  else
    out=$(sweep_timeout 60 git -C "$r" push origin "$branch" 2>&1)
    rc=$?
  fi
  sweep_log "push $name $branch rc=$rc: $(printf '%s' "$out" | tr '\n' ' ')"

  if [ "$rc" -eq 0 ]; then
    sweep_record_push pushed "$name" "$branch" "$ahead" \
      "$([ -z "$upstream" ] && printf 'new branch, upstream set' || printf 'to %s' "$upstream")"
    return 0
  fi

  reason=$(sweep_push_reason "$out")
  if sweep_is_auth_failure "$out"; then
    if [ "$SWEEP_AUTH_FAILED" = 0 ]; then
      SWEEP_AUTH_FAILED=1
      sweep_record_git auth "$name" \
        "auth failed: sweep could not authenticate to GitHub, so it stopped pushing for this run. Check that ~/.ssh/config has AddKeysToAgent and UseKeychain for github.com." \
        "ssh -T git@github.com"
    fi
    return 0
  fi
  sweep_record_git push_rejected "$name" "$branch: $reason" \
    "git -C $(sweep_disp "$r") push origin $branch"
  return 0
}

# ---------------------------------------------------------------------------
# the tier

sweep_git_check() {
  [ -d "${CODE_DIR:-}" ] || return 0

  GIT_TERMINAL_PROMPT=0; export GIT_TERMINAL_PROMPT
  GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
  export GIT_SSH_COMMAND

  if sweep_wait_for_network; then
    SWEEP_NET=1
  else
    SWEEP_NET=0
    sweep_record_git offline "-" \
      "github.com was unreachable for five minutes, so nothing was fetched or pushed this run. The local picture below may be out of date." \
      ""
  fi

  local repo n=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    [ -d "$repo" ] || continue
    n=$((n + 1))
    sweep_git_repo "$repo"
  done <<EOF
$(sweep_find_repos)
EOF
  sweep_log "checked $n repos (network=$SWEEP_NET)"
  SWEEP_REPO_COUNT=$n
  return 0
}
