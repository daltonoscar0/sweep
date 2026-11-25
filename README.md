# sweep

Once a day, early in the morning, `sweep` removes the regenerable clutter from
this Mac, checks that every git repo under `~/code` is actually backed up to
GitHub, pushes the ones that are safe to push, and leaves a short report.

It is one bash script with no dependencies: the bash 3.2 that ships with macOS,
plus `git`, `launchd` and the usual BSD tools. No Python, no Homebrew packages,
nothing to install.

```
sweep run [--dry-run] [--now] [--force]   one pass (what launchd calls)
sweep install                             write and load the LaunchAgent
sweep uninstall                           unload and remove it
sweep status                              installed?, last run, free space
sweep report                              print the latest report
```

## Install

```sh
cd ~/code/sweep
bin/sweep install
sweep run --now
sweep report
```

`install` symlinks `bin/sweep` into `~/.local/bin`, writes
`~/.config/sweep/config` if it is missing (it never overwrites an existing
one), writes and loads the LaunchAgent, and prints the two settings it
deliberately leaves to you. If `~/.local/bin` is not on your `PATH` it prints
the line to add to `~/.zshrc`; it does not edit `~/.zshrc` for you.

## How the scheduling works

A user LaunchAgent at `~/Library/LaunchAgents/com.daltonoscar0.sweep.plist`:

- `StartCalendarInterval` at **04:30**. If the Mac is asleep or off at 04:30,
  launchd runs the missed job at the next wake rather than skipping it.
- `RunAtLoad`, which covers the first login after a shutdown.
- `ProcessType Background`, `LowPriorityIO`, `Nice 10`, so it stays out of the
  way of anything you are doing.

Those triggers can fire several times a day. A guard inside the script makes
all but the first a no-op: a sweep "day" starts at **03:00**, and once a run
has finished successfully in the current day, further runs exit immediately.
`--force` ignores the guard. A `mkdir`-based lock in
`~/.local/state/sweep/` stops two runs from overlapping (and goes stale after
two hours, in case a run is killed).

Unless you pass `--now`, a run waits `START_DELAY` seconds (120 by default)
before starting, so waking the lid or logging in never feels slower. On battery
below 30% only the light tier runs, and the report says so.

## What it deletes

Everything below is regenerated automatically by the thing that made it. Every
single deletion goes through one function, `safe_rm`, which refuses `$HOME`,
any filesystem root, symlinks, paths containing `..`, and anything outside the
allowlist of cache roots.

**Light tier, every run**

| | |
|---|---|
| App caches | the contents of each folder in `~/Library/Caches` that is at least `CACHE_MIN_MB`, is not in `CACHE_SKIP`, and has had nothing inside it touched for `CACHE_ACTIVE_HOURS` (an open app is always skipped). The folder itself is kept. |
| Logs | files in `~/Library/Logs` older than `LOG_MAX_AGE_DAYS`. sweep's own reports are excluded. |
| Project caches | `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.ipynb_checkpoints` and `.hypothesis` inside `CODE_DIR`. Virtual environments, `site-packages`, `node_modules` and `.git` are pruned, not descended into. Anything tracked by git is kept and reported instead. |
| Xcode | `DerivedData` subfolders with no build in `DERIVED_DATA_MAX_AGE_DAYS` days. |

**Weekly tier** (Sundays, or whenever more than seven days have passed)

| | |
|---|---|
| Package managers | `~/.npm/_cacache`, then `uv cache prune`, `pip cache purge`, `brew cleanup -s --prune=all` and `pnpm store prune` for whichever of those exist. Each gets a five-minute limit; a failure is reported, not fatal. |
| Simulators | iOS DeviceSupport down to the newest `DEVICE_SUPPORT_KEEP` folders, plus `xcrun simctl delete unavailable`. |

**Low-space tier** (only when less than `LOW_SPACE_GB` is still free after the above)

| | |
|---|---|
| Hugging Face | `models--*` and `datasets--*` under `~/.cache/huggingface/hub` that have not been used in `HF_MAX_IDLE_DAYS`, longest idle first, stopping as soon as there is room again. Anything matching `KEEP_HF` is never deleted. |
| Report only | the ten largest files over 1 GB under `$HOME` (excluding `~/Library`), and the total size of Downloads older than 90 days. Neither is deleted. |

