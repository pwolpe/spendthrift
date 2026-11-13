#!/usr/bin/env python3
"""Writes the made-up cases the model benchmark uses, to Tests/Bench.

Nobody's real money is in here. Each household is a year of card charges with trips and events
planted in it, so which charge belongs to which trip is known for certain, not taken from a model.
pairs.tsv holds pairs of statement lines that are one business or two. The same seed gives the
same files every time.
    scripts/bench-data.py

One charge per line: date, statement text, amount, category, answer. The answer is:
    (empty)   ordinary life: belongs to no trip or event
    a name    the trip or event the charge belongs to
    ?         could fairly go either way (a ride on a day away): not scored
    !name     bait: looks like travel but is not (a weekly commute, an online order from abroad,
              a local restaurant named for a faraway city). Scored on being left out.
"""
import random
from datetime import date, timedelta
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Tests" / "Bench"
START, END = date(2025, 11, 1), date(2026, 10, 31)

DINING, GROCERIES, WINE, SHOPPING, CAR = "Dining", "Groceries", "Wine & Spirits", "Shopping", "Car & Transportation"
BILLS, SUBS, HEALTH, HOME, TRAVEL = "Bills & Utilities", "Subscriptions", "Health & Fitness", "Home", "Travel"
FUN, FEES, GIFTS, CARE = "Entertainment", "Fees & Interest", "Gifts & Giving", "Personal Care"


def d(text):
    y, m, day = (int(p) for p in text.split("-"))
    return date(y, m, day)


# Small things bought on a trip whose statement line says nothing about where: the dates are the only clue.
ABROAD = [("TAXI 4471", 9, 38, CAR), ("CAFE CENTRAL", 6, 24, DINING), ("MINI MARKET 24H", 4, 31, GROCERIES), ("PHARMACY 0221", 7, 29, HEALTH),
          ("KIOSK 7", 3, 12, SHOPPING), ("SOUVENIRS & GIFTS", 12, 60, SHOPPING), ("MUSEUM SHOP", 14, 52, SHOPPING)]
AT_HOME_ABROAD = [("SQ *COFFEE BAR", 5, 16, DINING), ("PARKING LOT 12", 8, 30, CAR), ("SQ *FARMERS MARKET", 9, 44, GROCERIES),
                  ("YELLOW CAB 2281", 11, 42, CAR), ("TST* THE COPPER KETTLE", 38, 120, DINING), ("GIFT SHOP", 10, 55, SHOPPING)]


