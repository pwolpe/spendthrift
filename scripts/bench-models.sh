#!/bin/zsh
# Which models should the app use? One run answers it.
#
#   scripts/bench-models.sh                       the models in Cloud/ModelNames.swift against the newest
#                                                 from each maker that could replace them
#   scripts/bench-models.sh maker/model …         also try these, whatever their price or maker
#   scripts/bench-models.sh --makers a,b,c        whose models to try (default: anthropic,google,meta,openai)
#   scripts/bench-models.sh --only trips,payees   some jobs only: payees, statements, trips, questions,
#                                                 first-pass, grouping, needs
#   scripts/bench-models.sh --budget 5            stop starting jobs once this many dollars are spent (default 10)
#   scripts/bench-models.sh --library DIR         a Spendthrift data folder other than your own
#
# It works on a copy of your library (the real one is never touched) and on the made-up households in
# Tests/Bench, sends what the app would send for the same jobs, to every model tried, and pays for it
# with your OpenRouter key. A full run takes about ten minutes. The report is printed and kept in
# ~/Library/Application Support/Spendthrift/Benchmarks. How it decides: Sources/Spendthrift/ModelBench.swift.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
OWN="$HOME/Library/Application Support/Spendthrift"
LIBRARY=$OWN; MAKERS=""; ONLY=""; BUDGET=""; MODELS=()
while (( $# )); do
  case $1 in
    --makers) shift; MAKERS=$1 ;;
    --only) shift; ONLY=$1 ;;
    --budget) shift; BUDGET=$1 ;;
    --library) shift; LIBRARY=$1 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) MODELS+=($1) ;;
  esac
  shift
done

scripts/build.sh > /dev/null 2>&1 || { echo "The build failed. Run scripts/build.sh to see why."; exit 2 }
APP="$ROOT/build/Spendthrift.app/Contents/MacOS/Spendthrift"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
for f in library.json orders.json; do [[ -f "$LIBRARY/$f" ]] && cp "$LIBRARY/$f" "$WORK/home/"; done

SPENDTHRIFT_HOME="$WORK/home" SPENDTHRIFT_SNAPSHOT="$WORK/snaps" SPENDTHRIFT_NO_SHOW=1 \
  SPENDTHRIFT_MODEL_BENCH="$WORK/out" SPENDTHRIFT_BENCH_MODELS="${(j:,:)MODELS}" SPENDTHRIFT_BENCH_MAKERS="$MAKERS" \
  SPENDTHRIFT_BENCH_ONLY="$ONLY" SPENDTHRIFT_BENCH_BUDGET="$BUDGET" SPENDTHRIFT_BENCH_STATEMENTS="$LIBRARY/Statements" \
  SPENDTHRIFT_BENCH_FIXTURES="$ROOT/Tests/Bench" SPENDTHRIFT_BENCH_LEDGER="$LIBRARY/spend.json" \
  "$APP" 2> "$WORK/errors.log" | tee "$WORK/run.log" | grep --line-buffered "^BENCH " | sed -l 's/^BENCH //'

if [[ ! -f "$WORK/out/report.txt" ]]; then
  echo "The benchmark stopped before it finished. Last lines:"; tail -5 "$WORK/run.log" "$WORK/errors.log"; exit 1
fi
echo
cat "$WORK/out/report.txt"
KEEP="$OWN/Benchmarks"
mkdir -p "$KEEP"
stamp=$(date +%Y-%m-%d-%H%M)
cp "$WORK/out/report.txt" "$KEEP/$stamp.txt"; cp "$WORK/out/results.json" "$KEEP/$stamp.json"
echo
echo "Kept in $KEEP/$stamp.txt"
