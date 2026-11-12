#!/bin/zsh
# Builds the app and has it check itself.
#
#   scripts/test.sh                 the made-up statements in Tests/Fixtures, then (if this Mac has
#                                   one) a copy of your own library. The real one is never touched.
#   scripts/test.sh --fixtures      the made-up statements only
#   scripts/test.sh --library DIR   also a copy of the library in DIR (a Spendthrift data folder)
#
# Nothing is sent anywhere: the run is offline. Exits non-zero if any check fails.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
OWN="$HOME/Library/Application Support/Spendthrift"
LIBRARY=""; [[ -f "$OWN/library.json" ]] && LIBRARY=$OWN
while (( $# )); do
  case $1 in
    --fixtures) LIBRARY="" ;;
    --library) shift; LIBRARY=$1 ;;
  esac
  shift
done

scripts/build.sh > /dev/null 2>&1 || { echo "The build failed. Run scripts/build.sh to see why."; exit 2 }
APP="$ROOT/build/Spendthrift.app/Contents/MacOS/Spendthrift"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
bad=0

run() {   # name, data folder, files to import (colon-separated)
  local log="$WORK/$1.log"
  SPENDTHRIFT_HOME="$2" SPENDTHRIFT_SNAPSHOT="$WORK/$1-snaps" SPENDTHRIFT_NO_CLOUD=1 SPENDTHRIFT_NO_SHOW=1 \
    SPENDTHRIFT_SELFTEST=1 SPENDTHRIFT_IMPORT="$3" "$APP" > "$log" 2>&1
  local passed=$(grep -c "^SELFTEST PASS" "$log") failed=$(grep -c "^SELFTEST FAIL" "$log")
  grep "^SELFTEST \(FAIL\|SKIP\)" "$log"
  if (( failed > 0 )) || ! grep -q "^SELFTEST SUMMARY" "$log"; then
    bad=1
    grep -q "^SELFTEST SUMMARY" "$log" || { echo "$1: the run stopped before the end. Last lines:"; tail -3 "$log" }
  fi
  echo "$1: $passed passed, $failed failed"
}

fixtures=(Tests/Fixtures/*.(csv|CSV|qfx|pdf)(N))
run "fixtures" "$WORK/fixtures-home" "${(j/:/)fixtures:a}"

if [[ -n $LIBRARY ]]; then
  mkdir -p "$WORK/library-home"
  for f in library.json orders.json; do [[ -f "$LIBRARY/$f" ]] && cp "$LIBRARY/$f" "$WORK/library-home/"; done
  run "a copy of the library" "$WORK/library-home" ""
fi

# Models are named in one file, so the whole app can be moved to new ones at once.
strays=$(grep -rnE '"(anthropic|google|openai|typesafe|meta|mistralai|x-ai|deepseek)/[a-z0-9.:-]+"' Sources --include='*.swift' | grep -v "Cloud/ModelNames.swift" || true)
if [[ -n "$strays" ]]; then echo "a model is named outside Cloud/ModelNames.swift:"; echo "$strays"; bad=1; fi

# How long the app takes to open, for the record: the middle of five runs (single runs vary by a
# tenth of a second). "Drawn" is when the first page is really on screen, timed from inside the pass
# that draws it; "all in" is when the pictures and lower cards have followed and the app is free.
# Not a pass or fail on other machines, but on this one a first page slower than 700 ms is a regression.
home="$WORK/fixtures-home"; [[ -d "$WORK/library-home" ]] && home="$WORK/library-home"
drawn=(); allin=()
for i in 1 2 3 4 5 6; do
  SPENDTHRIFT_HOME="$home" SPENDTHRIFT_TIMING=1 SPENDTHRIFT_NO_CLOUD=1 "$APP" > "$WORK/timing.log" 2>&1
  (( i == 1 )) && continue          # the first run after a build pays one-off costs
  drawn+=($(grep "pages drawn" "$WORK/timing.log" | awk '{print $2}'))
  allin+=($(grep "held-back pieces in" "$WORK/timing.log" | awk '{print $2}'))
done
drawn=(${(on)drawn}); allin=(${(on)allin})
echo "opening: first page drawn at ${drawn[3]:-?} ms, all in at ${allin[3]:-?} ms (middle of five)"
if [[ -n ${drawn[3]:-} ]] && (( ${drawn[3]} > 700 )); then echo "opening: slower than 700 ms"; [[ -n ${SPENDTHRIFT_STRICT_TIMING:-} ]] && bad=1; fi
exit $bad
