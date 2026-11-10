# Appauled

A Mac app made for Tony, honoring excellence in spending. Tony drops in statements from any bank or
card and sees where his money goes. No terminal, no Finder, no accounts to link.

Out of the box everything runs on his Mac, including the AI (Apple Intelligence), and the only thing
it asks the internet is whether a newer version exists. With an OpenRouter key entered in
**Settings** it also uses a powerful cloud model, which is what makes it feel like it just knows
(see *Smarter AI* below).

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

## Smarter AI (optional, recommended)

**Appauled → Settings…** takes an OpenRouter key (stored in a private file only his account can read, never in the
app, its data, or this repository). Make Tony his own key at openrouter.ai with a spending limit.
With a key:

- **Sorting**: the cloud model decides every place that isn't Tony's own choice or a business the
  app knows for certain, names it properly ("Dickson's Farmstand Meats"), and says whether it is sure.
  Sure ones are filed silently; only real guesses (a Zelle to a person, a bare "Withdrawal") go to
  Double-Check. When Tony corrects something, the remaining guesses are re-evaluated with his choice
  as an example.
- **Statements**: any PDF or scan that doesn't add up to its own printed totals is also read by the
  model, after name, address, email and account numbers are blanked. Its reading is accepted when it
  matches the statement's printed summary or agrees with the app's own reading.
- **Odd spreadsheets**: it works out the columns before Tony is ever asked.
- **Questions and writing**: Ask the Academy, the monthly recap, the daily nomination line. Totals
  are always computed in code.

Measured in Nov 2026 on a year of real statements (48 files, 2,213 transactions, 645 places): read
and sorted in under two minutes; 45 of 47 PDFs verified against their printed totals; 94% of
cloud-sorted places filed with no review. The default model is Claude Sonnet 5.5. Haiku 5.5 was the
same speed, 20× cheaper, and agreed with it on 88% of places; Cloudflare's Clef decision model was
twice as fast but agreed on only 64%, so it isn't offered. If the key is missing, wrong or out of
credit, or there's no internet, everything falls back to the on-device paths.

`statements/` (git-ignored) holds Paul's own statements, used for testing.

## Screens

- **The first minute**: the welcome screen asks for the OpenRouter key and tests it. Dropping in a pile
  of statements plays as a show (statements counted off, accounts, regulars and trips called out as they
  are found) and ends in a seven-card premiere: the count, where it went, the charge that stands out,
  what repeats, trips, the verdict, and a picture.
- **Say what it was**: in Double-Check, on a place's page, or as a note on a charge, type what something
  was in your own words ("my accountant, for tax prep"). The model names it, files it (making a category
  if none fits) and keeps the note. Notes also feed trip-finding, answers and the estimate below.
- **Looking ahead**: an estimate of next month's everyday spending from the history, what repeats and
  your notes. Always labelled an estimate.
- **Drill-downs**: any click on a category, month, trip or account opens one plain page of charges
  (`ChargesView`); a place opens its own page (`PlaceView`). Only one pane is ever open on the right.
- **Overview**: a wide banner across the top with a cartoon of Tony living out a daydream about a
  real recent purchase. It never waits: on opening it shows the picture prepared during the last
  visit (or one of twelve starters in `Resources/Starters`), then quietly asks OpenRouter which image
  model is best today and draws the next one from his photo for next time. **Another One** shows a
  different picture at once. Below it, a **Month / Year** switch. *Month*: the total, where it went,
  the trend, top places, what's coming up, and **The Monthly Ceremony** (awards plus notes on new
  subscriptions, price increases, possible double charges and unusual purchases). *Year*:
  month-by-month stacked spending, category trends, top places, biggest purchases, repeating
  charges and their yearly cost, money in, tax-time totals. **Save as PDF** to share.
- **Cash Flow**: the whole picture in lanes. *Everyday* (salary in, spending out), *Income taxes* on
  their own line, and *Investments* (distributions, capital calls, the investment loan, brokerage
  moves) kept apart, with a month-by-month chart and a by-fund table. Transfers between own accounts
  are left out. A **Credit Cards** check compares what the bank paid each card with the statements
  added: a payment only counts as a transfer when that card's purchases are in the app; otherwise it
  counts as spending under "Cards Not Added Yet", so the total is complete either way.
- **Transactions**: searchable, filterable table with an inspector.
- **Trips & Events**: runs of charges the model recognizes as a trip or an occasion, with totals
  added up in code. A charge in the wrong trip can be moved: right-click it in Transactions and
  choose **Trip or Event**, or use the same menu in the inspector. The move is remembered even
  when the model looks again and words the trip's name differently.
- **Ask the Academy**: plain-English questions. The model reads the intent; dates and totals are
  computed exactly in code.
- **Categories**: every category with its all-time total. **New Category** makes your own (name,
  icon, color); it also appears at the bottom of every category menu. Apple Intelligence is told
  about custom categories and sorts new places into them.
- **Accounts**: rename, remove, or fix an account whose amounts came in backwards.

## The look

Japanese in sensibility: paper and ink (an unbleached-paper background by day, sumi by night), cards
as sheets with a hairline edge, one warm accent, category colors taken from traditional dyes, and
space left empty on purpose. It is all in `Theme` (Components.swift) and the category table
(Models.swift). The banner picture hangs clean with its caption beneath it, like a gallery label.

## When things go wrong