### How "not used in N days" is decided for Hugging Face

APFS does not update access times reliably, so the atime of a model's blobs on
its own is not trustworthy. sweep takes the **newest** of three things: the
mtime of `refs/*` (rewritten whenever a revision is resolved), the mtime of
`snapshots/*`, and the atime of the blobs. If all three are missing it falls
back to the directory's own mtime. Erring towards "recently used" means a model
you are actually using is never deleted; the cost is occasionally keeping one
you are not.

`HF_HOME` is deliberately ignored: only `~/.cache/huggingface` is in the
`safe_rm` allowlist, so a cache you moved elsewhere is never touched.

## What it never touches, by design

- **The Trash.** A launchd job cannot see `~/.Trash` without Full Disk Access,
  and sweep is not going to ask for that. Turn on the built-in equivalent:
  Finder → Settings → Advanced → "Remove items from the Trash after 30 days".
- **Docker.** Reported by size when `docker` exists; never pruned.
- Mail, Messages, Photos, MobileSync (phone) backups, `~/Library/Containers`,
  `~/Library/Application Support`, `~/Library/Developer/Xcode/Archives`.
- Anything in `~/Downloads`.
- Any file tracked by git, any virtual environment, any `node_modules`.
- Documents, Desktop, and everything else that is not in the allowlist above.

## The git backup check

Every run, after the cleanup, sweep finds every directory containing `.git` up
to three levels under `CODE_DIR` (so `~/code/archive/ml/*` and
`morphology/external/tknzn4Irish` are both included; anything inside a venv or
`node_modules` is not), fetches with a 60-second limit, and reports:

- **detached HEAD** -- loudly, because commits made there belong to no branch
  and git will eventually discard them;
- **no remote at all**, so nothing in the repo is backed up anywhere;
- **tracked files missing from the working tree**, grouped by directory with a
  count and a `git restore` command. If an untracked `*-archive-*.tar.gz` is
  sitting in the repo, sweep says the files were probably archived rather than
  lost. This is the case that matters most: a blind `git add -A` in that state
  deletes the results from GitHub too;
- **untracked files over 50 MB**, with a `.gitignore` line to consider;
- **committed caches** (`__pycache__`, `*.pyc`, `.DS_Store` under version control);
- **uncommitted changes**, as a count;
- **branches with no upstream**;
- **behind upstream** -- reported with `git pull --rebase` as the fix. sweep
  never pulls, never rebases, never merges;
- **ahead of upstream**, which is what gets pushed.

### When sweep pushes

Only when every one of these is true:

1. `AUTO_PUSH=1`;
2. the remote is a `github.com` URL (both `git@github.com:owner/repo.git` and
   `https://github.com/owner/repo.git` are understood) whose **owner is listed
   in `PUSH_OWNERS`**. Repos belonging to anyone else -- `nyusemantics/
   LambdaCalculator`, `tristancchoi-svg/Goldfish` -- are never pushed, on any
   branch;
3. HEAD is on a branch, and that branch is not behind its upstream;
4. there is something to send: commits ahead, or a branch with no upstream yet
   (which gets `git push -u origin <branch>`);
5. no blob in the pending commits is larger than `MAX_PUSH_FILE_MB`;
6. no secret pattern appears in the diff being published.

sweep never uses `--force` and never pushes tags. It never runs `git add`,
`git commit` or `git stash`: pushing only sends commits that already exist.

The secret scan looks at the **added lines** of the pending diff, so something
already on GitHub does not block every future push, and at the names of added
files (`.env`, `*.pem`). It looks for Hugging Face, Anthropic, OpenAI-style and
GitHub tokens, AWS access key ids and private key blocks. When it finds one the
repo goes to the top of the report with the pattern's **name** and the
`file:line` -- never the value. Nothing matched is written to the report, the
run log, or anywhere else.

