#!/bin/bash
# Free space that went away without sweep's help.
#
# The case this exists for: on 2026-11-25 the disk lost about 15 GB in two
# hours while sweep had removed 38 MB. macOS had staged an OS update, which
# lives outside the home folder and so is invisible to every tier. From the
# tiers' own numbers the only available conclusion was "sweep is not working",
# which was wrong.
#
# SWEEP_TESTING=1 stops the probes shelling out to softwareupdate or tmutil on
# a real Mac, so these test the threshold, the arithmetic and the wording. The
# two probes' parsers are tested separately, on captured output.
. "$(dirname "$0")/../helpers.sh"

t_home
export SWEEP_TESTING=1
t_load

GB=1048576

echo "the threshold"

drop_from_to() {  # previous_gb now_gb
  : > "$SWEEP_FYI"
  sweep_state_set last_free_after_kb $(( $1 * GB ))
  sweep_fyi_space_drop $(( $2 * GB ))
}

drop_from_to 100 96      # 4 GB
assert_eq 'a 4 GB drop is ordinary churn and is not reported' \
  "$(sweep_count_kind "$SWEEP_FYI" space_drop)" "0"

drop_from_to 100 95      # exactly 5 GB
assert_eq 'exactly 5 GB is reported' \
  "$(sweep_count_kind "$SWEEP_FYI" space_drop)" "1"

drop_from_to 100 85      # the real 15 GB
assert_eq 'the 15 GB that prompted this is reported' \
  "$(sweep_count_kind "$SWEEP_FYI" space_drop)" "1"
assert_contains 'with the size of the drop' "$(cat "$SWEEP_FYI")" "down 15.0 GB"
assert_contains 'and where it is now'       "$(cat "$SWEEP_FYI")" "now 85.0 GB"
assert_contains 'and says it was not sweep' "$(cat "$SWEEP_FYI")" "not something sweep did"

echo "space going up, or staying put, is not news"
drop_from_to 85 100
assert_eq 'free space rising is not reported' \
  "$(sweep_count_kind "$SWEEP_FYI" space_drop)" "0"
drop_from_to 100 100
assert_eq 'no change is not reported' \
  "$(sweep_count_kind "$SWEEP_FYI" space_drop)" "0"

echo "the first ever run has nothing to compare against"
: > "$SWEEP_FYI"
rm -f "$HOME/.local/state/sweep/state"
assert_true 'no previous run is not an error' sweep_fyi_space_drop $(( 10 * GB ))
assert_eq 'and reports nothing' "$(sweep_count_kind "$SWEEP_FYI" space_drop)" "0"

echo "a corrupt state file is survived rather than divided by"
for bad in "" "not-a-number" "12 34" "-"; do
  : > "$SWEEP_FYI"
  printf 'last_free_after_kb=%s\n' "$bad" > "$HOME/.local/state/sweep/state"
  assert_true "state of '$bad' does not crash the run" \
    sweep_fyi_space_drop $(( 10 * GB ))
  assert_eq "state of '$bad' reports nothing" \
    "$(sweep_count_kind "$SWEEP_FYI" space_drop)" "0"
done

echo "it reports and never acts"
# The whole feature is an FYI. Nothing in it may delete, and the two commands
# a reader might reach for are named as theirs to run, not sweep's.
assert_not_contains 'no deletion in the feature at all' \
  "$(sed -n '/^sweep_fyi_space_drop()/,/^}/p;/^sweep_pending_updates()/,/^}/p;/^sweep_local_snapshots()/,/^}/p' "$SWEEP_SRC/lib/clean.sh")" \
  "safe_rm"
assert_not_contains 'and no rm either' \
  "$(sed -n '/^sweep_fyi_space_drop()/,/^}/p;/^sweep_pending_updates()/,/^}/p;/^sweep_local_snapshots()/,/^}/p' "$SWEEP_SRC/lib/clean.sh")" \
  "rm -"
# Joined into one line, backslash line-continuations removed, so an assertion
# does not depend on where a long message happens to wrap.
feature_src=$(tr '\n' ' ' < "$SWEEP_SRC/lib/clean.sh" | tr -d '\\' | tr -s ' ')
assert_contains 'deletelocalsnapshots is named as Oscar'"'"'s to run' \
  "$feature_src" "deletelocalsnapshots\` is yours"
assert_contains 'and so is installing or declining an update' \
  "$feature_src" "yours; sweep never touches them"

echo "the slow probe is bounded"
# softwareupdate --list reaches Apple and can take minutes. Without a limit it
# would hold the whole run, which is on a launchd schedule.
assert_contains 'softwareupdate runs under sweep_timeout' \
  "$(sed -n '/^sweep_pending_updates()/,/^}/p' "$SWEEP_SRC/lib/clean.sh")" \
  "sweep_timeout 45 softwareupdate"
