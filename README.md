# The Tony Awards

A Mac app made for Tony, honoring excellence in spending. Tony drops in statements from any bank or
card and sees where his money goes. No terminal, no Finder, no cloud, no accounts to link: everything
runs on his Mac, including the AI. The only thing it ever asks the internet is whether a newer
version of the app exists.

The idea started from [davidfowl/tally](https://github.com/davidfowl/tally); the app is now written
entirely in Swift with Apple's own frameworks (SwiftUI, Swift Charts, PDFKit, Vision, Foundation Models,
Image Playground) and has no dependencies.

## How it works

- **PDF statements check themselves.** Each one is read two ways (as stored, and rebuilt from
  positions on the page) and the version that adds up to the totals printed on the statement wins.
  The import message says whether the totals matched to the cent.
- **Drop anything in.** CSV/TSV exports, Excel (.xlsx), PDF statements (including scans and
  password-protected ones), photos or screenshots of a statement, Quicken files (OFX, QFX, QBO), or a
  whole folder of them. Files that can't be read are listed once, each with what to do about it. The app
  works out the columns, the account and which way the amounts go, with no questions asked.
  Overlapping statements are de-duplicated. Every import has an **Undo**.
- **Everything is sorted automatically**, in this order of trust:
  1. places Tony has already decided,
  2. a built-in list of well-known businesses,
  3. the bank's own category, when the file has one (Chase, Capital One, Amex, Discover…),
  4. obvious words in the name ("cafe", "parking"),
  5. Apple Intelligence, on-device, for whatever is left. It learns from Tony's own choices.
- **Double-Check** is optional: a short list of the AI's guesses, biggest first. One click to agree.
- **Change anything by hand.** Click any category pill to change it for that place, every time.
  Right-click for "only this charge". The inspector in Transactions renames places and shows the
  history at each one.

## Screens

- **Overview**: Today's Nominee (caricature Tony holding something he recently bought; Image
  Playground draws only the prop and backdrop, never Tony), the month's total, where it went, the
  trend, top places, and **The Monthly Ceremony**: awards plus notes on new subscriptions, price
  increases, possible double charges and unusual purchases.
- **Cash Flow**: the whole picture in lanes. *Everyday* (salary in, spending out), *Income taxes* on
  their own line, and *Investments* (distributions, capital calls, the investment loan, brokerage
  moves) kept apart, with a month-by-month chart and a by-fund table. Transfers between own accounts
  are left out. A **Credit Cards** check compares what the bank paid each card with the statements
  added: a payment only counts as a transfer when that card's purchases are in the app; otherwise it
  counts as spending under "Cards Not Added Yet", so the total is complete either way.
- **Transactions**: searchable, filterable table with an inspector.
- **Year in Review**: month-by-month stacked spending, category trends, top places, biggest
  purchases, repeating charges and their yearly cost, money in. **Save as PDF** to share.
- **Ask the Academy**: plain-English questions. The model reads the intent; dates and totals are
  computed exactly in code.
- **Categories**: every category with its all-time total. **New Category** makes your own (name,
  icon, color); it also appears at the bottom of every category menu. Apple Intelligence is told
  about custom categories and sorts new places into them.
- **Accounts**: rename, remove, or fix an account whose amounts came in backwards.

## Build (on your Mac)

Requires Command Line Tools or Xcode for macOS 26, on an Apple Silicon Mac.

```sh
scripts/build.sh
```

Output: `build/The Tony Awards.app` and `build/TheTonyAwards.zip`. The build briefly opens a small
window to draw the icon (Tony in a gold medallion on stage).

## Sending it to Tony, and sending updates

**First time**

1. Run `scripts/build.sh` and AirDrop `build/TheTonyAwards.zip` to Tony (or share it by iCloud/Messages).
2. He double-clicks the zip, drags **The Tony Awards** into **Applications**, then onto the **Dock**.
3. The app isn't notarized, so the first launch is blocked: double-click it once, click **Done**, then
   **System Settings → Privacy & Security → Open Anyway**.
4. When asked, **Allow** access to the Downloads folder (so new statements are offered automatically).

