# Adding and refreshing an Amazon order history

Without an order history, Amazon charges on your statements show as plain "Amazon". Adding one lets the
app name what was bought and file it. Amazon takes days to produce an export, so this is not a monthly
job: redo it every few months. Charges newer than the last export stay plain "Amazon" until then.

## 1. Request the export, per Amazon account

For each Amazon account that charges your cards:

1. Sign in at amazon.com, open Account, then **Request Your Data**
   (`amazon.com/hz/privacy-central/data-requests/preview.html`).
2. Choose **Your Orders** and submit. Amazon emails a link, usually within a day or two.
3. Download the zip. The app reads three files in it and ignores the rest:
   `Your Amazon Orders/Order History.csv`, `Digital Content Orders.csv` and
   `Your Returns & Refunds/Refund Details.csv`.

## 2. Drop it on the app

Drop the zip (or the unzipped `Your Orders` folder) onto the app. Exports from several accounts can be
dropped together. An order belongs to one export, so a newer export replaces the older copy of the same
orders and adds the new ones.

The app then, by itself:

- works out whose account it is from the billing address,
- has the model read any product listing it has not seen (plain name, budget category, kind of thing),
- matches orders to card charges, exact shipment or order totals first, then looser passes,
- keeps everything in `orders.json` in the data folder, apart from `library.json`.

## 3. What cannot be matched, and why

- Charges older than the oldest export you have added.
- Charges for the part of an order paid with reward points or a gift balance: the export does not say
  how much was paid that way, so the remainder matches nothing by amount. (The optional step below
  addresses this.)
- Whole Foods bought in a store without the Amazon app: there is no order.
- Orders on an account whose export was never added.

The Amazon page's "How this ties to your cards" card shows the current share of dollars matched and
lists the charges with no order behind them.

## 4. Optional, advanced: Amazon's Transactions page

Amazon's **Your Transactions** page (`https://www.amazon.com/cpe/yourpayments/transactions`) lists each
payment with its date, the card or balance used, the amount and the order number. That closes most of
the gap in section 3. It has no export button, and the app does not read it. Today it needs a helper
to read the order numbers off the page and write them into `orders.json`: an AI agent driving your
signed-in browser, or copying by hand. Only reading is needed; no order has to be opened and nothing on
the account changes. Each account holder needs their own pass, signed in as themselves.

Technical notes for whoever does the reading:

1. The list is a scrolling box that loads more rows as it nears the bottom and keeps only the rows on
   screen in the page, so rows must be collected while scrolling. Find the scrolling ancestor of a
   row, step `scrollTop` down by about 85% of its height, collect every link whose text contains
   `Order #` into a map keyed by position and text, and at the bottom wait for `scrollHeight` to grow
   (three waits with no growth means the end). Run in bursts of about 20 seconds; longer scripts time out.
2. Reduce each row to `yymmdd order-id amount instrument`, where instrument is the card's last four
   digits, `G` (gift balance) or `P` (points).
3. Tools that return results from the page may cut off long output, so do the matching inside the page:
   pass in the still-unmatched card charges (date and cents) and, for each, find the card row with the
   same amount dated from 2 days after to 6 days before the charge. Return only the charge index,
   order id, gift cents and points cents.
4. Write the links into `orders.json` under `pins`, with the app closed:

       { "<charge id>": { "order": "<order id>", "gift": <cents>, "points": <cents> } }

   Then clear `matches` and reopen the app (or re-add an export) so matching runs again. A pinned charge
   takes its order's items after the exact matches and before the looser ones.

The unmatched charges come from `library.json` and `orders.json`: spending lines whose statement text
mentions Amazon, AMZN, Whole Foods, Kindle, Audible or Prime Video, on accounts that are not kept apart,
with no entry in `orders.json` under `matches`.

## Checking a refresh

    SPENDTHRIFT_SNAPSHOT=/tmp/out SPENDTHRIFT_NO_SHOW=1 SPENDTHRIFT_NO_CLOUD=1 \
      SPENDTHRIFT_ORDERS="<export 1>:<export 2>" build/Spendthrift.app/Contents/MacOS/Spendthrift

prints how many charges matched by shop and by kind of match, and confirms that every exact match adds
up. Quit the app first; it uses the real data folder unless `SPENDTHRIFT_HOME` is set.