A rejected push is translated into plain words: protected branch ("open a pull
request from a side branch"), remote ahead ("pull --rebase first"), repo
renamed (with the new URL git printed), file too large. If authentication
fails, sweep says so once and stops pushing for that run rather than hammering
GitHub.

### SSH from a background job

For pushes to work from launchd, `~/.ssh/config` should contain:

```
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
```

With that plus a one-time `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`, the
key comes from the login keychain and nothing ever prompts. HTTPS remotes use
the macOS keychain credential helper and need nothing extra. sweep sets
`GIT_TERMINAL_PROMPT=0` and `ssh -o BatchMode=yes`, so a missing credential
fails fast and is reported instead of hanging until the timeout.

## The report

`~/Library/Logs/sweep/YYYY-MM-DD.md`, copied to `latest.md`, thirty days kept.
The full per-path deletion log is `YYYY-MM-DD.log` next to it. `sweep report`
prints the latest one.

The top of it is only for things that need you, each with the one command that
fixes or investigates it. Then what was pushed, then a table of what was
cleaned, then an FYI section, then the setup notes. When `NOTIFY=1` sweep posts
at most one macOS notification per run, and only when it freed more than
500 MB, pushed something, or found something that needs you.

## Config

`~/.config/sweep/config` is sourced as bash, so it is `KEY=value` lines. It is
created by `sweep install` and never overwritten. Environment variables win
over the file, which is handy for one-off runs:
`LOW_SPACE_GB=40 sweep run --now --force`.

```sh
CODE_DIR="$HOME/code"
LOW_SPACE_GB=20                 # below this, the low-space tier runs
KEEP_HF="distilroberta-base"    # substrings of HF repo ids never deleted
HF_MAX_IDLE_DAYS=21
DERIVED_DATA_MAX_AGE_DAYS=7
DEVICE_SUPPORT_KEEP=2           # newest N iOS DeviceSupport folders kept
LOG_MAX_AGE_DAYS=14
CACHE_MIN_MB=20                 # smaller app caches are left alone
CACHE_ACTIVE_HOURS=6            # skip caches touched this recently
CACHE_SKIP="com.apple.Safari com.apple.akd com.apple.accountsd"
AUTO_PUSH=1                     # 0 pauses pushing; everything is still reported
PUSH_OWNERS="daltonoscar0"      # only these GitHub owners are ever pushed to
MAX_PUSH_FILE_MB=95
NOTIFY=1
START_DELAY=120                 # seconds to wait before starting (--now skips)
```

## How to pause it

| | |
|---|---|
| Stop pushing, keep cleaning | `AUTO_PUSH=0` in the config |
| Stop cleaning, keep reporting | run it yourself with `--dry-run`, and `sweep uninstall` |
| Stop everything | `sweep uninstall` (keeps your config and reports) |
| One quiet day | nothing to do; `sweep status` shows when it last ran |

## Tests

```sh
bash test/run.sh            # everything
bash test/run.sh safe_rm    # cases matching a name
VERBOSE=1 bash test/run.sh  # show every assertion
```

`bash -n` over every file, `shellcheck` if it happens to be installed, then one
process per case. Every case builds a throwaway `$HOME` in a temp directory and
sets `HOME`, `CODE_DIR`, `SWEEP_NOW` (the clock), `SWEEP_FAKE_FREE_KB` (the
disk) and `SWEEP_FAKE_NETWORK`, so nothing on the real machine is read or
written. Remotes are local bare repos. `SWEEP_TESTING=1` also stops sweep from
ever shelling out to `brew`, `pnpm`, `xcrun`, `docker`, `launchctl` or
`osascript`, and is required before any of the fake-clock or
`SWEEP_TEST_OWNER_OVERRIDE` hooks do anything at all.

## Why bash 3.2 and not something nicer

It has to run from launchd on a Mac with nothing installed, including the
morning after a clean install, and it has to be readable in five years. That
rules out associative arrays, `${var,,}`, `mapfile`, GNU `stat`, GNU `sed -i`
and `timeout`. Two bugs from the hand-written script this replaces are now
tested against: printing `\~` instead of `~` (bash 3.2 keeps the backslash in
`${p/#$HOME/\~}`, so sweep uses a `TILDE` variable), and descending into
`.venv-extract` and friends while looking for `__pycache__`.
