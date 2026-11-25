#!/bin/bash
# test/helpers.sh -- sourced by every case in test/cases/.
#
# Each case gets a throwaway $HOME in a temp directory, so no test can touch
# anything real. Time comes from SWEEP_NOW and free space from
# SWEEP_FAKE_FREE_KB, both of which sweep only honours when SWEEP_TESTING=1.

set -u

: "${SWEEP_SRC:?set SWEEP_SRC to the repo root (test/run.sh does this)}"

export SWEEP_TESTING=1

T_FAILED=0
T_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sweeptest.XXXXXX") || exit 1
T_REAL_HOME="$HOME"

t_cleanup() { [ -n "${T_TMP:-}" ] && rm -rf "$T_TMP"; }
trap t_cleanup EXIT

t_ok()   { printf '  ok   %s\n' "$1"; }
t_fail() { printf '  FAIL %s\n' "$1"; T_FAILED=1; }
t_end()  { exit "$T_FAILED"; }

assert_true() {  # desc cmd...
  local desc="$1"; shift
  if "$@"; then t_ok "$desc"; else t_fail "$desc"; fi
}
assert_false() { # desc cmd...
  local desc="$1"; shift
  if "$@"; then t_fail "$desc (expected failure)"; else t_ok "$desc"; fi
}
assert_eq() {    # desc got want
  if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1 (got '$2', want '$3')"; fi
}
assert_contains() {     # desc haystack needle
  case "$2" in *"$3"*) t_ok "$1" ;; *) t_fail "$1 (missing '$3')" ;; esac
}
assert_not_contains() { # desc haystack needle
  case "$2" in *"$3"*) t_fail "$1 (unexpectedly contains '$3')" ;; *) t_ok "$1" ;; esac
}
assert_exists()  { if [ -e "$2" ]; then t_ok "$1"; else t_fail "$1 ($2 is gone)"; fi }
assert_missing() { if [ -e "$2" ]; then t_fail "$1 ($2 still there)"; else t_ok "$1"; fi }
assert_empty_dir() {
  if [ -d "$2" ] && [ -z "$(ls -A "$2" 2>/dev/null)" ]; then t_ok "$1"
  else t_fail "$1 ($2 is not an empty directory)"; fi
}

# A fresh fake home. Call once per case (or again for a clean slate).
t_home() {
  HOME="$T_TMP/home"
  rm -rf "$HOME"
  mkdir -p "$HOME/Library/Caches" "$HOME/Library/Logs" "$HOME/Library/LaunchAgents" \
           "$HOME/.config/sweep" "$HOME/.local/state/sweep" "$HOME/.local/bin" \
           "$HOME/code" "$HOME/Downloads"
  export HOME
  export CODE_DIR="$HOME/code"
  export START_DELAY=0
  export NOTIFY=0
  export SWEEP_FAKE_NETWORK=1
  export SWEEP_FAKE_BATT=100
  export SWEEP_NOW="${SWEEP_NOW:-$(date +%s)}"
  # git needs an identity and must not read Oscar's real config
  export GIT_CONFIG_NOSYSTEM=1
  cat > "$HOME/.gitconfig" <<'GITCONFIG'
[user]
	name = sweep tests
	email = tests@example.invalid
[init]
	defaultBranch = main
[commit]
	gpgsign = false
[advice]
	detachedHead = false
GITCONFIG
}

# Run sweep as a subprocess, inheriting the fake home.
t_sweep() { bash "$SWEEP_SRC/bin/sweep" "$@"; }

# Source the libraries into this shell and set up a run context, for the cases
# that test one function rather than a whole run.
t_load() {
  . "$SWEEP_SRC/lib/common.sh"
  . "$SWEEP_SRC/lib/clean.sh"
  . "$SWEEP_SRC/lib/git.sh"
  . "$SWEEP_SRC/lib/report.sh"
  sweep_paths
  sweep_load_config
  sweep_run_init
}

# A file of a given size in MB, with an optional mtime N days in the past.
t_mkfile() {  # path mb [age_days]
  local path="$1" mb="$2" age="${3:-}"
  mkdir -p "$(dirname "$path")"
  dd if=/dev/zero of="$path" bs=1048576 count="$mb" 2>/dev/null
  [ -n "$age" ] && t_age "$path" "$age"
  return 0
}

# Ages are measured from SWEEP_NOW, the same clock sweep uses, so that
# "21 days idle" means exactly that and no test is a second away from flaky.
t_stamp() { date -r $(( SWEEP_NOW - $1 )) +%Y%m%d%H%M.%S; }

t_age()       { touch -t "$(t_stamp $(( $2 * 86400 )))" "$1"; }  # path days
t_age_hours() { touch -t "$(t_stamp $(( $2 * 3600 )))" "$1"; }   # path hours

# Age a whole tree, deepest entries included.
t_age_tree() { # path days
  find "$1" -print0 | xargs -0 -n 50 touch -t "$(t_stamp $(( $2 * 86400 )))"
}

# A repo with one commit, plus a bare "remote" it is up to date with.
t_mkrepo() {  # name  -> echoes the repo path
  # bash expands every word of "local" before assigning any of them, so these
  # cannot be one statement.
  local name repo remote
  name="$1"
  repo="$CODE_DIR/$name"
  remote="$T_TMP/remotes/$name.git"
  mkdir -p "$repo" "$(dirname "$remote")"
  git init -q --bare "$remote"
  git init -q "$repo"
  printf '# %s\n' "$name" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "first"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q -u origin main 2>/dev/null
  printf '%s\n' "$repo"
}

# Pretend a repo's origin belongs to someone on GitHub. sweep only reads this
# when SWEEP_TESTING=1.
# Kept inside .git so it does not show up as an untracked file.
t_own() { printf '%s\n' "$2" > "$1/.git/sweep-test-owner"; }

t_commit() {  # repo file content [message]
  local repo="$1" file="$2"
  mkdir -p "$(dirname "$repo/$file")"
  printf '%s\n' "$3" > "$repo/$file"
  git -C "$repo" add -- "$file"
  git -C "$repo" commit -qm "${4:-change $file}"
}

t_report() { cat "$HOME/Library/Logs/sweep/latest.md" 2>/dev/null; }
