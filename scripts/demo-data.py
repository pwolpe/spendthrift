#!/usr/bin/env python3
"""Writes a year of made-up statements to docs/demo, for trying the app and for the README pictures.

Nobody's real money is in here. The same seed gives the same files every time.
    scripts/demo-data.py
"""
import csv, random
from datetime import date, timedelta
from pathlib import Path

random.seed(7)
OUT = Path(__file__).resolve().parent.parent / "docs" / "demo"
START, END = date(2025, 11, 1), date(2026, 11, 10)
card, bank = [], []          # (date, description, amount): card purchases positive, bank money out positive


def days():
    d = START
    while d <= END:
        yield d
        d += timedelta(days=1)


def money(low, high):
    return round(random.uniform(low, high), 2)


EVERYDAY = [  # description, low, high, chance a day
    ("BLUE BOTTLE COFFEE BROOKLYN", 4.75, 13.5, 0.42), ("STARBUCKS STORE 0412", 5.2, 11.8, 0.12),
    ("TRADER JOE S #552", 38, 124, 0.20), ("WHOLEFDS MKT 10234", 46, 168, 0.12),
    ("TST* OLIVE & FIG", 58, 142, 0.07), ("SQ *NIGHT OWL RAMEN", 31, 66, 0.07),
    ("TST* LITTLE HAVANA CAFE", 24, 58, 0.05), ("SWEETGREEN PARK SLOPE", 14, 31, 0.10),
    ("DOORDASH*THAI VILLA", 28, 54, 0.07), ("UBER *TRIP", 11, 46, 0.11), ("MTA*NYCT PAYGO", 2.9, 2.9, 0.38),
    ("SHELL OIL 57442", 38, 67, 0.035), ("AMAZON MKTPL*", 12, 96, 0.13), ("TARGET 00012345", 22, 138, 0.05),
    ("CVS/PHARMACY #02184", 8, 47, 0.06), ("CHEWY.COM", 42, 88, 0.03), ("BARNES & NOBLE #2675", 14, 52, 0.02),
    ("AMC 9640 ONLINE", 19, 44, 0.02), ("UNIQLO USA 5TH AVE", 39, 160, 0.02), ("BROOKLYN WINE EXCHANGE", 22, 78, 0.04),
    ("HOME DEPOT #1225", 18, 190, 0.02),
]
MONTHLY = [  # day, description, amount
    (3, "NETFLIX.COM", 15.49), (5, "SPOTIFY USA", 11.99), (8, "NYTIMES*NYTIMES", 25.00), (11, "APPLE.COM/BILL", 9.99),
    (14, "PELOTON MEMBERSHIP", 44.00), (17, "ADOBE *CREATIVE CLOUD", 59.99), (21, "HULU 877-8244858", 17.99),
    (24, "PLANET FITNESS CLUB FEE", 24.99),
]
ONCE = [
    (date(2025, 11, 28), "APPLE STORE #R095", 1299.00), (date(2025, 12, 13), "NORDSTROM #0520", 318.40),
    (date(2025, 12, 16), "LEGO STORE ROCKEFELLER", 164.99), (date(2025, 12, 19), "ETSY.COM*CERAMICS", 92.00),
    (date(2026, 1, 9), "HEADSPACE ANNUAL", 69.99), (date(2026, 2, 14), "TST* LE COUCOU", 286.50),
    (date(2026, 3, 2), "PARK SLOPE VETERINARY", 412.00), (date(2026, 6, 20), "WAYFAIR*SOFA", 1180.00),
    (date(2026, 8, 30), "TICKETMASTER*MSG", 356.80), (date(2026, 9, 12), "REI #118 SOHO", 244.15),
    # Lisbon, in May: flights bought in March.
    (date(2026, 3, 11), "TAP AIR PORTUGAL", 1486.20), (date(2026, 5, 15), "HOTEL AVENIDA PALACE LISBOA", 1142.00),
    (date(2026, 5, 15), "UBER *TRIP LISBOA", 18.40), (date(2026, 5, 16), "PASTEIS DE BELEM LISBOA", 14.20),
    (date(2026, 5, 16), "TIME OUT MARKET LISBOA", 63.80), (date(2026, 5, 17), "MUSEU CALOUSTE GULBENKIAN", 28.00),
    (date(2026, 5, 17), "CERVEJARIA RAMIRO LISBOA", 121.50), (date(2026, 5, 18), "CP COMBOIOS DE PORTUGAL SINTRA", 11.00),
    (date(2026, 5, 18), "PALACIO DA PENA SINTRA", 40.00), (date(2026, 5, 19), "A VIDA PORTUGUESA LISBOA", 86.30),
    (date(2026, 5, 19), "BELCANTO LISBOA", 318.00), (date(2026, 5, 20), "FOREIGN TRANSACTION FEE", 18.44),
    # A long weekend in Vermont, in October.
    (date(2026, 10, 9), "HERTZ RENT-A-CAR LGA", 284.60), (date(2026, 10, 9), "STOWE MOUNTAIN LODGE", 742.00),
    (date(2026, 10, 10), "BEN & JERRYS WATERBURY VT", 17.50), (date(2026, 10, 10), "ALCHEMIST BREWERY STOWE VT", 46.00),
    (date(2026, 10, 11), "HEN OF THE WOOD WATERBURY", 164.20), (date(2026, 10, 12), "COLD HOLLOW CIDER MILL VT", 38.75),
]
AWAY = [(date(2026, 5, 14), date(2026, 5, 20)), (date(2026, 10, 9), date(2026, 10, 12))]

