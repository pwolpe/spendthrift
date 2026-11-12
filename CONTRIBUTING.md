# Working on Spendthrift

Read the README's "For developers" section first. This page is the short list of rules the code
keeps, and how to check your work.

## Rules

1. **Every number is computed in code.** A model may read what someone meant, or write a sentence
   around figures it is handed. It never adds, rounds or estimates. Text from a model that contains
   a dollar amount the app did not supply is thrown away (`ChatAnalyst.dollarAmounts`).
2. **Works without a key.** Anything a model writes has a plain fallback built from the same figures,
   so the page is complete offline.
3. **One way back.** A link inside a page goes through `store.navigate`, `store.go(to:)`,
   `store.stepInto`, `store.showPlace` or `store.showCharges` (Store/BudgetStore+Navigation.swift).
   Only the sidebar and the menus set `store.selection` directly.
4. **If it is shown, it leads somewhere.** A payee, a category, a month, a trip, an amount made of
   charges: each opens the thing it names.
5. **Nothing slow in a view's body.** Work that reads every transaction is done once and kept in the
   store until the library changes (see `insightCache`, `reportCache` in BudgetStore.swift, cleared in
   `rebuild`). State that should survive leaving a page and coming back lives in the store.
6. **Rules are general.** No payee, employer, bank or person is special-cased for one household.
   What one person teaches the app is saved in their library (`Library`), never in the source.
7. **Engines are pure.** Logic that turns transactions into findings is an `enum` with static
   functions over `[Transaction]` (like `InsightEngine`), so it can be checked without a window.
8. **Shared pieces are shared.** Cards, rows, steppers, search fields and chart behaviour live in
   Views/Components.swift. If you need a second copy of something, make the first one reusable.
9. **A new saved field is optional and decoded.** `Library` has a hand-written `init(from:)`: add the
   field there, or it will vanish at the next launch. The self-test checks this.
10. **A decision model's answer is acted on automatically only above a measured confidence, is
    always recorded, and can always be undone.** Below that it is offered or ignored. Models in
    `Cloud/Decisions.swift` only judge; the threshold is chosen by measurement, not by feel.
11. **Models are named in one file.** `Cloud/ModelNames.swift` holds every model name; change it there
    and the whole app follows. The test script fails if a model is spelled out anywhere else.
12. **Plain words.** "Payee", "charge", "trip or event". Speak to the reader as "you". No jargon,
    no exclamation marks.

## Checking your work

```sh
scripts/test.sh            # builds, runs every check offline, reports how long the app takes to open
scripts/test.sh --fixtures # the made-up statements only
```

Add a check to `Sources/Spendthrift/SelfTest.swift` with every change: a pure rule in `logic`, a sum
that must agree in `books`, or an action a person would take.

To look at a page without opening a window, render it from the made-up statements:

```sh
scripts/build.sh
HOME_DIR=$(mktemp -d)
SPENDTHRIFT_HOME=$HOME_DIR SPENDTHRIFT_SNAPSHOT=$HOME_DIR/snaps SPENDTHRIFT_NO_CLOUD=1 SPENDTHRIFT_NO_SHOW=1 \
  SPENDTHRIFT_IMPORT="$(ls -d $PWD/Tests/Fixtures/*.{csv,CSV,qfx} | tr '\n' ':')" \
  build/Spendthrift.app/Contents/MacOS/Spendthrift
open $HOME_DIR/snaps
```

Pickers and text fields cannot be drawn this way and appear as yellow placeholders.

The app should stay fast: the test script prints when the first page is really drawn (the middle of
five runs; under 700 ms on a 19,000-charge library). If your change moves it, find out why before
going further (`SPENDTHRIFT_TIMING=1` prints each step; `SPENDTHRIFT_BENCH=1` times what pages do
repeatedly, then quits). Three things keep it there: the window goes up while the saved file is read
(`Boot` in Launch.swift), pictures are decoded off the main thread (`Decoding`), and anything not in
the first screenful waits for the first draw (`AfterFirstFrame`).
