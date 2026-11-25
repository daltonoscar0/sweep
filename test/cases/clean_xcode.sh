#!/bin/bash
# Tier 4: Xcode DerivedData. Tier 6: iOS DeviceSupport.
. "$(dirname "$0")/../helpers.sh"

t_home
export DERIVED_DATA_MAX_AGE_DAYS=7
export DEVICE_SUPPORT_KEEP=2
t_load

X="$HOME/Library/Developer/Xcode"
mkdir -p "$X/DerivedData/Old-abc/Build/Products" \
         "$X/DerivedData/Fresh-def/Build/Products" \
         "$X/Archives/2026-01-01"
printf 'x\n' > "$X/DerivedData/Old-abc/Build/Products/app"
printf 'x\n' > "$X/DerivedData/Fresh-def/Build/Products/app"
printf 'x\n' > "$X/Archives/2026-01-01/app.xcarchive"

t_age_tree "$X/DerivedData/Old-abc" 30
t_age "$X/Archives/2026-01-01/app.xcarchive" 400
t_age "$X/Archives/2026-01-01" 400
t_age "$X/Archives" 400

sweep_clean_derived_data

assert_missing 'a DerivedData folder untouched for 30 days goes' "$X/DerivedData/Old-abc"
assert_exists  'a recently built one stays'                      "$X/DerivedData/Fresh-def/Build/Products/app"
assert_exists  'DerivedData itself stays'                        "$X/DerivedData"
assert_exists  'Archives is never touched, however old'          "$X/Archives/2026-01-01/app.xcarchive"

echo "Archives cannot be removed even if asked directly"
assert_false 'safe_rm refuses an Archives path' sweep_safe_rm "$X/Archives/2026-01-01" test
assert_exists 'so it is still there'            "$X/Archives/2026-01-01/app.xcarchive"

echo "iOS DeviceSupport keeps the newest two"
D="$X/iOS DeviceSupport"
mkdir -p "$D/17.0 (21A123)" "$D/18.0 (22A456)" "$D/26.0 (23A789)" "$D/16.0 (20A000)"
for v in "17.0 (21A123)" "18.0 (22A456)" "26.0 (23A789)" "16.0 (20A000)"; do
  printf 'symbols\n' > "$D/$v/Symbols"
done
t_age "$D/16.0 (20A000)" 900
t_age "$D/17.0 (21A123)" 600
t_age "$D/18.0 (22A456)" 300
t_age "$D/26.0 (23A789)" 2

sweep_clean_device_support

assert_exists  'the newest DeviceSupport stays'   "$D/26.0 (23A789)/Symbols"
assert_exists  'the second newest stays'          "$D/18.0 (22A456)/Symbols"
assert_missing 'the third goes'                   "$D/17.0 (21A123)"
assert_missing 'and the fourth goes'              "$D/16.0 (20A000)"

t_end