- A zip (a year of statements from the bank) is opened and read like a folder, at any depth.
- Files that aren't statements are listed with a plain reason; inside a dropped folder they are skipped.
- European exports (semicolons, 31.12.2026, 1.234,56) are understood.
- If the model can't be used (bad key, no credit, no connection), the import still finishes with
  what the app can do by itself, and a banner says what happened and that nothing was lost.
- `APPAULED_FAIL_CLOUD=credit|key|offline` simulates that; `APPAULED_WIDTH` and `APPAULED_DARK`
  render the test pictures at a given width and in Dark Mode.

## Build (on your Mac)

Requires Command Line Tools or Xcode for macOS 26, on an Apple Silicon Mac.

```sh
scripts/build.sh
```

Output: `build/Appauled.app` and `build/Appauled.zip`. The build briefly opens a small
window to draw the icon (Tony in a gold medallion on stage).

## Sending it to Tony, and sending updates

**First time**

1. Run `scripts/build.sh` and AirDrop `build/Appauled.zip` to Tony (or share it by iCloud/Messages).
2. He double-clicks the zip, drags **Appauled** into **Applications**, then onto the **Dock**.
3. The app isn't notarized, so the first launch is blocked: double-click it once, click **Done**, then
   **System Settings → Privacy & Security → Open Anyway**.
4. When asked, **Allow** access to the Downloads folder (so new statements are offered automatically).

5. On the welcome screen, paste an OpenRouter key (his own, or one made for him with a spending
   limit) and click **Turn On**. Then drop in a folder of statements: the import plays as a show and
   ends in a premiere of what it found.

Requirements: an Apple Silicon Mac on macOS 26. The key is what makes it magic (reading any
statement, naming every place, trips, pictures, questions, the estimate); without one the app still
reads and sorts what its built-in rules know and leaves the rest in Double-Check. A full first
import of about 130 statements costs roughly $3 on the key.

**Updates (automatic)**

1. Put a higher number in `VERSION` (say `1.1`).
2. Run `scripts/release.sh "What's new, in a sentence. Tony sees this."`

That builds, signs and publishes the zip to the public repository
[pwolpe/appauled-releases](https://github.com/pwolpe/appauled-releases). Tony's app checks it
once a day (or from **Appauled → Check for Updates…**), shows a "Version 1.1 is ready" button,
and on one click downloads it, checks the signature, replaces itself and reopens. The check sends
nothing about Tony; it only asks GitHub for the latest version number.

How it works without an Apple Developer account:

- Every build is signed with a self-made certificate, **Appauled Signing**, in this Mac's login
  keychain (created Nov 2026, valid ten years). Same certificate means same app identity, so macOS
  keeps Tony's Downloads permission across updates.
- Before installing, the app requires the download to be signed by that same certificate and to be a
  higher version. Anything else is refused and nothing changes.
- The app downloads the update itself, so Gatekeeper's "Open Anyway" step is only needed for the very
  first install.

**Back up the certificate.** If it is lost (a new Mac without migrating the keychain), Tony's app will
refuse every future update and he'll need one manual reinstall (his data is unaffected). To back it
up: Keychain Access → login → My Certificates → right-click **Appauled Signing** → Export, and keep
the .p12 somewhere safe. To build on another Mac, import that file there.

His data is not inside the app, so replacing the app never touches it. The data file is read
forgivingly (missing fields get defaults, unknown fields are ignored, a damaged record is skipped),
so any version can open any other version's data. A backup is kept per day for two weeks in
`Backups/`; if the main file is ever unreadable it is set aside, never overwritten, and the latest
backup is restored.

An Apple Developer ID ($99/year) would additionally remove the first-install "Open Anyway" step by
notarizing the app; `notarytool` and `stapler` are already in the Command Line Tools.

## Where the data lives

`~/Library/Application Support/Appauled/`

- `library.json`: accounts, every statement line, and what the app has learned about each place
- `Backups/`: one copy per day, two weeks' worth (**Help → Save a Backup to the Desktop** makes one on demand)
- `Pictures/`: the last thirty banner pictures and `gallery.json`, which says what each is about

To back up or move Tony to a new Mac, copy that folder.

## Code map

| File | What it does |
| --- | --- |
| `BudgetStore.swift` | The single source of truth: importing, sorting, editing, analytics |
| `Library.swift` | The saved file, and `MerchantResolver` (which place is this? instant category) |
| `Importing.swift`, `CSV.swift`, `PDFStatement.swift` | Reading CSV, OFX/QFX and PDF statements |
| `Suggestions.swift`, `AISchemas.swift` | Name cleanup, known businesses, bank categories, Apple Intelligence |
| `Insights.swift`, `Ask.swift`, `DailyPicture.swift`, `Compositor.swift` | Awards and notes, questions, the daily picture |
| `Views/` | The screens |

## Testing (for Paul)

A self-driving test mode, enabled only through environment variables:

```sh
open -W -n "build/Appauled.app" --stdout run.log \
  --env APPAULED_HOME=/tmp/tony-test \
  --env APPAULED_SNAPSHOT=/tmp/tony-test/snaps \
  --env "APPAULED_IMPORT=a.csv:b.pdf:c.qfx"
```

It imports the files, logs how every place was sorted, the awards, notes and sample Ask answers,
and saves pictures of the main screens. Add `--env APPAULED_SELFTEST=1` to exercise category
changes, re-import, undo-style removal and saving (prints PASS/FAIL lines). `APPAULED_HOME`
alone runs the app against a scratch folder. To preview how a statement will be read:
`"build/Appauled.app/Contents/MacOS/Appauled" --inspect file.pdf`