assert_true 'and the timeout helper really does return' \
  sweep_timeout 2 true
assert_false 'and really does kill what overruns' \
  sweep_timeout 1 sleep 5

echo "the report prints the group first, above the other FYI kinds"
assert_eq 'space_drop leads sweep_fyi_groups' \
  "$(sweep_fyi_groups | sed -n 1p | cut -f1)" "space_drop"
assert_contains 'with a label that says whose fault it is not' \
  "$(sweep_fyi_groups | sed -n 1p)" "went somewhere else"

echo "end to end: the drop reaches the report"
: > "$SWEEP_FYI"
sweep_state_set last_free_after_kb $(( 100 * GB ))
sweep_fyi_space_drop $(( 85 * GB ))
sweep_write_report $(( 85 * GB )) $(( 85 * GB ))
report=$(t_report)
assert_contains 'the FYI section carries it' "$report" "went somewhere else"
assert_contains 'with the figure'            "$report" "15.0 GB"

echo "the probes' parsers, on captured output"
# Real `softwareupdate --list` output, so the parser is tested against the
# format rather than against a convenient shape.
got=$(sweep_parse_updates <<'EOF'
Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: macOS Sequoia 26.4-26.4
	Title: macOS Sequoia, Version: 26.4, Size: 7812345KiB, Recommended: YES, Action: restart,
* Label: Safari26.4MojaveAuto-26.4
	Title: Safari, Version: 26.4, Size: 123456KiB, Recommended: YES,
EOF
)
# LC_ALL=C in the parser, so this order is the same here and on CI's Linux.
assert_eq 'two titles, not the labels or the preamble' \
  "$(printf '%s' "$got" | tr '\n' '|')" "Safari|macOS Sequoia"

assert_eq 'a block with no Title falls back to its Label, once' \
  "$(sweep_parse_updates <<'EOF'
* Label: XProtectPlistConfigData_10_15-2026
* Label: Safari26.4-26.4
	Title: Safari, Version: 26.4, Size: 123456KiB,
EOF
)" "$(printf 'Safari\nXProtectPlistConfigData_10_15-2026')"

assert_eq 'nothing available parses to nothing' \
  "$(sweep_parse_updates <<'EOF'
Software Update Tool

Finding available software
No new software available.
EOF
)" ""

got=$(sweep_parse_snapshots <<'EOF'
Snapshots for volume group containing disk /:
com.apple.TimeMachine.2026-11-25-041500.local
com.apple.TimeMachine.2026-11-24-174500.local
EOF
)
assert_eq 'both snapshot dates, header dropped' \
  "$(printf '%s' "$got" | tr '\n' '|')" \
  "2026-11-24-174500|2026-11-25-041500"

echo "a run with no previous state does not report a drop"
# Guards the ordering in bin/sweep: the check has to read the *previous* run's
# figure, so it must happen before this run overwrites it.
assert_contains 'bin/sweep checks before any tier runs' \
  "$(sed -n '/free_before=\$(sweep_free_kb)/,/sweep_tier light/p' "$SWEEP_SRC/bin/sweep")" \
  "sweep_fyi_space_drop"
assert_not_contains 'and not after the tiers have moved the number' \
  "$(sed -n '/^  free_after=/,$p' "$SWEEP_SRC/bin/sweep")" \
  "sweep_fyi_space_drop"


echo "the suite never shells out to softwareupdate or tmutil"
# Both probes are gated on SWEEP_TESTING as well as the caller, so a case that
# calls one directly cannot reach Apple from Oscar's machine.
assert_eq 'sweep_pending_updates is inert under test' "$(sweep_pending_updates)" ""
assert_eq 'sweep_local_snapshots is inert under test' "$(sweep_local_snapshots)" ""

echo "the threshold is a config key like every other"
assert_eq 'it defaults to 5' "$SPACE_DROP_GB" "5"
cat > "$HOME/.config/sweep/config" <<'EOF'
SPACE_DROP_GB=20
EOF
sweep_load_config
assert_eq 'the config file can raise it' "$SPACE_DROP_GB" "20"
: > "$SWEEP_FYI"
sweep_state_set last_free_after_kb $(( 100 * GB ))
sweep_fyi_space_drop $(( 85 * GB ))
assert_eq 'and a 15 GB drop is then below the bar' \
  "$(sweep_count_kind "$SWEEP_FYI" space_drop)" "0"
rm -f "$HOME/.config/sweep/config"
sweep_load_config

t_end