for d in days():
    away = any(a <= d <= b for a, b in AWAY)
    for name, low, high, chance in EVERYDAY:
        if not away and random.random() < chance * (1.25 if d.month == 12 else 1):
            card.append((d, name + ("%s" % random.choice(["AB12", "ZK40", "QT77"]) if name.endswith("*") else ""), money(low, high)))
    for day, name, amount in MONTHLY:
        if d.day == day:
            # One price creeps up in June, the kind of thing the app notices.
            card.append((d, name, 17.99 if name.startswith("NETFLIX") and d >= date(2026, 6, 1) else amount))
card += ONCE
card.append((date(2026, 4, 6), "TARGET 00012345", -42.18))          # a refund

# The bank account: pay in, the household's fixed costs out, and last month's card paid in full.
for d in days():
    if d.weekday() == 4 and (d - date(2025, 11, 7)).days % 14 == 0:
        bank.append((d, "ACME CORP PAYROLL DIR DEP", -4250.00))
        bank.append((d, "NORTHWIND DESIGN PAYROLL", -3120.00))
    if d.day == 1: bank.append((d, "PARKSIDE APARTMENTS RENT", 3200.00))
    if d.day == 6: bank.append((d, "CON EDISON OF NY", money(96, 148) + (70 if d.month in (7, 8, 1, 2) else 0)))
    if d.day == 9: bank.append((d, "VERIZON WIRELESS", 142.18))
    if d.day == 12: bank.append((d, "NELNET STUDENT LOAN", 386.00))
    if d.day == 15: bank.append((d, "VANGUARD BUY INVESTMENT", 600.00))
    if d.day == 20: bank.append((d, "ONLINE TRANSFER TO SAVINGS", 500.00))
    if d.day == 22: bank.append((d, "GEICO AUTO INSURANCE", 128.40))
    if d.day == 27: bank.append((d, "ZELLE TO MARIA DOG WALKER", 240.00))
    if d.day == 18 and random.random() < 0.5: bank.append((d, "ATM WITHDRAWAL 7TH AVE", 120.00))
    if (d.month, d.day) in ((3, 31), (6, 30), (9, 30), (12, 31)): bank.append((d, "INTEREST PAYMENT", -money(6, 11)))
bank.append((date(2026, 4, 14), "IRS USATAXPYMT", 1840.00))
bank.append((date(2025, 12, 19), "ACME CORP BONUS DIR DEP", -6500.00))
month = date(2025, 11, 1)
while month < date(2026, 11, 1):
    after = date(month.year + month.month // 12, month.month % 12 + 1, 1)
    total = round(sum(a for d, _, a in card if month <= d < after), 2)
    bank.append((after + timedelta(days=4), "CHASE CREDIT CRD AUTOPAY", total))
    card.append((after + timedelta(days=4), "AUTOMATIC PAYMENT - THANK YOU", -total))
    month = after

OUT.mkdir(parents=True, exist_ok=True)
with open(OUT / "Chase Sapphire 4417.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Transaction Date", "Post Date", "Description", "Category", "Type", "Amount", "Memo"])
    for d, name, amount in sorted(card):
        kind = "Payment" if "PAYMENT" in name else "Return" if amount < 0 else "Sale"
        w.writerow([d.strftime("%m/%d/%Y"), d.strftime("%m/%d/%Y"), name, "", kind, f"{-amount:.2f}", ""])
with open(OUT / "Everyday Checking 2290.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Date", "Description", "Debit", "Credit"])
    for d, name, amount in sorted(bank):
        w.writerow([d.strftime("%m/%d/%Y"), name, f"{amount:.2f}" if amount > 0 else "", f"{-amount:.2f}" if amount < 0 else ""])
print(f"{len(card)} card lines and {len(bank)} bank lines written to {OUT}")
