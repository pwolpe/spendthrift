#!/usr/bin/env python3
"""What each card was used for, as plain text for a card audit.

Reads a Spendthrift library and prints, for the last N months: what went on each card by
category and by payee, every credit and refund, fees, charges that repeat, payees that appear on
more than one card, and large payments made from bank accounts that a card could have taken.

Nothing is sent anywhere and nothing is written: the output is your own spending, so keep it out
of the repository. `/card-audit` in Claude Code runs this and compares it with each card's
current benefits.

    scripts/card-audit.py [--library DIR] [--months 12] [--top 60] [--json]
"""
import argparse
import collections
import datetime
import json
import os
import re
import sys

AIRLINE = re.compile(
    r"AIRLINE|AIRWAYS|AIR LINES|\bUNITED\s+\d|UNITED AIR|\bDELTA AIR|\bLAN AIR|JETBLUE|"
    r"AER LINGUS|LUFTHANSA|AIR FRANCE|AIR CANADA|\bKLM\b|QANTAS|EMIRATES|RYANAIR|EASYJET",
    re.I,
)
PAYMENTS = {"Card Payment", "Payments & Transfers", "Transfer"}
FEES = {"Annual Fee", "Fees & Interest", "Service Fee"}


def load(library_dir):
    path = os.path.join(library_dir, "library.json")
    with open(path) as f:
        return json.load(f)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--library", default=os.environ.get(
        "SPENDTHRIFT_HOME", os.path.expanduser("~/Library/Application Support/Spendthrift")))
    p.add_argument("--months", type=int, default=12)
    p.add_argument("--top", type=int, default=60, help="payees listed per card")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()

    lib = load(a.library)
    merchants = lib.get("merchants", {})
    accounts = {x["id"]: x for x in lib.get("accounts", [])}
    entries = lib.get("entries", [])
    if not entries:
        sys.exit("The library holds no charges.")

    last = max(e["date"] for e in entries)
    end = datetime.date.fromisoformat(last)
    month = end.month - a.months % 12
    year = end.year - a.months // 12 - (1 if month < 1 else 0)
    month = month + 12 if month < 1 else month
    start = datetime.date(year, month, min(end.day, 28)).isoformat()

    def named(e):
        k = e.get("merchantKey", "")
        if k.startswith("known:"):
            return k[6:], k[6:]
        m = merchants.get(k)
        return (m.get("name", k), m.get("category", "Other")) if m else (k, "Other")

    def kind(category, text):
        if AIRLINE.search(text):
            return "Flights"
        return category

    report = {"from": start, "to": last, "cards": [], "banks": [], "onSeveralCards": []}
    by_account = collections.defaultdict(list)
    for e in entries:
        if e["date"] >= start:
            by_account[e["accountID"]].append(e)

    payee_cards = collections.defaultdict(lambda: collections.defaultdict(float))

    for aid, acct in accounts.items():
        rows = by_account.get(aid, [])
        if not rows:
            continue
        is_card = bool(acct.get("product"))
        if not is_card:
            big = []
            for e in rows:
                name, cat = named(e)
                if e["amount"] >= 1000 and not name.endswith("Card Payment") and cat not in PAYMENTS:
                    big.append({"date": e["date"], "amount": round(e["amount"], 2), "payee": name,
                                "category": cat, "line": e["description"][:60]})
            repeats = collections.defaultdict(list)
            for e in rows:
                name, cat = named(e)
                if e["amount"] > 0 and not name.endswith("Card Payment") and cat not in PAYMENTS:
                    repeats[name].append(e)
            bills = [{"payee": n, "times": len(v), "total": round(sum(x["amount"] for x in v), 2)}
                     for n, v in repeats.items() if len({x["date"][:7] for x in v}) >= 3]
            report["banks"].append({
                "name": acct["name"],
                "large": sorted(big, key=lambda r: -r["amount"])[:40],
                "repeating": sorted(bills, key=lambda r: -r["total"])[:30],
            })
            continue

        kinds = collections.defaultdict(lambda: [0.0, 0])
        payees = collections.defaultdict(lambda: {"total": 0.0, "times": 0, "months": set(),
                                                 "category": "", "line": "", "amounts": []})
        credits, fees = [], []
        months = collections.defaultdict(float)
        years = collections.defaultdict(float)
        for e in rows:
            name, cat = named(e)
            text = e["description"]
            if cat in PAYMENTS or name.endswith("Card Payment"):
                continue
            if cat in FEES or name in FEES:
                fees.append({"date": e["date"], "amount": round(e["amount"], 2), "line": text[:60]})
                continue
            k = kind(cat, text)
            if e["amount"] < 0:
                credits.append({"date": e["date"], "amount": round(e["amount"], 2),
                                "line": text[:70],
                                "statementCredit": bool(re.search(r"\bcredit\b", text, re.I))})
            kinds[k][0] += e["amount"]
            kinds[k][1] += 1
            months[e["date"][:7]] += e["amount"]
            years[e["date"][:4]] += e["amount"]
            x = payees[name]
            x["total"] += e["amount"]
            x["times"] += 1
            x["category"] = k
            x["line"] = text[:48]
            if e["amount"] > 0:
                x["months"].add(e["date"][:7])
                x["amounts"].append(round(e["amount"], 2))
                payee_cards[name][acct.get("product") or acct["name"]] += e["amount"]

        listed = sorted(payees.items(), key=lambda kv: -kv[1]["total"])
        top = [{"payee": n, "total": round(v["total"], 2), "times": v["times"],
                "category": v["category"], "line": v["line"]} for n, v in listed[:a.top]]
        repeating = []
        for n, v in listed:
            if len(v["months"]) >= 3:
                usual = collections.Counter(v["amounts"]).most_common(1)[0]
                repeating.append({"payee": n, "months": len(v["months"]), "times": v["times"],
                                  "total": round(v["total"], 2), "usual": usual[0],
                                  "category": v["category"], "line": v["line"]})
        report["cards"].append({
            "name": acct["name"], "product": acct.get("product"),
            "lastCharge": max(e["date"] for e in rows),
            "spent": round(sum(v[0] for v in kinds.values()), 2),
            "kinds": sorted(([k, round(v[0], 2), v[1]] for k, v in kinds.items()),
                            key=lambda r: -r[1]),
            "byMonth": sorted((m, round(t, 2)) for m, t in months.items()),
            "byCalendarYear": sorted((y, round(t, 2)) for y, t in years.items()),
            "payees": top, "repeating": repeating,
            "credits": sorted(credits, key=lambda r: r["date"]),
            "fees": sorted(fees, key=lambda r: r["date"]),
        })

    for name, cards in payee_cards.items():
        if len(cards) > 1 and sum(cards.values()) >= 200:
            report["onSeveralCards"].append(
                {"payee": name, "cards": {c: round(t, 2) for c, t in cards.items()}})
    report["onSeveralCards"].sort(key=lambda r: -sum(r["cards"].values()))

    if a.json:
        json.dump(report, sys.stdout, indent=1)
        return

    out = print
    out(f"Card use from {report['from']} to {report['to']}")
    for c in report["cards"]:
        out(f"\n=== {c['product']} ({c['name']}): ${c['spent']:,.2f} after refunds and credits, "
            f"last charge {c['lastCharge']}")
        out("  By kind")
        for k, t, n in c["kinds"]:
            out(f"    {t:12,.2f}  {n:4d}  {k}")
        out("  By calendar year: " + ", ".join(f"{y} ${t:,.0f}" for y, t in c["byCalendarYear"]))
        out("  By month: " + ", ".join(f"{m} ${t:,.0f}" for m, t in c["byMonth"]))
        out("  Fees")
        for f in c["fees"]:
            out(f"    {f['date']}  {f['amount']:10,.2f}  {f['line']}")
        out("  Credits and refunds (* names itself a credit)")
        for r in c["credits"]:
            out(f"    {r['date']}  {r['amount']:10,.2f} {'*' if r['statementCredit'] else ' '} {r['line']}")
        out("  Repeating charges (months seen, times, total, usual amount)")
        for r in c["repeating"]:
            out(f"    {r['months']:2d}  {r['times']:3d}  {r['total']:10,.2f}  {r['usual']:9,.2f}  "
                f"{r['payee'][:28]:28s}  {r['category'][:16]:16s}  {r['line']}")
        out(f"  Largest payees (top {a.top})")
        for r in c["payees"]:
            out(f"    {r['total']:12,.2f}  {r['times']:3d}  {r['payee'][:28]:28s}  "
                f"{r['category'][:16]:16s}  {r['line']}")
    out("\n=== Payees on more than one card")
    for r in report["onSeveralCards"][:60]:
        out("    " + r["payee"][:28].ljust(28) + "  "
            + ", ".join(f"{c} ${t:,.0f}" for c, t in r["cards"].items()))
    for b in report["banks"]:
        out(f"\n=== Paid from {b['name']} (not by card)")
        out("  Repeating")
        for r in b["repeating"]:
            out(f"    {r['total']:12,.2f}  {r['times']:3d}  {r['payee']}")
        out("  $1,000 or more")
        for r in b["large"]:
            out(f"    {r['date']}  {r['amount']:12,.2f}  {r['payee'][:28]:28s}  {r['category'][:16]:16s}  {r['line']}")


if __name__ == "__main__":
    main()
