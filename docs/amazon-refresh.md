# Refreshing the Amazon data

Order history is not a monthly thing: Amazon takes days to produce an export. This is what
was done in November 2026 and what to repeat every three to six months. Card and bank
statements keep working without any of it; charges newer than the last refresh simply show
as plain "Amazon" until the next one.

## 1. A fresh order history, per account

For each Amazon account that charges the household's cards (two, as of November 2026):

1. Sign in at amazon.com → Account → **Request Your Data** (`amazon.com/hz/privacy-central/data-requests/preview.html`).
2. Choose **Your Orders** and submit. Amazon emails a link, usually within a day or two.
3. Download the zip. It contains `Your Amazon Orders/Order History.csv`,
   `Digital Content Orders.csv` and `Your Returns & Refunds/Refund Details.csv`; the app
   reads those three and ignores the rest (delivery photos, cart history).
4. Drop the zip (or the unzipped `Your Orders` folder) onto the app. Several people's
   exports can be dropped together; an order belongs to one export, so a newer export
   replaces the older copy of the same orders and adds the new ones.

The app then, by itself:

- works out whose account it is from the billing address,
- has the model read any product listing it hasn't seen (plain name, budget category, kind of thing),
- matches orders to card charges (exact shipment or order totals first, then the looser passes),
- keeps everything in `orders.json` in the data folder, apart from `library.json`.

A copy of each export is kept, out of source control, in `statements/Amazon/`.

## 2. Amazon's own record of card charges (closes most of the remaining gap)

The export does not say how much of an order was paid with reward points or a gift balance,
so a charge for "the rest" matches nothing by amount. Amazon's **Your Transactions** page
does say: `https://www.amazon.com/cpe/yourpayments/transactions` lists every payment with
its date, the card or balance used, the amount and the order number. In November 2026 it
went back to June 2020 (1,169 rows on one account) and tied 135 charges ($4,775).

It has no export button. What worked, with Claude driving Chrome while signed in:

1. Open the page. The list is a scrolling box that loads more as it nears the bottom and
   only keeps the rows on screen in the page, so rows have to be collected while scrolling:
   find the scrolling ancestor of a row, step `scrollTop` down by ~85% of its height,
   collect every link whose text contains `Order #` into a map keyed by position and text,
   and at the bottom wait for `scrollHeight` to grow (three waits with no growth = the end).
   Run it in bursts of about 20 seconds; longer scripts time out.
2. Reduce each row to `yymmdd order-id amount instrument`, where instrument is the card's
   last four digits, `G` (gift balance) or `P` (points).
3. The tool that returns results from the page cuts off long output, so do the matching
   inside the page: pass in the list of still-unmatched card charges (date and cents) and,
   for each, find the card row with the same amount dated from 2 days after to 6 days
   before the charge. Return only `charge index, order id, gift cents, points cents`.
4. Save the links into `orders.json` under `pins` as
   `{ "<charge id>": { "order": "<order id>", "gift": cents, "points": cents } }`
   with the app closed, clear `matches`, and reopen (or re-add an export) so matching runs again.
   A pinned charge takes its order's items after the exact matches and before the looser ones.

Only reading was done on the page: no order was opened and nothing on the account changed.
The other account holder has their own Transactions page; the same pass there needs them signed in.

The list of unmatched charges comes from `library.json` and `orders.json`: spending lines
whose statement text mentions Amazon, AMZN, Whole Foods, Kindle, Audible or Prime Video,
on accounts that are not kept apart, with no entry in `orders.json` → `matches`.

## 3. What can't be tied, and why

- Charges older than the Transactions page reaches (before mid-2020 in November 2026).
- Whole Foods bought in the store without the Amazon app: there is no order.
- Orders on an account whose export was never added.

The Amazon page's "How this ties to your cards" card shows the current figure
(96.3% of the dollars in November 2026) and lists the charges with no order behind them.

## Checking a refresh

    SPENDTHRIFT_SNAPSHOT=/tmp/out SPENDTHRIFT_NO_SHOW=1 SPENDTHRIFT_NO_CLOUD=1 \
      SPENDTHRIFT_ORDERS="<export 1>:<export 2>" build/Spendthrift.app/Contents/MacOS/Spendthrift

prints how many charges matched by shop and by kind of match, and confirms that every exact
match adds up. Quit the app first; it uses the real data folder unless `SPENDTHRIFT_HOME` is set.
