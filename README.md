# Spendthrift

A Mac app that reads your bank and card statements on your own computer and shows where your money
goes. It can use AI to sort payees, find trips and answer questions, and it works without any account
linking.

Requires an Apple Silicon Mac on macOS 26. It is written in Swift with Apple's frameworks (SwiftUI,
Swift Charts, PDFKit, Vision, Foundation Models, Image Playground) and has no dependencies. The idea
started from [davidfowl/tally](https://github.com/davidfowl/tally).

## What it does

- Reads CSV/TSV, Excel (.xlsx), PDF statements (including scans and password-protected ones), photos
  of statements, Quicken files (OFX, QFX, QBO), zips and whole folders. It works out the columns, the
  account and which way the amounts go. Overlapping statements are de-duplicated, and every import has
  an **Undo**.
- Checks each PDF against the totals printed on it: the statement is read two ways and the reading that
  adds up wins. The import message says whether the totals matched to the cent.
- Sorts every payee automatically, in this order of trust: your own decisions, a built-in list of
  well-known businesses, the bank's own category, obvious words in the name, then AI for what is left.
- Lets you change anything: click a category to change it for that payee, right-click for "only this
  charge", or type what a charge was in your own words and let the model name and file it.
- Finds trips and events, estimates next month's everyday spending, and answers questions in plain
  English. Every figure is computed in code.
- Matches an Amazon order history to your card charges so "Amazon" becomes what was bought
  (see `docs/amazon-refresh.md`).
- Keeps every statement as it came, and opens it at the line a charge was read from.

## Getting started

1. Build the app with `scripts/build.sh` (see *For developers*), or download a build from this
   repository's Releases page. Builds are not notarized, so the first launch is blocked: open it once,
   click **Done**, then **System Settings → Privacy & Security → Open Anyway**.
2. Allow access to the Downloads folder if you want new statements offered automatically.
3. On the welcome screen, optionally paste an OpenRouter key (see below) and click **Turn On**.
4. Drop in your statements, or a folder of them. The import plays as a short show and ends in a
   premiere of what it found.

## Privacy and AI

Statements are read and stored on your Mac. Out of the box the AI is Apple Intelligence, running
on-device, and the only thing the app asks the internet is whether a newer version exists (it sends
nothing about you).

With an OpenRouter key entered in **Spendthrift → Settings…** the app also uses a cloud model. Make your
own key at openrouter.ai and give it a spending limit. The key is kept in a private file only your
account can read, never in the app, its data or this repository. With a key:

- **Sorting**: the model decides every payee that is not your own choice or a business the app knows for
  certain, names it, and says whether it is sure. Sure ones are filed silently; real guesses go to
  **Double-Check**, a short list, biggest first, where one click agrees.
- **Statements**: a PDF or scan that does not add up to its own printed totals is also read by the model,
  after name, address, email and account numbers are blanked. Its reading is accepted only when it
  matches the printed summary or the app's own reading.
- **Odd spreadsheets**: the model works out the columns before you are asked.
- **Questions and writing**: Ask, the monthly note, the daily picture and its caption, trips, and the
  next-month estimate. Totals are always computed in code.

Without a key the app still reads and sorts what its built-in rules and Apple Intelligence know, and
leaves the rest in Double-Check. If the key is missing, wrong or out of credit, or there is no internet,
an import still finishes on the on-device paths and a banner says what happened.

## The pages

- **Overview**: the first page. A banner with the day's picture, a **Month / Year** switch, and the
  verdict: what came in, and how much of it went on living, taxes and interest; what is left is yours.
  Three cards open further pages: **Spending** (where it went, the run of months, top payees, a note
  for the month, and in Year view a year in review you can save as PDF), **Income** (who paid) and
  **Investing** (where the money came from and what it did). The verdict itself opens **Money In and
  Out**, the full statement, with transfers between your own accounts left out and card payments
  counted once. A **Bills & Subscriptions** card shows what repeats and what it costs a year, with the
  next four due; it opens a page listing every bill by how often it comes, what crept up in price, what
  may have been forgotten, and what has stopped.
- **Back**: every link inside a page (a category, a month, a trip, a payee, an order, a statement) goes
  through one history, so **Back** (or ⌘[) returns to where you came from. Choosing a section in the
  sidebar starts fresh.
- **Transactions**: a searchable, filterable table with an inspector. Rename payees, see their history,
  move a charge to another trip, and use **Show in Statement** (right-click, the magnifier, or Space).
- **Payees**: everyone and everything money went to, with totals. A way a payee is written on
  statements can be made a payee of its own.
- **Trips & Events**: runs of charges the model recognizes as a trip or occasion, with totals added up in
  code. A move you make is remembered when the model looks again.
- **Ask**: plain-English questions; the model reads the intent and the figures come from code.
- **Categories**: every category with its all-time total. **New Category** makes your own.
- **Amazon**: an order history matched to card charges, with a card showing how well it ties and which
  charges have no order behind them.
- **Statements**: every statement by account, opened as it came (PDFs as they are, CSV and Excel as a
  table, Quicken files as a list).
- **Accounts**: rename, remove, or fix an account whose amounts came in backwards.

The daily picture stars two cartoon friends, Tony and Paul, who made the app: a drawing of one or both
daydreaming about a real recent purchase, checked by a second model against the receipt it shows. Their
photos in `Resources/` are the only personal thing in the repository.

Where it applies: a zip is opened like a folder; files that are not statements are listed with a plain
reason; European formats (semicolons, 31.12.2026, 1.234,56) are understood.

## For developers

**Build.** Requires Command Line Tools or Xcode for macOS 26.

```sh
scripts/build.sh
```

Output: `build/Spendthrift.app` and `build/Spendthrift.zip`. `statements/` is a git-ignored folder for
your own statements while developing.

**Where the data lives**: `~/Library/Application Support/Spendthrift/`

- `library.json`: accounts, every statement line, and what the app has learned about each payee
- `orders.json`: Amazon order histories and their matches
- `Backups/`: one copy per day for two weeks (**Help → Save a Backup to the Desktop** makes one now)
- `Pictures/`: the last thirty daily pictures and `gallery.json`
- `Statements/`: every statement exactly as added

The data is not inside the app, so replacing the app never touches it. It is read forgivingly (missing
fields get defaults, unknown fields are ignored, a damaged record is skipped). If the main file is
unreadable it is set aside, never overwritten, and the latest backup is restored. To move to another
Mac, copy that folder.

**Code map**

| Where | What it does |
| --- | --- |
| `BudgetStore.swift` | The single source of truth: the saved library, what the screens derive from it, and all stored state |
| `Store/` | The store's work, one file per concern: `+Navigation`, `+Importing`, `+Sorting`, `+Editing`, `+Orders`, `+Stories`, `+Noticed`, `+Accounts`, `+Insights` |
| `Cloud/` | Everything sent to a model, one file per job: client and cost ledger, blanking personal details, sorting, reading statements, pictures, lookups, trips, findings, short writing |
| `Library.swift` | The saved file, and `MerchantResolver` (which payee is this?) |
| `Importing.swift`, `CSV.swift`, `PDFStatement.swift`, `Scans.swift` | Reading CSV, OFX/QFX and PDF statements |
| `Orders.swift` | Order histories: reading the export, matching orders to card charges |
| `Suggestions.swift`, `AISchemas.swift` | Name cleanup, known businesses, bank categories, Apple Intelligence |
| `Insights.swift`, `Ask.swift`, `AskChat.swift` | The month's notes; questions answered from figures the app computes |
| `Views/` | The screens; `Components.swift` holds the shared pieces and `Theme` |

**Two rules the code keeps**: every number shown is computed in code (a model only reads intent or
writes prose around figures it is given), and every link goes through `BudgetStore.navigate`.

**Testing**

```sh
scripts/test.sh
```

builds the app and has it check itself, offline, exiting non-zero on any failure. It runs against the
made-up statements in `Tests/Fixtures` and, when this Mac has one, a copy of your own library, which is
never touched; `--fixtures` runs only the first. The checks live in
`Sources/Spendthrift/SelfTest.swift`: rules that need no data, sums that must agree for any library (the
verdict against its parts, a year against its months, each card against the page it opens), and doing
what a person would do (changing categories, following links and going back, importing twice, saving
and reloading). When a bug is found, a check for it goes in before the fix.

Useful environment variables: `SPENDTHRIFT_HOME` runs the app against a scratch folder,
`SPENDTHRIFT_SNAPSHOT=<dir>` saves a picture of each screen, `SPENDTHRIFT_IMPORT=a.csv:b.pdf` imports
files first, `SPENDTHRIFT_FAIL_CLOUD=credit|key|offline` simulates a cloud failure,
`SPENDTHRIFT_WIDTH` and `SPENDTHRIFT_DARK` set the picture width and Dark Mode, and
`SPENDTHRIFT_TIMING=1` prints each startup step with its cost. To preview how a statement will be read:
`build/Spendthrift.app/Contents/MacOS/Spendthrift --inspect file.pdf`

**Releasing.** Maintainers publish updates with `scripts/release.sh "What's new, in a sentence."`
after raising the number in `VERSION`. It builds, signs and publishes the zip to a releases repository
you configure (set it in `scripts/release.sh` and in `Sources/Spendthrift/Updater.swift`). The app
checks that repository once a day or from **Spendthrift → Check for Updates…**, and on one click
downloads the update, verifies the signature, replaces itself and reopens.

Signing needs no Apple Developer account. Create a self-signed code-signing certificate in your login
keychain (Keychain Access → Certificate Assistant → Create a Certificate, type Code Signing) with the name set as `SIGN_NAME` in `scripts/build.sh` (default `Spendthrift Signing`). The same certificate means the same app identity, so macOS keeps
permissions such as Downloads access across updates, and the updater refuses any download not signed by
that certificate or not a higher version. Back the certificate up (Keychain Access → My Certificates →
Export as .p12); if it is lost, existing installs will refuse every update and need one manual
reinstall (data is unaffected). An Apple Developer ID would also let you notarize the app and remove the
"Open Anyway" step; `notarytool` and `stapler` come with the Command Line Tools.
