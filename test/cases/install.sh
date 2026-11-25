#!/bin/bash
# install, uninstall and status. launchctl itself is never called under
# SWEEP_TESTING, so running this suite cannot schedule anything on a real Mac.
. "$(dirname "$0")/../helpers.sh"

t_home

out=$(t_sweep install 2>&1)
PLIST="$HOME/Library/LaunchAgents/com.daltonoscar0.sweep.plist"

echo "install"
assert_true     'the plist was written'        test -f "$PLIST"
assert_true     'and it is a valid plist'      plutil -lint "$PLIST"
assert_true     'the config was created'       test -f "$HOME/.config/sweep/config"
assert_true     'sweep is on PATH as a symlink' test -L "$HOME/.local/bin/sweep"
assert_eq       'pointing at this checkout'    "$(readlink "$HOME/.local/bin/sweep")" "$SWEEP_SRC/bin/sweep"
assert_not_contains 'launchctl was not called' "$out" "Loaded with"
assert_contains 'and install says why'         "$out" "Not loading it: SWEEP_TESTING is set."

echo "what the plist asks launchd for"
plist=$(cat "$PLIST")
assert_contains 'the label'                    "$plist" "<string>com.daltonoscar0.sweep</string>"
assert_contains 'bash runs it'                 "$plist" "<string>/bin/bash</string>"
assert_contains 'with an absolute path'        "$plist" "<string>$SWEEP_SRC/bin/sweep</string>"
assert_contains 'and the run subcommand'       "$plist" "<string>run</string>"
assert_contains '04:30'                        "$(printf '%s' "$plist" | tr -d ' \t\n')" "<key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer>"
assert_contains 'RunAtLoad for the first login after a shutdown' "$plist" "<key>RunAtLoad</key>"
assert_contains 'a background process type'    "$plist" "<key>ProcessType</key>"
assert_contains 'Background'                   "$plist" "<string>Background</string>"
assert_contains 'low priority IO'              "$plist" "<key>LowPriorityIO</key>"
assert_contains 'nice 10'                      "$(printf '%s' "$plist" | tr -d ' \t\n')" "<key>Nice</key><integer>10</integer>"
assert_contains 'stdout in the log dir'        "$plist" "$HOME/Library/Logs/sweep/launchd.out.log"
assert_contains 'stderr too'                   "$plist" "$HOME/Library/Logs/sweep/launchd.err.log"
assert_contains 'a PATH with homebrew first'   "$plist" "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "install tells him the three things sweep will not do for him"
assert_contains 'the Trash setting'            "$out" "Remove items from the Trash after 30 days"
assert_contains 'the ssh config'               "$out" "AddKeysToAgent yes"
assert_contains 'and UseKeychain'              "$out" "UseKeychain yes"
assert_contains 'what to run next'             "$out" "sweep run --now"
assert_contains 'the PATH line, printed not edited' "$out" 'export PATH="$HOME/.local/bin:$PATH"'
assert_false    'and .zshrc was not touched'   test -f "$HOME/.zshrc"

echo "a second install keeps the config"
printf 'LOW_SPACE_GB=7\n' > "$HOME/.config/sweep/config"
out2=$(t_sweep install 2>&1)
assert_contains 'it says so'                   "$out2" "Kept your existing"
assert_eq       'and it really is kept'        "$(cat "$HOME/.config/sweep/config")" "LOW_SPACE_GB=7"

echo "status"
st=$(t_sweep status 2>&1)
assert_contains 'the agent is reported installed' "$st" "LaunchAgent: installed"
assert_contains 'with no run yet'              "$st" "last run:    never"
assert_contains 'free space now'               "$st" "free now:"
assert_contains 'and the push setting'         "$st" "auto-push:   on (owners: daltonoscar0)"

t_sweep run --now >/dev/null 2>&1
st=$(t_sweep status 2>&1)
assert_contains 'after a run the time is shown' "$st" "last run:    $(date -r "$SWEEP_NOW" '+%Y-%m-%d %H:%M')"
assert_contains 'with the free-space numbers'   "$st" "free space:"

echo "uninstall"
un=$(t_sweep uninstall 2>&1)
assert_false 'the plist is gone'               test -f "$PLIST"
assert_false 'the symlink is gone'             test -L "$HOME/.local/bin/sweep"
assert_true  'the config is kept'              test -f "$HOME/.config/sweep/config"
assert_true  'and so are the reports'          test -f "$HOME/Library/Logs/sweep/latest.md"
assert_contains 'which it says'                "$un" "Kept your config"
assert_contains 'status agrees'                "$(t_sweep status 2>&1)" "LaunchAgent: not installed"

echo "no report yet is not an error"
t_home
assert_contains 'it suggests a run'            "$(t_sweep report)" "No report yet. Run: sweep run --now"
assert_contains 'help lists the subcommands'   "$(t_sweep --help)" "sweep install"
assert_false    'an unknown command fails'     t_sweep frobnicate

t_end
