---
description: Check that each purchase is on the right card and that every card credit is being used
argument-hint: "[months, default 12]"
---

Audit how the cards in the Spendthrift library were used against what each card currently offers.
The goal is a short list of things to change, with dollar amounts.

## Privacy

- The spending stays on this Mac. Web searches and page fetches may name a card product and a
  benefit ("Amex Platinum CLEAR credit 2026"). They never contain an amount, a date of a charge, a
  payee from the library, an account number or the person's name.
- Write nothing under the repository. The benefit table and the reports live in
  `~/Library/Application Support/Spendthrift/CardAudit/`.

## Steps

1. **Read the spending.** Run `scripts/card-audit.py --months ${ARGUMENTS:-12}` and read all of
   its output. It lists each card's totals by kind, by month and by calendar year, fees, credits
   and refunds, repeating charges, largest payees, payees on more than one card, and what was paid
   from bank accounts instead.

2. **Read what is already known.** In the CardAudit folder, read `benefits.json` (the last benefit
   table, with the date each card was checked and the sources) and the newest dated report.

3. **Refresh the benefits from the web.** For every card product the script lists, look up the
   terms as they stand today: each credit (amount, how often it resets, what triggers it, whether
   it needs enrolling, when it ends), earning rates by kind of purchase, annual and extra-card
   fees, the foreign transaction fee, and travel insurance in one line. Start from the sources
   saved in `benefits.json`, add the issuer's own page, and search for changes since the saved
   date. Use the web-fetch agent, one per card, in parallel. Where sources disagree or the issuer's
   page could not be read, record the benefit as unconfirmed and say who said what; never fill a
   gap from memory. Then rewrite `benefits.json` in the same shape, with today's date and the
   sources used, and note in the report every term that changed since last time.

4. **Compare.** Work only from the script's numbers and the refreshed table.
   - *Credits not collected:* for each credit, find its postings among the card's credits. Count
     the periods (months, quarters, half-years, years) in the window with no posting. Name the
     qualifying charge that sat on another card, if there was one.
   - *Credits about to lapse:* anything unused in the current period, with its last day.
   - *Wrong card:* for each kind of spending, the card in this wallet with the best return, and
     what was put elsewhere. Value points at 1.5 cents unless `benefits.json` holds a figure the
     person chose. Leave out differences under $50 a year.
   - *Paid for and included:* subscriptions and memberships being paid that a card already gives
     free or refunds.
   - *From the bank instead:* repeating bills and large payments that a card would take without a
     surcharge. Say when a surcharge or lost autopay discount would likely cancel the gain.
   - *Fees:* each card's yearly fee against what it returned in credits and rewards this window.
   - Apply any monthly or yearly caps and spending thresholds using the by-month and
     by-calendar-year totals.

5. **Say what cannot be seen.** Credits applied inside an app (ride and delivery credits), tiers
   that depend on a balance held elsewhere, and how recent each card's last charge is. If one
   missing fact decides a large part of the answer, ask for it once at the end.

6. **Report.** Lead with the total and the three changes worth the most. Then: credits not
   collected (table: credit, what happened, lost, do this), credits about to lapse, wrong-card
   spending, things checked and found right, benefit terms that changed since the last audit, what
   could not be seen, sources. Compared with the last report, mark each earlier finding fixed,
   still open or new. Save the same text as `CardAudit/<today>.md`.

Plain words, as in the app: "payee", "charge", "you". Every dollar figure comes from the script's
output or the benefit table, with the sum shown when it is not a single line.
