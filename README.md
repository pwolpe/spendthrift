# Spendthrift

A Mac app that reads your bank and card statements on your own computer and shows where your money
goes, whether you are living within your means, and where you could spend less. It can use AI to sort
payees, find trips and answer questions, and it works without any account linking.

Requires an Apple Silicon Mac on macOS 26. It is written in Swift with Apple's frameworks (SwiftUI,
Swift Charts, PDFKit, Vision, Foundation Models, Image Playground) and has no dependencies. The idea
started from [davidfowl/tally](https://github.com/davidfowl/tally).

## What it does

- **Am I living within my means?** The verdict answers it against all income, then again **on your pay
  alone**, without what investments paid out. Taxes and interest are shown apart from living costs.
- **What changed and why**: a month, or the last twelve months, against what is usual, in dollars that
  add up to the difference (a trip, one large charge, a new repeating charge, a price rise).
- **Bills and subscriptions**: found from the charges themselves, with what each costs a year, what
  crept up in price, what may be forgotten and what has stopped.
- **Budgets that set themselves** from the middle of your last six months, which you can overtype.
- **Needs and wants**: each payee is judged a need or a choice, so **Where to trim** ranks only what
  could be cut. **Ways to save** lists ideas in dollars a year, each opening the charges behind it.
- **Payees tidy themselves**: duplicates are combined and mix-ups separated when the app is sure, with
  an **Undo** for each; a few doubtful pairs are left for you.
- Reads CSV/TSV, Excel (.xlsx), PDF statements (including scans and password-protected ones), photos
  of statements, Quicken files (OFX, QFX, QBO), zips and whole folders, on your Mac. It works out the
  columns, the account and which way the amounts go. Overlapping statements are de-duplicated, and every
  import has an **Undo**. Each PDF is checked against the totals printed on it, and the import message
  says whether they matched to the cent.
- Sorts every payee automatically, in this order of trust: your own decisions, a built-in list of
  well-known businesses, the bank's own category, obvious words in the name, then AI for what is left.
  You can change anything: click a category, right-click for "only this charge", or say what a charge
  was in your own words.
- Finds trips and events, and estimates next month's everyday spending.
- Matches an Amazon order history to your card charges so "Amazon" becomes what was bought
  (see `docs/amazon-refresh.md`).
- Answers questions in plain English, and can carry out an instruction (file, rename or combine
  payees) after you click to confirm it.
- **Find This in My Mail** on any charge opens a search in your own mail for the amount around that
  date. The app reads nothing from your mail.
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

With an OpenRouter key entered in **Spendthrift → Settings…** the app also uses cloud models. Make your
own key at openrouter.ai and give it a spending limit. The key is kept in a private file only your
account can read, never in the app, its data or this repository. There are two kinds of model:

- **A writing and reading model** handles: PDFs and scans that do not add up to their printed totals
  (sent after name, address, email and account numbers are blanked, and accepted only when the
  reading matches the printed summary or the app's own); odd spreadsheets' columns; payee names and
  categories; trips and events; notices; the daily picture and its caption; Ask; and the short
  written summaries (**the short version**, sentences about what changed), which are built from
  figures the app computed and handed over.
- **Decision models** are small, fast models that never write. They answer typed questions: are these
  two payees the same business, which category is this, is this a need or a want. They are sent a
  statement line or payee name with its typical amount, scrubbed of numbers and emails. Each answer
  carries a confidence. The app acts on it alone only when it is high, records what it did, and
  offers **Undo**; lower answers go to **Double-Check** as a suggestion, or are ignored.

Two guarantees hold for both. Every number shown is computed in code. And text from a model that
contains a dollar amount the app did not supply is discarded, so a made-up figure never reaches a page.

Without a key everything computed in code still works: the verdict, what changed, bills, budgets,
savings, needs and wants (from each category's usual answer) and trips from the built-in rules. What
is skipped is the model-written sentences and automatic tidying; payees the rules cannot place wait in
Double-Check. If the key is missing, wrong or out of credit, or there is no internet, an import still
finishes on the on-device paths and a banner says what happened.

## The pages

- **Overview**: the first page, and it opens on the last twelve months. A banner with the day's
  picture and a **Month / Year** switch, then in order:
  - **The verdict**: what came in, how much went on living, taxes and interest, and what is left, with
    **on your pay alone** beneath. It opens **Money In and Out**, the full statement, with transfers
    between your own accounts left out and card payments counted once.
  - **The short version** (twelve months, with a key): two or three sentences about the stretch.
  - **What changed**: why the stretch differs from usual, each reason opening the charges behind it.
  - **Spending**, **Income** and **Investing** cards. Spending steps into where it went, the run of
    months, top payees, **Where to trim**, and in Year view a year in review you can save as PDF.
  - **Things noticed**, and the **Bills & Subscriptions** card (what repeats and what it costs a year,
    the next four due). It opens every bill by how often it comes, what crept up, what may be forgotten,
    and what has stopped.
  - **Ways to save**, in dollars a year, stepping into the charges behind each idea.
  - In Month view, a **Budget** card beside Bills: a target for each category from your last six
    months (trips left out). Step in to see each row, type your own target or return to automatic.
- **Back**: every link inside a page (a category, a month, a trip, a payee, an order, a statement) goes
  through one history, so **Back** (or ⌘[) returns to where you came from. Choosing a section in the
  sidebar starts fresh.
- **Transactions**: a searchable, filterable table with an inspector. Rename payees, see their history,
  move a charge to another trip, and use **Show in Statement** (right-click, the magnifier, or Space)
  or **Find This in My Mail**.
- **Payees**: everyone and everything money went to, with totals. A way a payee is written on
  statements can be made a payee of its own. A **Tidied for you** card at the top lists what the app
  combined or separated by itself, with an Undo for each, and any pairs it was not sure about.
- **Trips & Events**: runs of charges the model recognizes as a trip or occasion, with totals added up in
  code. A move you make is remembered when the model looks again.
- **Ask**: plain-English questions; the model reads the intent and the figures come from code. An
  instruction such as "file Trader Joe's under Groceries" is shown as what it would do and happens
  only after you confirm.
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
| `Store/` | The store's work, one file per concern: `+Navigation`, `+Importing`, `+Sorting`, `+Editing`, `+Orders`, `+Stories`, `+Noticed`, `+Accounts`, `+Insights`, `+Changes`, `+Reads` (the short version), `+Facts` (needs and wants), `+Tidy` (tidying payees), `+Caches` (values kept until the library changes) |
| `Cloud/` | Everything sent to a model, one file per job: client and cost ledger, blanking personal details, sorting, reading statements, pictures, lookups, trips, findings, short writing |
| `Cloud/Decisions.swift` | Decision models: typed yes/no and choice questions that return a confidence, used by tidying and needs and wants |
| `Library.swift` | The saved file, and `MerchantResolver` (which payee is this?) |
| `Importing.swift`, `CSV.swift`, `PDFStatement.swift`, `Scans.swift` | Reading CSV, OFX/QFX and PDF statements |
| `Orders.swift` | Order histories: reading the export, matching orders to card charges |
| `Suggestions.swift`, `AISchemas.swift` | Name cleanup, known businesses, bank categories, Apple Intelligence |
| `Insights.swift`, `Ask.swift`, `AskChat.swift` | The month's notes; questions answered from figures the app computes, and `ChatAction` (changes asked for in words, made after a confirming click) |
| `Changes.swift`, `Recurring.swift`, `Budgets.swift`, `Savings.swift`, `Tidy.swift` | Engines: transactions in, findings out. What changed, bills and subscriptions, budgets, ways to save, payee pairs to combine or separate |
| `MailSearch.swift` | The mail search for a charge (amount, a week either side), opened in your own mail |
| `Views/` | The screens; `Components.swift` holds the shared pieces and `Theme` |

**Two rules the code keeps**: every number shown is computed in code (a model only reads intent or
writes prose around figures it is given), and every link goes through `BudgetStore.navigate`.

**Testing**

```sh
scripts/test.sh
```

builds the app and has it check itself, offline, exiting non-zero on any failure. It runs against the
made-up statements in `Tests/Fixtures` and, when this Mac has one, a copy of your own library, which is
never touched; `--fixtures` runs only the first, and `--library DIR` adds a copy of another data folder.
It then prints how long the app takes to open, which is not a pass or fail. The checks live in
`Sources/Spendthrift/SelfTest.swift`, in three sections: rules that need no data (including what leaves
the Mac, findings, what changed and budgets), sums that must agree for any library (the verdict against
its parts, a year against its months, each card against the page it opens), and doing what a person
would do (changing categories, following links and going back, importing twice, saving and reloading).
When a bug is found, a check for it goes in before the fix.

Useful environment variables: `SPENDTHRIFT_HOME` runs the app against a scratch folder,
`SPENDTHRIFT_SNAPSHOT=<dir>` saves a picture of each screen, `SPENDTHRIFT_IMPORT=a.csv:b.pdf` imports
files first, `SPENDTHRIFT_FAIL_CLOUD=credit|key|offline` simulates a cloud failure,
`SPENDTHRIFT_WIDTH` and `SPENDTHRIFT_DARK` set the picture width and Dark Mode, and
`SPENDTHRIFT_TIMING=1` prints each startup step with its cost, and `SPENDTHRIFT_BENCH=1` times what
pages do over and over, then quits. To preview how a statement will be read:
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