def household(seed, everyday, monthly, weekly_bait, once, trips, places):
    """everyday: (text, low, high, chance a day, category, answer, bought in person)
    monthly: (day, text, amount, category); weekly_bait: (weekday, text, low, high, category, answer)
    once: (date, text, amount, category, answer); trips: (answer, first day, last day, [(date, text, amount, category)])
    places: trip to (the place names its statement lines end with, whether it is abroad)"""
    rng = random.Random(seed)
    away = set()
    for _, first, last, _ in trips:
        if first and last:
            day = d(first)
            while day <= d(last):
                away.add(day)
                day += timedelta(days=1)
    rows = []
    day = START
    while day <= END:
        for text, low, high, chance, category, answer, in_person in everyday:
            # Nobody buys coffee at home while they are away.
            if in_person and day in away:
                continue
            if rng.random() < chance:
                rows.append((day, text, round(rng.uniform(low, high), 2), category, answer))
        for when, text, amount, category in monthly:
            if day.day == when:
                rows.append((day, text, amount, category, ""))
        for weekday, text, low, high, category, answer in weekly_bait:
            if day.weekday() == weekday and day not in away:
                rows.append((day, text, round(rng.uniform(low, high), 2), category, answer))
        day += timedelta(days=1)
    for when, text, amount, category, answer in once:
        rows.append((d(when), text, amount, category, answer))
    for answer, first, last, charges in trips:
        endings, abroad = places.get(answer, ([], False))
        for when, text, amount, category in charges:
            # Real statements often leave the city off. Half of what was bought while away loses it here
            # (never the hotel, and never a booking paid ahead, which only its wording ties to the trip).
            during = first and d(first) <= d(when) <= d(last)
            if during and category != TRAVEL and rng.random() < 0.5:
                for ending in endings:
                    if text.endswith(" " + ending):
                        text = text[: -len(ending) - 1]
                        break
            rows.append((d(when), text, amount, category, answer))
        if first and last:
            # And a few small things each trip that never said where they were.
            span = (d(last) - d(first)).days
            for _ in range(2 + span // 3):
                text, low, high, category = rng.choice(ABROAD if abroad else AT_HOME_ABROAD)
                rows.append((d(first) + timedelta(days=rng.randint(0, span)), text, round(rng.uniform(low, high), 2), category, answer))
    rows.sort(key=lambda r: (r[0], r[1]))
    return rows


BROOKLYN = dict(
    seed=11,
    everyday=[
        ("BLUE BOTTLE COFFEE BROOKLYN NY", 4.75, 13.5, 0.40, DINING, "", True),
        ("TRADER JOE S #552 BROOKLYN NY", 38, 124, 0.20, GROCERIES, "", True),
        ("WHOLEFDS PSL 10234 BROOKLYN NY", 46, 168, 0.11, GROCERIES, "", True),
        ("TST* OLIVE & FIG BROOKLYN NY", 58, 142, 0.06, DINING, "", True),
        ("SQ *NIGHT OWL RAMEN BROOKLYN NY", 31, 66, 0.06, DINING, "", True),
        ("SWEETGREEN PARK SLOPE BROOKLYN NY", 14, 31, 0.09, DINING, "", True),
        ("DOORDASH*THAI VILLA", 28, 54, 0.06, DINING, "", True),
        ("UBER *TRIP HELP.UBER.COM", 11, 46, 0.09, CAR, "", True),
        ("MTA*NYCT PAYGO NEW YORK NY", 2.9, 2.9, 0.36, CAR, "", True),
        ("SHELL OIL 57442 BROOKLYN NY", 38, 67, 0.03, CAR, "", True),
        ("AMAZON MKTPL*2K4RT81", 12, 96, 0.12, SHOPPING, "", False),
        ("TARGET 00012345 BROOKLYN NY", 22, 138, 0.05, SHOPPING, "", True),
        ("CVS/PHARMACY #02184 BROOKLYN NY", 8, 47, 0.06, HEALTH, "", True),
        ("CHEWY.COM 800-672-4399 FL", 42, 88, 0.03, SHOPPING, "", False),
        ("BROOKLYN WINE EXCHANGE BROOKLYN NY", 22, 78, 0.04, WINE, "", True),
        ("HOME DEPOT #1225 BROOKLYN NY", 18, 90, 0.02, HOME, "", True),
        # Bait: neighbourhood places named for somewhere far away.
        ("TST* LISBOA GRILL BROOKLYN NY", 44, 96, 0.03, DINING, "!places named for elsewhere", True),
        ("LITTLE TOKYO SUSHI BROOKLYN NY", 36, 84, 0.03, DINING, "!places named for elsewhere", True),
        # Bait: a drink at a hotel in one's own city is not a stay.
        ("THE HARBOR HOTEL LOBBY BAR BROOKLYN NY", 24, 68, 0.02, DINING, "!hotel bars at home", True),
        ("GRAND STREET HOTEL RESTAURANT BROOKLYN NY", 62, 148, 0.015, DINING, "!hotel bars at home", True),
    ],
    monthly=[
        (3, "NETFLIX.COM", 15.49, SUBS), (5, "SPOTIFY USA", 11.99, SUBS), (8, "NYTIMES*NYTIMES", 25.00, SUBS),
        (12, "CON EDISON OF NY", 142.18, BILLS), (15, "VERIZON WIRELESS", 96.40, BILLS),
        (19, "GEICO *AUTO", 128.00, BILLS), (24, "PLANET FITNESS CLUB FEE BROOKLYN NY", 24.99, HEALTH),
    ],
    weekly_bait=[
        # Bait: a day at the office in another state, every Tuesday of the year.
        (1, "NJ TRANSIT RAIL NEWARK NJ", 16.5, 16.5, CAR, "!weekly commute"),
        (1, "SQ *PRINCETON SOUP CO PRINCETON NJ", 11, 19, DINING, "!weekly commute"),
    ],
    once=[
        ("2025-11-28", "APPLE STORE #R095 NEW YORK NY", 1299.00, SHOPPING, ""),
        ("2025-12-16", "LEGO STORE ROCKEFELLER NEW YORK NY", 164.99, SHOPPING, ""),
        ("2026-02-14", "TST* LE PETIT JARDIN NEW YORK NY", 286.50, DINING, ""),
        ("2026-06-20", "WAYFAIR*SOFA 4455", 1180.00, HOME, ""),
        ("2026-08-30", "TICKETMASTER*MSG NEW YORK NY", 356.80, FUN, ""),
        # Bait: things ordered online from abroad while at home.
        ("2025-11-19", "LIBERTY LONDON GB", 148.00, SHOPPING, "!ordered from abroad"),
        ("2025-11-19", "FOREIGN TRANSACTION FEE", 4.44, FEES, "!ordered from abroad"),
        ("2026-06-03", "MUJI ONLINE STORE TOKYO JP", 86.20, SHOPPING, "!ordered from abroad"),
        ("2026-06-03", "FOREIGN TRANSACTION FEE", 2.59, FEES, "!ordered from abroad"),
        ("2026-08-12", "SP * PARIS PAPETERIE FR", 54.00, SHOPPING, "!ordered from abroad"),
    ],
    trips=[
        ("Miami over New Year", "2025-12-27", "2026-01-02", [
            ("2025-11-14", "JETBLUE 2792145338211 JFK-MIA", 618.40, TRAVEL),
            ("2025-12-27", "THE BETSY HOTEL MIAMI BEACH FL", 1986.00, TRAVEL),
            ("2025-12-27", "STONE CRAB HOUSE MIAMI BEACH FL", 212.60, DINING),
            ("2025-12-28", "WYNWOOD COFFEE ROASTERS MIAMI FL", 14.25, DINING),
            ("2025-12-28", "PEREZ ART MUSEUM MIAMI FL", 32.00, FUN),
            ("2025-12-29", "CALLE OCHO CUBAN KITCHEN MIAMI FL", 68.90, DINING),
            ("2025-12-30", "EVERGLADES AIRBOAT TOURS HOMESTEAD FL", 96.00, FUN),
            ("2025-12-31", "MANDOLIN AEGEAN BISTRO MIAMI FL", 348.00, DINING),
            ("2026-01-01", "OCEAN DRIVE SANDWICH CO MIAMI BEACH FL", 31.40, DINING),
            ("2026-01-02", "WALGREENS #4421 MIAMI BEACH FL", 18.72, HEALTH),
        ]),
        ("Chicago weekend", "2026-02-06", "2026-02-08", [
            ("2026-02-06", "LOU MALNATIS PIZZERIA CHICAGO IL", 58.20, DINING),
            ("2026-02-07", "ART INSTITUTE OF CHICAGO CHICAGO IL", 64.00, FUN),
            ("2026-02-08", "THE DRAKE HOTEL CHICAGO IL", 512.30, TRAVEL),
        ]),
        ("Kitchen renovation", None, None, [
            ("2026-03-03", "BKLYN KITCHEN & BATH REMODEL DEPOSIT", 6500.00, HOME),
            ("2026-03-09", "FERGUSON BATH KITCHEN GALLERY NEW YORK NY", 2840.00, HOME),
            ("2026-03-12", "IKEA BROOKLYN KITCHEN CABINETS NY", 3180.55, HOME),
            ("2026-03-18", "CAESARSTONE COUNTERTOPS FABRICATOR NY", 4120.00, HOME),
            ("2026-03-21", "HOME DEPOT #1225 KITCHEN TILE BROOKLYN NY", 684.30, HOME),
            ("2026-03-27", "BKLYN KITCHEN & BATH REMODEL PROGRESS", 6500.00, HOME),
            ("2026-04-02", "AJ MADISON KITCHEN APPLIANCES BROOKLYN NY", 5260.00, HOME),
            ("2026-04-10", "BKLYN KITCHEN & BATH REMODEL FINAL", 4200.00, HOME),
        ]),
        ("Japan", "2026-04-18", "2026-04-28", [
            ("2026-01-15", "JAPAN AIRLINES JFK-HND 1312245781100", 2864.00, TRAVEL),
            ("2026-04-02", "JR EAST RAIL PASS TOKYO JP", 412.00, TRAVEL),
            ("2026-04-18", "HOTEL NIWA TOKYO JP", 1245.00, TRAVEL),
            ("2026-04-19", "ICHIRAN SHIBUYA TOKYO JP", 21.40, DINING),
            ("2026-04-19", "TEAMLAB PLANETS TOKYO JP", 54.00, FUN),
            ("2026-04-20", "TSUKIJI SUSHI SEI TOKYO JP", 88.30, DINING),
            ("2026-04-21", "UNIQLO GINZA TOKYO JP", 124.60, SHOPPING),
            ("2026-04-22", "SUICA MOBILE CHARGE TOKYO JP", 20.00, CAR),
            ("2026-04-23", "RYOKAN YOSHIDA SANSO KYOTO JP", 1680.00, TRAVEL),
            ("2026-04-24", "NISHIKI MARKET KYOTO JP", 36.80, DINING),
            ("2026-04-25", "KINKAKUJI TEMPLE KYOTO JP", 8.00, FUN),
            ("2026-04-26", "GION KAPPO SAKAMOTO KYOTO JP", 264.00, DINING),
            ("2026-04-27", "LAWSON KYOTO EKIMAE JP", 9.15, GROCERIES),
        ]),
        ("Lisbon", "2026-05-15", "2026-05-20", [
            ("2026-03-11", "TAP AIR PORTUGAL 0472213345690", 1486.20, TRAVEL),
            ("2026-05-15", "HOTEL AVENIDA PALACE LISBOA PT", 1142.00, TRAVEL),
            ("2026-05-16", "PASTEIS DE BELEM LISBOA PT", 14.20, DINING),
            ("2026-05-16", "TIME OUT MARKET LISBOA PT", 63.80, DINING),
            ("2026-05-17", "MUSEU CALOUSTE GULBENKIAN LISBOA PT", 28.00, FUN),
            ("2026-05-17", "CERVEJARIA RAMIRO LISBOA PT", 121.50, DINING),
            ("2026-05-18", "CP COMBOIOS DE PORTUGAL SINTRA PT", 11.00, CAR),
            ("2026-05-18", "PALACIO DA PENA SINTRA PT", 40.00, FUN),
            ("2026-05-19", "A VIDA PORTUGUESA LISBOA PT", 86.30, SHOPPING),
            ("2026-05-19", "BELCANTO LISBOA PT", 318.00, DINING),
        ]),
        ("Peru", "2026-07-08", "2026-07-19", [
            # Paid in Lisbon, for a trek two months later: it belongs to Peru.
            ("2026-05-17", "ANDEAN TREKS INCA TRAIL CUSCO PE", 2380.00, TRAVEL),
            ("2026-04-30", "ANDES AIR PERU JFK-LIM", 1742.80, TRAVEL),
            ("2026-07-08", "HOTEL MIRAMAR LIMA PE", 486.00, TRAVEL),
            ("2026-07-09", "CENTRAL RESTAURANTE LIMA PE", 412.00, DINING),
            ("2026-07-10", "MUSEO LARCO LIMA PE", 22.00, FUN),
            ("2026-07-11", "EL MERCADO HOTEL CUSCO PE", 624.00, TRAVEL),
            ("2026-07-12", "CHICHA POR GASTON ACURIO CUSCO PE", 96.40, DINING),
            ("2026-07-13", "ANDEAN RAIL OLLANTAYTAMBO PE", 168.00, TRAVEL),
            ("2026-07-17", "INKATERRA MACHU PICCHU PUEBLO PE", 538.00, TRAVEL),
            ("2026-07-18", "MERCADO SAN PEDRO CUSCO PE", 27.30, SHOPPING),
        ]),
        ("Hudson Valley weekend", "2026-08-21", "2026-08-23", [
            ("2026-08-21", "THE MILL HOUSE HOTEL BEACON NY", 688.00, TRAVEL),
            ("2026-08-22", "DIA BEACON MUSEUM BEACON NY", 40.00, FUN),
            ("2026-08-22", "LIL DEB'S OASIS HUDSON NY", 132.75, DINING),
            ("2026-08-23", "FISHKILL FARMS HOPEWELL JUNCTION NY", 46.10, GROCERIES),
        ]),
        ("Napa wedding", "2026-09-11", "2026-09-14", [
            ("2026-07-24", "ALASKA AIR 0272298114530 JFK-SFO", 842.60, TRAVEL),
            ("2026-09-11", "AVIS RENT A CAR SFO SAN FRANCISCO CA", 318.44, TRAVEL),
            ("2026-09-11", "ANDAZ NAPA NAPA CA", 1284.00, TRAVEL),
            ("2026-09-12", "OXBOW PUBLIC MARKET NAPA CA", 38.20, DINING),
            ("2026-09-13", "DOMAINE CARNEROS TASTING NAPA CA", 110.00, WINE),
            ("2026-09-13", "BOUCHON BAKERY YOUNTVILLE CA", 24.80, DINING),
            ("2026-09-14", "GOTTS ROADSIDE ST HELENA CA", 46.15, DINING),
        ]),
        ("Vermont weekend", "2026-10-09", "2026-10-12", [
            ("2026-10-09", "STOWE MOUNTAIN LODGE STOWE VT", 742.00, TRAVEL),
            ("2026-10-10", "BEN & JERRYS FACTORY WATERBURY VT", 17.50, DINING),
            ("2026-10-10", "ALCHEMIST BREWERY STOWE VT", 46.00, WINE),
            ("2026-10-11", "HEN OF THE WOOD WATERBURY VT", 164.20, DINING),
            ("2026-10-12", "COLD HOLLOW CIDER MILL WATERBURY VT", 38.75, GROCERIES),
        ]),
        # Could fairly be counted or not: not scored either way.
        ("?", None, None, [
            ("2026-02-06", "UNITED 0162291847731 UNITED.COM", 284.00, TRAVEL),
            ("2026-05-20", "FOREIGN TRANSACTION FEE", 18.44, FEES),
            ("2026-04-28", "FOREIGN TRANSACTION FEE", 41.20, FEES),
            ("2026-07-19", "FOREIGN TRANSACTION FEE", 22.86, FEES),
            ("2026-09-02", "ZOLA.COM WEDDING REGISTRY", 180.00, GIFTS),
            ("2026-10-09", "HERTZ RENT-A-CAR LGA NEW YORK NY", 284.60, TRAVEL),
            ("2026-08-21", "METRO-NORTH TICKETS NEW YORK NY", 39.00, CAR),
            ("2026-04-17", "UBER *TRIP HELP.UBER.COM", 78.20, CAR),
        ]),
    ],
)

BROOKLYN["places"] = {
    "Miami over New Year": (["MIAMI BEACH FL", "MIAMI FL", "HOMESTEAD FL"], False),
    "Chicago weekend": (["CHICAGO IL"], False),
    "Japan": (["TOKYO JP", "KYOTO JP", "KYOTO EKIMAE JP"], True),
    "Lisbon": (["LISBOA PT", "SINTRA PT"], True),
    "Peru": (["LIMA PE", "CUSCO PE", "OLLANTAYTAMBO PE", "PUEBLO PE"], True),
    "Hudson Valley weekend": (["BEACON NY", "HUDSON NY", "HOPEWELL JUNCTION NY"], False),
    "Napa wedding": (["NAPA CA", "YOUNTVILLE CA", "ST HELENA CA", "SAN FRANCISCO CA"], False),
    "Vermont weekend": (["STOWE VT", "WATERBURY VT"], False),
}

AUSTIN = dict(
    seed=29,
    everyday=[
        ("LADYBIRD COFFEE SOUTH CONGRESS AUSTIN TX", 4.5, 12.8, 0.38, DINING, "", True),
        ("H-E-B #455 AUSTIN TX", 41, 162, 0.24, GROCERIES, "", True),
        ("WHOLE FOODS LAMAR AUSTIN TX", 33, 141, 0.08, GROCERIES, "", True),
        ("TORCHYS TACOS AUSTIN TX", 13, 34, 0.11, DINING, "", True),
        ("P. TERRY'S #12 AUSTIN TX", 9, 22, 0.08, DINING, "", True),
        ("TST* SUERTE AUSTIN TX", 74, 188, 0.04, DINING, "", True),
        ("FAVOR DELIVERY AUSTIN TX", 22, 49, 0.06, DINING, "", True),
        ("CHEVRON 0204517 AUSTIN TX", 34, 71, 0.07, CAR, "", True),
        ("LYFT *RIDE", 9, 38, 0.05, CAR, "", True),
        ("AMAZON MKTPL*7H2PQ04", 11, 104, 0.13, SHOPPING, "", False),
        ("TARGET 00028811 AUSTIN TX", 19, 127, 0.05, SHOPPING, "", True),
        ("WALGREENS #7731 AUSTIN TX", 7, 44, 0.05, HEALTH, "", True),
        ("TOTAL WINE & MORE AUSTIN TX", 24, 92, 0.03, WINE, "", True),
        ("LOWES #01120 AUSTIN TX", 16, 110, 0.02, HOME, "", True),
        ("ALAMO DRAFTHOUSE SOUTH LAMAR AUSTIN TX", 26, 58, 0.03, FUN, "", True),
        # Bait: neighbourhood places named for somewhere far away.
        ("TST* ROMA PIZZERIA AUSTIN TX", 28, 71, 0.03, DINING, "!places named for elsewhere", True),
        ("NEW YORK BAGEL CO AUSTIN TX", 8, 21, 0.04, DINING, "!places named for elsewhere", True),
        # Bait: a drink at a hotel in one's own city is not a stay.
        ("HOTEL SAN JOSE COURTYARD BAR AUSTIN TX", 22, 64, 0.02, DINING, "!hotel bars at home", True),
        ("SOUTH CONGRESS HOTEL CAFE AUSTIN TX", 14, 46, 0.015, DINING, "!hotel bars at home", True),
    ],
    monthly=[
        (2, "HULU 877-8244858 CA", 17.99, SUBS), (6, "APPLE.COM/BILL", 9.99, SUBS), (9, "AUSTIN ENERGY UTILITIES", 188.42, BILLS),
        (13, "AT&T *BILL PAYMENT", 121.30, BILLS), (17, "STATE FARM INSURANCE", 164.00, BILLS),
        (22, "LIFE TIME FITNESS AUSTIN TX", 139.00, HEALTH), (26, "TEXAS GAS SERVICE", 38.66, BILLS),
    ],
    weekly_bait=[
        # Bait: a day at the San Antonio office, every Thursday of the year.
        (3, "ROADRUNNER TRAVEL CENTER NEW BRAUNFELS TX", 9, 31, CAR, "!weekly commute"),
        (3, "SQ *RIVERWALK OFFICE CAFE SAN ANTONIO TX", 10, 18, DINING, "!weekly commute"),
    ],
    once=[
        ("2025-11-29", "BEST BUY 00014522 AUSTIN TX", 849.99, SHOPPING, ""),
        ("2025-12-20", "KENDRA SCOTT AUSTIN TX", 128.00, SHOPPING, ""),
        ("2026-03-01", "AUSTIN VETERINARY CLINIC AUSTIN TX", 372.00, HEALTH, ""),
        ("2026-08-15", "WEST ELM 6011 AUSTIN TX", 1420.00, HOME, ""),
        ("2026-10-10", "ACL MUSIC FESTIVAL AUSTIN TX", 395.00, FUN, ""),
        # Bait: things ordered online from abroad while at home.
        ("2025-11-08", "ZARA.COM ARTEIXO ES", 139.80, SHOPPING, "!ordered from abroad"),
        ("2025-11-08", "FOREIGN TRANSACTION FEE", 4.19, FEES, "!ordered from abroad"),
        ("2026-02-25", "SP * TOKYO STATIONERY CO JP", 61.30, SHOPPING, "!ordered from abroad"),
        ("2026-05-02", "MARIMEKKO.COM HELSINKI FI", 212.00, SHOPPING, "!ordered from abroad"),
        ("2026-05-02", "FOREIGN TRANSACTION FEE", 6.36, FEES, "!ordered from abroad"),
    ],
    trips=[
        ("New Orleans weekend", "2025-12-12", "2025-12-14", [
            ("2025-12-12", "COMMANDERS PALACE NEW ORLEANS LA", 246.80, DINING),
            ("2025-12-13", "CAFE DU MONDE NEW ORLEANS LA", 16.40, DINING),
            ("2025-12-14", "HOTEL MONTELEONE NEW ORLEANS LA", 598.00, TRAVEL),
        ]),
        ("New York theater weekend", "2026-01-16", "2026-01-19", [
            ("2025-12-02", "BROADWAY BOX OFFICE SHUBERT THEATRE NEW YORK NY", 478.00, FUN),
            ("2025-12-02", "DELTA AIR 0062214977310 AUS-JFK", 692.40, TRAVEL),
            ("2026-01-16", "THE LUDLOW HOTEL NEW YORK NY", 1128.00, TRAVEL),
            ("2026-01-17", "RUSS & DAUGHTERS CAFE NEW YORK NY", 71.20, DINING),
            ("2026-01-17", "MOMA MUSEUM ADMISSIONS NEW YORK NY", 60.00, FUN),
            ("2026-01-18", "KATZS DELICATESSEN NEW YORK NY", 58.75, DINING),
            ("2026-01-18", "MTA*NYCT PAYGO NEW YORK NY", 11.60, CAR),
            ("2026-01-19", "JOES PIZZA BROADWAY NEW YORK NY", 14.00, DINING),
        ]),
        ("Colorado ski week", "2026-02-14", "2026-02-21", [
            ("2025-11-12", "VAIL RESORTS EPIC PASS LIFT TICKETS CO", 1196.00, FUN),
            ("2026-01-05", "SOUTHWEST AIR 5262239041187 AUS-DEN", 512.90, TRAVEL),
            ("2026-02-14", "THE ARRABELLE AT VAIL SQUARE VAIL CO", 3420.00, TRAVEL),
            ("2026-02-14", "SUMMIT SKI RENTAL VAIL CO", 388.00, FUN),
            ("2026-02-15", "MOUNTAIN STANDARD VAIL CO", 164.30, DINING),
            ("2026-02-16", "TWO ELK LODGE VAIL MOUNTAIN CO", 48.60, DINING),
            ("2026-02-18", "SWEET BASIL VAIL CO", 228.90, DINING),
            ("2026-02-19", "MOUNTAIN GROCER #416 VAIL CO", 92.14, GROCERIES),
            ("2026-02-21", "EPIC MOUNTAIN EXPRESS SHUTTLE DENVER CO", 196.00, TRAVEL),
        ]),
        ("Big Bend and Marfa", "2026-03-13", "2026-03-17", [
            ("2026-03-13", "HOTEL SAINT GEORGE MARFA TX", 562.00, TRAVEL),
            ("2026-03-14", "MARFA BURRITO MARFA TX", 18.00, DINING),
            ("2026-03-14", "CHINATI FOUNDATION MARFA TX", 50.00, FUN),
            ("2026-03-15", "BIG BEND NATL PARK ENTRANCE FEE TX", 30.00, FUN),
            ("2026-03-15", "CHISOS MOUNTAINS LODGE BIG BEND TX", 348.00, TRAVEL),
            ("2026-03-16", "STARLIGHT THEATRE TERLINGUA TX", 76.45, DINING),
            ("2026-03-17", "STRIPES #2231 ALPINE TX", 58.20, CAR),
        ]),
        ("Mexico City", "2026-04-09", "2026-04-13", [
            ("2026-02-20", "AEROMEXICO 1392281100457 AUS-MEX", 884.00, TRAVEL),
            ("2026-04-09", "HOTEL CONDESA DF CIUDAD DE MEX MX", 912.00, TRAVEL),
            ("2026-04-10", "PANADERIA ROSETTA CIUDAD DE MEX MX", 19.30, DINING),
            ("2026-04-10", "MUSEO FRIDA KAHLO COYOACAN MX", 31.00, FUN),
            ("2026-04-11", "CONTRAMAR CIUDAD DE MEX MX", 142.80, DINING),
            ("2026-04-12", "EL CARDENAL CENTRO CIUDAD DE MEX MX", 64.20, DINING),
            ("2026-04-12", "MERCADO DE ARTESANIAS LA CIUDADELA MX", 88.00, SHOPPING),
            ("2026-04-13", "PUJOL CIUDAD DE MEX MX", 396.00, DINING),
        ]),
        ("Disney World", "2026-06-06", "2026-06-12", [
            # Paid in Mexico City, for June: it belongs to Disney World.
            ("2026-04-11", "DISNEY RESORT RESERVATIONS ORLANDO FL", 2480.00, TRAVEL),
            ("2026-04-20", "SOUTHWEST AIR 5262241558902 AUS-MCO", 1104.20, TRAVEL),
            ("2026-06-06", "DISNEY POLYNESIAN VILLAGE LAKE BUENA VISTA FL", 1860.00, TRAVEL),
            ("2026-06-07", "WDW MAGIC KINGDOM TICKETS ORLANDO FL", 1312.00, FUN),
            ("2026-06-07", "COSMIC RAYS STARLIGHT CAFE LAKE BUENA VISTA FL", 74.30, DINING),
            ("2026-06-08", "WDW LIGHTNING LANE ORLANDO FL", 132.00, FUN),
            ("2026-06-09", "OHANA RESTAURANT LAKE BUENA VISTA FL", 286.40, DINING),
            ("2026-06-10", "WORLD OF DISNEY STORE LAKE BUENA VISTA FL", 164.85, SHOPPING),
            ("2026-06-11", "PUBLIX #1218 ORLANDO FL", 47.92, GROCERIES),
        ]),
        ("Italy", "2026-07-25", "2026-08-06", [
            ("2026-03-20", "ITA AIRWAYS 0552267711203 JFK-FCO", 3148.00, TRAVEL),
            ("2026-07-25", "HOTEL DE RUSSIE ROMA IT", 2240.00, TRAVEL),
            ("2026-07-26", "MUSEI VATICANI ROMA IT", 68.00, FUN),
            ("2026-07-26", "ROSCIOLI SALUMERIA ROMA IT", 148.60, DINING),
            ("2026-07-27", "GELATERIA DEL TEATRO ROMA IT", 12.00, DINING),
            ("2026-07-28", "ARMANDO AL PANTHEON ROMA IT", 121.00, DINING),
            ("2026-07-30", "TRENITALIA ROMA TERMINI IT", 98.00, TRAVEL),
            ("2026-07-30", "HOTEL LUNGARNO FIRENZE IT", 1980.00, TRAVEL),
            ("2026-07-31", "GALLERIA DEGLI UFFIZI FIRENZE IT", 58.00, FUN),
            ("2026-08-01", "TRATTORIA SOSTANZA FIRENZE IT", 134.50, DINING),
            ("2026-08-03", "SCUOLA DEL CUOIO FIRENZE IT", 310.00, SHOPPING),
            ("2026-08-05", "MERCATO CENTRALE FIRENZE IT", 42.70, DINING),
        ]),
        ("London", "2026-09-30", "2026-10-03", [
            ("2026-08-18", "BRITISH AIRWAYS 1252290033871 AUS-LHR", 1688.00, TRAVEL),
            ("2026-09-30", "THE HOXTON HOLBORN LONDON GB", 964.00, TRAVEL),
            ("2026-10-01", "DISHOOM COVENT GARDEN LONDON GB", 84.30, DINING),
            ("2026-10-01", "TFL TRAVEL CHARGE LONDON GB", 14.80, CAR),
            ("2026-10-02", "TATE MODERN LONDON GB", 26.00, FUN),
            ("2026-10-02", "ST JOHN RESTAURANT LONDON GB", 172.40, DINING),
            ("2026-10-03", "FORTNUM & MASON LONDON GB", 96.50, SHOPPING),
        ]),
        ("Wedding", None, None, [
            ("2026-02-02", "BARR MANSION WEDDING VENUE DEPOSIT AUSTIN TX", 4500.00, FUN),
            ("2026-03-05", "MINTED.COM WEDDING INVITATIONS", 486.20, SHOPPING),
            ("2026-03-28", "DAVIDS BRIDAL #118 AUSTIN TX", 1340.00, SHOPPING),
            ("2026-04-22", "PETAL PUSHERS WEDDING FLORIST AUSTIN TX", 2150.00, FUN),
            ("2026-05-08", "ROYAL FIG WEDDING CATERING AUSTIN TX", 7860.00, DINING),
            ("2026-05-15", "MENS WEARHOUSE TUX RENTAL AUSTIN TX", 219.99, SHOPPING),
            ("2026-05-20", "BARR MANSION WEDDING VENUE BALANCE AUSTIN TX", 6200.00, FUN),
            ("2026-05-23", "SOUTH AUSTIN WEDDING BAND DJ", 1800.00, FUN),
            ("2026-05-23", "CAPTURED WEDDING PHOTOGRAPHY AUSTIN TX", 3400.00, FUN),
        ]),
        # Could fairly be counted or not: not scored either way.
        ("?", None, None, [
            ("2026-04-13", "FOREIGN TRANSACTION FEE", 46.11, FEES),
            ("2026-08-06", "FOREIGN TRANSACTION FEE", 160.82, FEES),
            ("2026-10-03", "FOREIGN TRANSACTION FEE", 41.39, FEES),
            ("2025-12-12", "SOUTHWEST AIR 5262230998812", 318.60, TRAVEL),
            ("2026-03-13", "LYFT *RIDE", 44.10, CAR),
            ("2026-06-06", "ABIA PARKING AUSTIN TX", 96.00, CAR),
            ("2026-07-25", "ABIA PARKING AUSTIN TX", 182.00, CAR),
            ("2026-05-30", "MARRIOTT AUSTIN DOWNTOWN AUSTIN TX", 289.00, TRAVEL),
        ]),
    ],
)


AUSTIN["places"] = {
    "New Orleans weekend": (["NEW ORLEANS LA"], False),
    "New York theater weekend": (["NEW YORK NY"], False),
    "Colorado ski week": (["VAIL CO", "VAIL MOUNTAIN CO", "DENVER CO"], False),
    "Big Bend and Marfa": (["MARFA TX", "BIG BEND TX", "TERLINGUA TX", "ALPINE TX"], False),
    "Mexico City": (["CIUDAD DE MEX MX", "COYOACAN MX", "MX"], True),
    "Disney World": (["LAKE BUENA VISTA FL", "ORLANDO FL"], False),
    "Italy": (["ROMA IT", "FIRENZE IT", "ROMA TERMINI IT"], True),
    "London": (["LONDON GB"], True),
}

# Pairs of statement lines that are plainly one business written two ways, or plainly two businesses
# that share a word. Made up, in the style of real statements.
SAME = [
    ("BUON ITALIA NEW YORK NY", "BUON'ITALIA CHELSEA MKT NY"), ("TST* JOES PIZZA BROADWAY", "JOE'S PIZZA BROADWAY NEW YORK NY"),
    ("CHOPT CREATIVE SALAD 14 ST NY", "CHOPT #23 NEW YORK NY"), ("SQ *BLUE BOTTLE COFFEE", "BLUE BOTTLE COFFEE BROOKLYN NY"),
    ("WHOLEFDS PSL 10234 BROOKLYN NY", "WHOLE FOODS MARKET LAMAR AUSTIN TX"), ("AMZN MKTP US*2K4RT81", "AMAZON MKTPL*7H2PQ04"),
    ("DELTA AIR 0062214977310", "DELTA AIR LINES ATLANTA GA"), ("CVS/PHARMACY #02184 BROOKLYN NY", "CVS PHARMACY 9912 AUSTIN TX"),
    ("TRADER JOE S #552 BROOKLYN NY", "TRADER JOE'S 0721 AUSTIN TX"), ("NYTIMES*NYTIMES", "NEW YORK TIMES DIGITAL 800-698-4637 NY"),
    ("STARBUCKS STORE 0412 NEW YORK NY", "STARBUCKS #08812 SEATTLE WA"), ("UBER *TRIP HELP.UBER.COM", "UBER TRIP SAN FRANCISCO CA"),
    ("SHELL OIL 57442 BROOKLYN NY", "SHELL SERVICE STATION AUSTIN TX"), ("HOME DEPOT #1225 BROOKLYN NY", "THE HOME DEPOT 6512 AUSTIN TX"),
    ("PLANET FITNESS CLUB FEE", "PLANET FIT *MONTHLY DUES NH"), ("APLPAY SWEETGREEN PARK SLOPE", "SWEETGREEN UNION SQ NEW YORK NY"),
    ("TST* TORCHYS TACOS - SOUTH LAMAR", "TORCHYS TACOS AUSTIN TX"), ("LYFT *RIDE SUN 9PM", "LYFT *2 RIDES 11-04"),
    ("SPOTIFY USA", "SPOTIFY P2A1B3C4D5 NEW YORK NY"), ("H-E-B #455 AUSTIN TX", "HEB ONLINE #108 SAN ANTONIO TX"),
    ("NETFLIX.COM", "PAYPAL *NETFLIX.COM"), ("CON EDISON OF NY", "CONED BILL PAYMENT 800-752-6633"),
    ("VERIZON WIRELESS", "VZWRLSS*APOCC VISB"), ("WALGREENS #7731 AUSTIN TX", "WALGREENS.COM 800-925-4733 IL"),
    ("TARGET 00012345 BROOKLYN NY", "TARGET.COM * 800-591-3869 MN"), ("CHEWY.COM 800-672-4399 FL", "CHEWY INC DANIA BEACH FL"),
    ("ALAMO DRAFTHOUSE SOUTH LAMAR AUSTIN TX", "ALAMO DRAFTHOUSE CINEMA MUELLER AUSTIN"), ("GEICO *AUTO", "GEICO INSURANCE 800-841-3000 DC"),
    ("P. TERRY'S #12 AUSTIN TX", "P TERRYS BURGER STAND 7 AUSTIN TX"), ("LADYBIRD COFFEE SOUTH CONGRESS AUSTIN TX", "SQ *LADYBIRD COFFEE DOWNTOWN AUSTIN"),
]
DIFFERENT = [
    ("WESTSIDE MARKET NYC 77TH NEW YORK NY", "TST* WESTSIDE TAVERN NEW YORK NY"), ("PARAMOUNT+ 888-274-5343 CA", "PARAMOUNT HOTEL NEW YORK NY"),
    ("DELTA AIR LINES ATLANTA GA", "DELTA FAUCET PARTS INDIANAPOLIS IN"), ("APPLE STORE #R095 NEW YORK NY", "APPLEBEES GRILL 4412 AUSTIN TX"),
    ("SHELL OIL 57442 BROOKLYN NY", "SHELLS SEAFOOD SHACK MIAMI FL"), ("UNITED 0162291847731 UNITED.COM", "UNITED HEALTHCARE PREMIUM MN"),
    ("STEAM GAMES STEAMPOWERED.COM WA", "STEAM ROOM SAUNA & SPA DENVER CO"), ("SPECTRUM 855-707-7328 MO", "SPECTRUM DANCE STUDIO BROOKLYN NY"),
    ("SOUTHWEST AIR 5262239041187", "SQ *SOUTHWEST DINER SANTA FE NM"), ("VAIL RESORTS EPIC PASS CO", "VAIL VALLEY PHARMACY EDWARDS CO"),
    ("SQ *PRINCETON SOUP CO PRINCETON NJ", "PRINCETON UNIVERSITY STORE NJ"), ("COLUMBIA SPORTSWEAR #441 OR", "COLUMBIA UNIVERSITY BURSAR NY"),
    ("LIBERTY LONDON GB", "LIBERTY MUTUAL INSURANCE MA"), ("BLUE BOTTLE COFFEE BROOKLYN NY", "BLUE APRON MEAL KITS NY"),
    ("OLIVE GARDEN #1182 AUSTIN TX", "TST* OLIVE & FIG BROOKLYN NY"), ("SQ *NIGHT OWL RAMEN BROOKLYN NY", "NIGHT OWL SECURITY CAMERAS FL"),
    ("AMAZON MKTPL*2K4RT81", "AMAZONIA BRAZILIAN GRILL ORLANDO FL"), ("CHASE CAR WASH AUSTIN TX", "CHASE FIELD CONCESSIONS PHOENIX AZ"),
    ("PELOTON MEMBERSHIP NY", "PELOTON CYCLES BIKE SHOP BOULDER CO"), ("HILTON GARDEN INN AUSTIN TX", "HILTON HEAD ISLAND TOLL SC"),
    ("BEST BUY 00014522 AUSTIN TX", "BEST WESTERN PLUS MARFA TX"), ("JOES PIZZA BROADWAY NEW YORK NY", "JOES CRAB SHACK GALVESTON TX"),
    ("MARFA BURRITO MARFA TX", "MARFA PUBLIC RADIO DONATION TX"), ("BROOKLYN WINE EXCHANGE BROOKLYN NY", "BROOKLYN BOWL TICKETS NY"),
    ("AUSTIN ENERGY UTILITIES", "AUSTIN VETERINARY CLINIC AUSTIN TX"), ("LITTLE TOKYO SUSHI BROOKLYN NY", "LITTLE HAVANA CAFE BROOKLYN NY"),
    ("HEN OF THE WOOD WATERBURY VT", "HENS TOOTH TOY STORE WATERBURY VT"), ("STATE FARM INSURANCE", "STATE PARKS RESERVATIONS TX"),
    ("COSTCO WHSE #1171 AUSTIN TX", "COSTA COFFEE LONDON GB"), ("TOTAL WINE & MORE AUSTIN TX", "TOTAL GYM FITNESS DIRECT"),
]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rng = random.Random(3)
    with open(OUT / "pairs.tsv", "w") as f:
        f.write("answer\tline_a\tseen_a\ttypical_a\tline_b\tseen_b\ttypical_b\n")
        for answer, pairs in (("same", SAME), ("different", DIFFERENT)):
            for a, b in pairs:
                f.write(f"{answer}\t{a}\t{rng.randint(2, 40)}\t{rng.uniform(8, 140):.2f}\t{b}\t{rng.randint(1, 12)}\t{rng.uniform(8, 140):.2f}\n")
    print(f"pairs: {len(SAME)} the same business, {len(DIFFERENT)} different")
    for name, spec in (("trips-brooklyn", BROOKLYN), ("trips-austin", AUSTIN)):
        rows = household(**spec)
        with open(OUT / f"{name}.tsv", "w") as f:
            f.write("date\ttext\tamount\tcategory\tanswer\n")
            for day, text, amount, category, answer in rows:
                f.write(f"{day.isoformat()}\t{text}\t{amount:.2f}\t{category}\t{answer}\n")
        planted = sorted({r[4] for r in rows if r[4] and r[4] != "?" and not r[4].startswith("!")})
        print(f"{name}: {len(rows)} charges, {len(planted)} trips and events planted")


if __name__ == "__main__":
    main()
