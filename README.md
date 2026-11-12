# Spendthrift

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

**Spendthrift → Settings…** takes an OpenRouter key (stored in a private file only his account can read, never in the
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
- **Questions and writing**: Ask, the monthly note, the line under the daily picture. Totals
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
- **One way back**: every link inside a page (a category, a month, a trip, a payee, an order, a
  statement) goes through one navigation history, so **Back** (or ⌘[) always returns to where it was
  followed from, however many steps deep. Choosing a section in the sidebar is a fresh start.
- **Overview**: one page that answers one question first. A banner with the day's picture (a real
  purchase on this day in an earlier year), then a **Month / Year** switch and **the verdict**: what
  came in, and how much of it went on living, taxes and interest. What is left is gold: kept or
  invested, it is still yours. Below it, three cards to step into:
  - **Spending**: where it went, the run of months, top payees, an estimate for next month, and the
    month's note. In Year view, the year in review, with **Save as PDF**.
  - **Income**: who paid, and how much.
  - **Investing**: where the money came from and what it did, and the investment side line by line.
  - The verdict itself opens **Money In and Out**: the full statement, with transfers between your
    own accounts left out and card payments counted once.
- **Transactions**: searchable, filterable table with an inspector.
- **Trips & Events**: runs of charges the model recognizes as a trip or an occasion, with totals
  added up in code. A charge in the wrong trip can be moved: right-click it in Transactions and
  choose **Trip or Event**, or use the same menu in the inspector. The move is remembered even
  when the model looks again and words the trip's name differently.
- **Ask**: plain-English questions. The model reads the intent; dates and totals are
  computed exactly in code.
- **Categories**: every category with its all-time total. **New Category** makes your own (name,
  icon, color); it also appears at the bottom of every category menu. Apple Intelligence is told
  about custom categories and sorts new places into them.
- **Accounts**: rename, remove, or fix an account whose amounts came in backwards.

### Statements, and "Show in Statement"

Every statement added is kept as it came. **Statements** in the sidebar lists them by account, and
opens any of them: PDFs as they are, CSV and Excel files as a table, Quicken files as their list of
transactions. From any charge (right-click → **Show in Statement**, the button in the details pane,
the small magnifier at the end of a row, or the Space bar in Transactions) the original opens at the
line the charge was read from, with the line washed yellow and the amount marked. Nothing about
position is stored at import: `SourceLocator` finds the amount afresh and checks the date and
merchant beside it, so it works for statements read by pattern and by the model alike.

A library from before originals were kept: drop the statements in again. They are re-read without
the model, nothing is added twice, and each charge is pointed at its file.

### The banner picture

A cartoon of Tony, Paul or both (a third of the time each) in a daydream about a real recent
purchase, one of them holding the receipt: the place, what it sells and the real total. Each drawing
is checked by a second model that reads the receipt back; a picture whose receipt is wrong or hard
to read is redrawn (up to three tries). Pictures are drawn and kept on that person's Mac only. The
starter pictures that ship with the app have no receipts.

## Words

The app calls anyone or anything money went to a **payee** (a shop, a subscription, a landlord, a person paid by Zelle). The code and this file still say "place" and "merchant" in places; they mean the same thing.

## The look

Paper and ink, and one emblem: the till receipt. `ReceiptPaper`, `ReceiptRule`, `ReceiptLine` and
`ReceiptMark` (in `Components.swift`) are used for the sidebar masthead, a charge's details, the
month's summary and every chat answer. One accent, receipt-ink blue (`Theme.accent`); brass is kept
for one meaning only, money invested. The voice is a dry, fond bookkeeper: never awards-show, never scolding.


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
- `SPENDTHRIFT_FAIL_CLOUD=credit|key|offline` simulates that; `SPENDTHRIFT_WIDTH` and `SPENDTHRIFT_DARK`
  render the test pictures at a given width and in Dark Mode.

## Build (on your Mac)

Requires Command Line Tools or Xcode for macOS 26, on an Apple Silicon Mac.

```sh
scripts/build.sh
```

Output: `build/Spendthrift.app` and `build/Spendthrift.zip`. The build briefly opens a small
window to draw the icon (a fallback; the finished icon in Resources is used when present).

## Sending it to Tony, and sending updates

**First time**

1. Run `scripts/build.sh` and AirDrop `build/Spendthrift.zip` to Tony (or share it by iCloud/Messages).
2. He double-clicks the zip, drags **Spendthrift** into **Applications**, then onto the **Dock**.
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
[pwolpe/spendthrift-releases](https://github.com/pwolpe/spendthrift-releases). Tony's app checks it
once a day (or from **Spendthrift → Check for Updates…**), shows a "Version 1.1 is ready" button,
and on one click downloads it, checks the signature, replaces itself and reopens. The check sends
nothing about Tony; it only asks GitHub for the latest version number.

How it works without an Apple Developer account:

- Every build is signed with a self-made certificate, **Spendthrift Signing**, in this Mac's login
  keychain (created Nov 2026, valid ten years). Same certificate means same app identity, so macOS
  keeps Tony's Downloads permission across updates.
- Before installing, the app requires the download to be signed by that same certificate and to be a
  higher version. Anything else is refused and nothing changes.
- The app downloads the update itself, so Gatekeeper's "Open Anyway" step is only needed for the very
  first install.

**Back up the certificate.** If it is lost (a new Mac without migrating the keychain), Tony's app will
refuse every future update and he'll need one manual reinstall (his data is unaffected). To back it
up: Keychain Access → login → My Certificates → right-click **Spendthrift Signing** → Export, and keep
the .p12 somewhere safe. To build on another Mac, import that file there.

His data is not inside the app, so replacing the app never touches it. The data file is read
forgivingly (missing fields get defaults, unknown fields are ignored, a damaged record is skipped),
so any version can open any other version's data. A backup is kept per day for two weeks in
`Backups/`; if the main file is ever unreadable it is set aside, never overwritten, and the latest
backup is restored.

An Apple Developer ID ($99/year) would additionally remove the first-install "Open Anyway" step by
notarizing the app; `notarytool` and `stapler` are already in the Command Line Tools.

## Where the data lives

`~/Library/Application Support/Spendthrift/`

- `library.json`: accounts, every statement line, and what the app has learned about each place
- `Backups/`: one copy per day, two weeks' worth (**Help → Save a Backup to the Desktop** makes one on demand)
- `Pictures/`: the last thirty banner pictures and `gallery.json`, which says what each is about
- `Statements/`: every statement exactly as it was added, so any charge can be shown in its original

Data kept under the app's earlier name (`Appauled`) is moved here the first time Spendthrift opens.

To back up or move Tony to a new Mac, copy that folder.

## Code map

| Where | What it does |
| --- | --- |
| `BudgetStore.swift` | The single source of truth: the saved library, what the screens derive from it, and all stored state |
| `Store/` | The store's work, one file per concern: `+Navigation` (where you are and the way back), `+Importing`, `+Sorting`, `+Editing`, `+Orders`, `+Stories`, `+Noticed`, `+Accounts`, `+Insights` |
| `Cloud/` | Everything sent to a model, one file per job: the client and its cost ledger, blanking personal details, sorting payees, reading statements and checks, pictures, lookups, trips, findings, short writing |
| `Library.swift` | The saved file, and `MerchantResolver` (which payee is this? instant category) |
| `Importing.swift`, `CSV.swift`, `PDFStatement.swift`, `Scans.swift` | Reading CSV, OFX/QFX and PDF statements |
| `Orders.swift` | An order history: reading the export, matching orders to card charges |
| `Suggestions.swift`, `AISchemas.swift` | Name cleanup, known businesses, bank categories, Apple Intelligence |
| `Insights.swift`, `Ask.swift`, `AskChat.swift` | The month's notes and awards; questions, answered from figures the app computes |
| `Views/` | The screens. `Components.swift` holds the pieces they share (cards, receipts, steppers, payee rows) |

Two rules the code keeps: every number shown is computed in code (a model only reads intent or
writes prose around figures it is given), and every link goes through `BudgetStore.navigate`.

## Testing (for Paul)

A self-driving test mode, enabled only through environment variables:

```sh
open -W -n "build/Spendthrift.app" --stdout run.log \
  --env SPENDTHRIFT_HOME=/tmp/tony-test \
  --env SPENDTHRIFT_SNAPSHOT=/tmp/tony-test/snaps \
  --env "SPENDTHRIFT_IMPORT=a.csv:b.pdf:c.qfx"
```

It imports the files, logs how every place was sorted, the month's superlatives, notes and sample Ask answers,
and saves pictures of the main screens. Add `--env SPENDTHRIFT_SELFTEST=1` to exercise category
changes, re-import, undo-style removal and saving (prints PASS/FAIL lines). `SPENDTHRIFT_HOME`
alone runs the app against a scratch folder. To preview how a statement will be read:
`"build/Spendthrift.app/Contents/MacOS/Spendthrift" --inspect file.pdf`