Requirements: an Apple Silicon Mac on macOS 26 with Apple Intelligence turned on (**System
Settings → Apple Intelligence & Siri**). Without it everything still works, except that places the
built-in rules can't sort wait in Double-Check for Tony to pick, and Today's Nominee uses a simpler
picture.

**Updates (automatic)**

1. Put a higher number in `VERSION` (say `1.1`).
2. Run `scripts/release.sh "What's new, in a sentence. Tony sees this."`

That builds, signs and publishes the zip to the public repository
[pwolpe/tony-awards-releases](https://github.com/pwolpe/tony-awards-releases). Tony's app checks it
once a day (or from **The Tony Awards → Check for Updates…**), shows a "Version 1.1 is ready" button,
and on one click downloads it, checks the signature, replaces itself and reopens. The check sends
nothing about Tony; it only asks GitHub for the latest version number.

How it works without an Apple Developer account:

- Every build is signed with a self-made certificate, **Tony Awards Signing**, in this Mac's login
  keychain (created Nov 2026, valid ten years). Same certificate means same app identity, so macOS
  keeps Tony's Downloads permission across updates.
- Before installing, the app requires the download to be signed by that same certificate and to be a
  higher version. Anything else is refused and nothing changes.
- The app downloads the update itself, so Gatekeeper's "Open Anyway" step is only needed for the very
  first install.

**Back up the certificate.** If it is lost (a new Mac without migrating the keychain), Tony's app will
refuse every future update and he'll need one manual reinstall (his data is unaffected). To back it
up: Keychain Access → login → My Certificates → right-click **Tony Awards Signing** → Export, and keep
the .p12 somewhere safe. To build on another Mac, import that file there.

His data is not inside the app, so replacing the app never touches it. The data file is read
forgivingly (missing fields get defaults, unknown fields are ignored, a damaged record is skipped),
so any version can open any other version's data. A backup is kept per day for two weeks in
`Backups/`; if the main file is ever unreadable it is set aside, never overwritten, and the latest
backup is restored.

An Apple Developer ID ($99/year) would additionally remove the first-install "Open Anyway" step by
notarizing the app; `notarytool` and `stapler` are already in the Command Line Tools.

## Where the data lives

`~/Library/Application Support/Tony Awards/`

- `library.json`: accounts, every statement line, and what the app has learned about each place
- `Backups/`: one copy per day, two weeks' worth (**Help → Save a Backup to the Desktop** makes one on demand)
- `Daily Tony/`: the last two weeks of nominee pictures

To back up or move Tony to a new Mac, copy that folder.

## Code map

| File | What it does |
| --- | --- |
| `BudgetStore.swift` | The single source of truth: importing, sorting, editing, analytics |
| `Library.swift` | The saved file, and `MerchantResolver` (which place is this? instant category) |
| `Importing.swift`, `CSV.swift`, `PDFStatement.swift` | Reading CSV, OFX/QFX and PDF statements |
| `Suggestions.swift`, `AISchemas.swift` | Name cleanup, known businesses, bank categories, Apple Intelligence |
| `Insights.swift`, `Ask.swift`, `DailyTony.swift`, `Compositor.swift` | Awards and notes, questions, the daily picture |
| `Views/` | The screens |

## Testing (for Paul)

A self-driving test mode, enabled only through environment variables:

```sh
open -W -n "build/The Tony Awards.app" --stdout run.log \
  --env TONY_AWARDS_HOME=/tmp/tony-test \
  --env TONY_AWARDS_SNAPSHOT=/tmp/tony-test/snaps \
  --env "TONY_AWARDS_IMPORT=a.csv:b.pdf:c.qfx"
```

It imports the files, logs how every place was sorted, the awards, notes and sample Ask answers,
and saves pictures of the main screens. Add `--env TONY_AWARDS_SELFTEST=1` to exercise category
changes, re-import, undo-style removal and saving (prints PASS/FAIL lines). `TONY_AWARDS_HOME`
alone runs the app against a scratch folder. To preview how a statement will be read:
`"build/The Tony Awards.app/Contents/MacOS/TonyAwards" --inspect file.pdf`
