# Notes for agents working on sweep

Read `README.md` first; it is the user-facing description and it is accurate.
These are the things that are easy to get wrong.

## Hard constraints

- **bash 3.2** (the macOS system bash). No associative arrays, no `${var,,}`,
  no `mapfile`, no `declare -A`, no `&>>`. BSD tools only: `stat -f`, BSD
  `find`, `sed -i ''`, no `timeout` (use `sweep_timeout`).
- `local a=1 b=$a` does **not** work: bash expands every word of `local`
  before assigning any of them. Use separate statements.
- No dependency may be required to run. `shellcheck` is used if installed and
  skipped otherwise.
- Never ask for a password, token or key, and never write a credential to disk.
  The secret scanner must only ever record a pattern's name and `file:line`.

## The rules that must not regress

1. **`sweep_safe_rm` in `lib/common.sh` is the only code that deletes.** If you
   add a tier, call it; do not call `rm` yourself. It enforces the allowlist in
   `sweep_safe_roots`, refuses `$HOME`, roots, symlinks and `..`, records the
   size and path to the run log, and does nothing in dry-run.
2. **`git push` is the only git write.** No `add`, `commit`, `stash`, `pull`,
   `rebase`, `restore`, `--force` or tags, ever. Everything else is reported
   with the command Oscar would run.
3. **`PUSH_OWNERS`.** Repos owned by anyone else are never pushed on any
   branch. `nyusemantics/LambdaCalculator` and `tristancchoi-svg/Goldfish` are
   real repos in `~/code` that belong to other people.
4. **Tracked files are sacred.** A `__pycache__` that is committed gets
   reported, not deleted; deleting it would stage a deletion. Missing tracked
   files get a `git restore` hint, never a fix.
5. **Dry-run writes a full report and changes nothing**, including the
   once-per-day marker, so a dry run never costs him the real run.

## Things that look like bugs but are not

- `TILDE='~'` exists because `${p/#$HOME/\~}` keeps the backslash in bash 3.2.
  Always display paths with `sweep_disp`. A test asserts the report contains no
  backslash at all.
- Project-cache discovery prunes `.venv*`, `venv*`, `site-packages`,
  `node_modules` and `.git`. The real repo that broke this was
  `.venv-extract/lib/python3.12/site-packages/...`.
- Hugging Face "last used" is the newest of three timestamps, not the atime,
  because APFS atimes are unreliable. See the README.
- `sweep_clean_logs` prunes `~/Library/Logs/sweep`, or sweep would delete its
  own reports.
- The light tier may empty `~/Library/Caches/Homebrew` before the weekly tier
  runs `brew cleanup`. That is fine; the sizes are attributed to whichever got
  there first.
- `sweep_load_config` snapshots environment overrides once
  (`SWEEP_ENV_SNAPSHOT`), because after the first call the config variables are
  set either way and it could no longer tell them apart.

## Testing

`bash test/run.sh`, about two minutes (it makes a lot of small git repos).
`test/helpers.sh` gives each case a throwaway `$HOME`. Ages are measured from
`SWEEP_NOW`, via `t_age` / `t_age_tree`, so no test depends on the real clock.

Hooks that only exist for tests, all gated on `SWEEP_TESTING=1`:
`SWEEP_NOW`, `SWEEP_FAKE_FREE_KB` (a simulated disk that grows as sweep
deletes), `SWEEP_FAKE_NETWORK`, `SWEEP_FAKE_BATT`,
`SWEEP_TEST_OWNER_OVERRIDE` and `.git/sweep-test-owner`. `SWEEP_TESTING=1` also
blocks every shell-out to `brew`, `pnpm`, `xcrun`, `docker`, `launchctl`,
`osascript`, `softwareupdate` and `tmutil`, so the suite is safe to run on
Oscar's own machine. Keep it that way: a test that schedules a LaunchAgent,
prunes Homebrew or asks Apple what updates are pending is a broken test.
Where a probe parses an external tool's output, split the parser from the call
(`sweep_parse_updates`, `sweep_parse_snapshots`) and test it on captured
output; the two `sort`s in those are `LC_ALL=C` so CI's Linux and macOS agree.

If you add a behaviour, add a case in `test/cases/`. One file per behaviour,
and assertion descriptions read as sentences in the output.
