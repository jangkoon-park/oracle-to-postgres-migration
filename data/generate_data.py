#!/usr/bin/env python3
"""Generate deterministic, 100% fictional data for the BuildCo ERP contract module.

Every name (sites, clients, vendors, managers) is assembled at random from small
word lists; nothing comes from a real company. The same CSV files are meant to be
loaded into Oracle (SQL*Loader, see oracle/03_load/) and into the simulated
Oracle source schema in PostgreSQL (simulation/02_load_source.sql).

CSV conventions (match what SQL*Loader / Oracle would hold):
  * header row, comma separated, UTF-8
  * NULL = empty unquoted field (Oracle stores '' as NULL anyway)
  * DATE = 'YYYY-MM-DD HH24:MI:SS' (Oracle DATE always carries a time part)

Usage: python3 data/generate_data.py [--out data/csv] [--seed 20261012]
"""
import argparse
import csv
import datetime as dt
import os
import random

# --- volume knobs (total stays well below the 100,000 row limit) -------------
N_SITES = 60
CONTRACTS_PER_SITE = (20, 60)      # min/max contracts for an active/closed site
LINES_PER_CONTRACT = (5, 25)
POS_PER_CONTRACT = (3, 10)
SPOT_POS_PER_SITE = (10, 40)       # purchase orders without a contract
SEQ_CACHE_GAP = 20                 # simulate Oracle sequence CACHE gaps

# --- fictional word lists -----------------------------------------------------
PLACE_WORDS = ["Gaon", "Dasol", "Nuri", "Byeol", "Arin", "Haram", "Saebit", "Yeoul",
               "Seorim", "Hanul", "Morae", "Bada", "Sanmaru", "Gureum", "Narae", "Iroum"]
PROJECT_TYPES = ["Apartment Complex", "Logistics Center", "Office Tower",
                 "Bridge Rehabilitation", "Water Treatment Plant", "Elementary School",
                 "Community Center", "Data Center", "Distribution Warehouse",
                 "Road Widening", "Riverside Park", "Hospital Annex"]
REGIONS = ["Seoul", "Gyeonggi", "Incheon", "Busan", "Daegu", "Daejeon", "Gwangju",
           "Ulsan", "Sejong", "Gangwon", "Chungbuk", "Jeonnam"]
CLIENT_SUFFIX = ["Development", "Housing Trust", "Logistics Holdings", "Urban Partners",
                 "Infra Fund", "Public Works Office"]
VENDOR_WORDS = ["Doore", "Sora", "Tamra", "Uri", "Bitna", "Onnuri", "Hanaro", "Maru",
                "Sarang", "Jinju", "Pureun", "Saemaeul", "Dongbaek", "Solbit", "Garam",
                "Hwarang", "Nadeul", "Yeon", "Chorok", "Mirae"]
SURNAMES = ["Kim", "Lee", "Park", "Choi", "Jung", "Kang", "Cho", "Yoon", "Jang", "Lim"]

# cost code -> (trade label for vendor names, contract type, items)
# item = (item_code, item_name, spec or None, unit, unit price range KRW)
COST_CODES = {
    "C01-EARTH":  ("Earthworks", "SUB", [("EW-EXC", "Excavation 터파기", "Soil, backhoe 1.0m3", "m3", (9000, 15000)),
                                         ("EW-BKF", "Backfill 되메우기", None, "m3", (6000, 11000))]),
    "C02-CONC":   ("Concrete", "MAT", [("RMC-25-24", "Ready-mix concrete 레미콘", "25-24-150", "m3", (82000, 96000)),
                                       ("RMC-25-30", "Ready-mix concrete 레미콘", "25-30-150", "m3", (90000, 105000))]),
    "C03-REBAR":  ("Rebar", "MAT", [("RB-SD400-D13", "Deformed rebar 이형철근", "SD400 D13", "ton", (880000, 990000)),
                                    ("RB-SD500-D22", "Deformed rebar 이형철근", "SD500 D22", "ton", (900000, 1020000))]),
    "C04-FORM":   ("Formwork", "SUB", [("FW-EURO", "Euro form 유로폼", None, "m2", (21000, 33000)),
                                       ("FW-ALU", "Aluminium form 알폼", "AL 6061", "m2", (26000, 39000))]),
    "C05-STEEL":  ("Steel Structure", "SUB", [("SS-H300", "H-beam erection 철골 설치", "H-300x300", "ton", (1500000, 2100000))]),
    "C06-MASON":  ("Masonry", "SUB", [("MS-BLK", "Concrete block 블록 쌓기", "190x390x150", "m2", (28000, 41000))]),
    "C07-WATERPR": ("Waterproofing", "SUB", [("WP-URE", "Urethane waterproofing 우레탄 방수", None, "m2", (17000, 26000))]),
    "C08-MEP-E":  ("Electrical", "SUB", [("EL-CBL", "Power cable 전력 케이블", "F-CV 6sq", "m", (2500, 4800)),
                                         ("EL-PNL", "Distribution panel 분전반", None, "set", (650000, 1400000))]),
    "C09-MEP-M":  ("Mechanical", "SUB", [("ME-DCT", "Galvanized duct 아연도 덕트", "0.5t", "m2", (31000, 47000)),
                                         ("ME-PMP", "Booster pump 부스터 펌프", "15kW", "ea", (3800000, 6200000))]),
    "C10-FINISH": ("Interior Finishing", "SUB", [("FN-TIL", "Porcelain tile 자기질 타일", "600x600", "m2", (36000, 58000)),
                                                 ("FN-PNT", "Interior paint 수성페인트", None, "m2", (7000, 12000))]),
    "C11-TEMP":   ("Temporary Works", "SVC", [("TW-FEN", "Site fence 가설 펜스", "EGI H=3m", "m", (42000, 61000)),
                                              ("TW-SEC", "Site security service 경비 용역", None, "month", (3200000, 4500000))]),
    "C12-EQUIP":  ("Equipment Rental", "EQP", [("EQ-TC", "Tower crane rental 타워크레인 임대", "T-150", "month", (17000000, 26000000)),
                                               ("EQ-EXC", "Excavator rental 굴삭기 임대", "0.8m3", "day", (650000, 900000))]),
}
REMARK_POOL = ["Price escalation clause applies", "Includes transport to site",
               "Night work allowed", "Retention released on completion",
               "Revised per design change #", "Payment terms 30 days"]

FMT = "%Y-%m-%d %H:%M:%S"


def d(day: dt.date) -> str:
    """Business date: Oracle DATE with a midnight time part."""
    return dt.datetime.combine(day, dt.time()).strftime(FMT)


def ts(rng: random.Random, day: dt.date) -> str:
    """Audit timestamp: Oracle DATE with a time part (SYSDATE at insert)."""
    t = dt.time(rng.randint(7, 19), rng.randint(0, 59), rng.randint(0, 59))
    return dt.datetime.combine(day, t).strftime(FMT)


def rand_day(rng, start: dt.date, end: dt.date) -> dt.date:
    return start + dt.timedelta(days=rng.randint(0, max((end - start).days, 0)))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "csv"))
    ap.add_argument("--seed", type=int, default=20261012)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    os.makedirs(args.out, exist_ok=True)

    vendors = {cc: sorted({f"{rng.choice(VENDOR_WORDS)} {trade} Co., Ltd." for _ in range(8)})
               for cc, (trade, _, _) in COST_CODES.items()}

    sites, contracts, lines, pos, budgets = [], [], [], [], []
    contract_id = po_id = budget_id = 0

    for site_id in range(1, N_SITES + 1):
        start = rand_day(rng, dt.date(2021, 1, 1), dt.date(2025, 6, 30))
        status = rng.choices(["A", "C", "P"], weights=[6, 3, 1])[0]
        if status == "P":
            start = rand_day(rng, dt.date(2026, 11, 1), dt.date(2027, 6, 30))
        duration = dt.timedelta(days=rng.randint(400, 1100))
        end = start + duration if status != "A" or rng.random() < 0.7 else None
        place = rng.choice(PLACE_WORDS)
        sites.append({
            "site_id": site_id,
            "site_code": f"ST-{start.year % 100:02d}-{site_id:04d}",
            "site_name": f"{place} {rng.choice(PROJECT_TYPES)} Phase {rng.randint(1, 3)}",
            "region": rng.choice(REGIONS),
            "client_name": None if rng.random() < 0.1 else f"{rng.choice(PLACE_WORDS)} {rng.choice(CLIENT_SUFFIX)}",
            "start_date": d(start),
            "end_date": d(end) if end else None,
            "status": status,
            "manager_name": f"{rng.choice(SURNAMES)} {rng.choice('BDHJMSY')}.{rng.choice('ACHKSW')}.",
            "created_at": ts(rng, start - dt.timedelta(days=rng.randint(10, 60))),
        })

        # ---- budget: one row per fiscal year x cost code ------------------
        years = range(start.year, (end or dt.date(2026, 12, 31)).year + 1)
        for fy in years:
            for cc in COST_CODES:
                if rng.random() < 0.15:          # not every cost code every year
                    continue
                budget_id += 1
                amt = round(rng.uniform(80, 2500), 0) * 1_000_000
                budgets.append({
                    "budget_id": budget_id, "site_id": site_id, "fiscal_year": fy,
                    "cost_code": cc, "budget_amount": f"{amt:.2f}",
                    "revised_amount": f"{amt * rng.choice([0.9, 1.05, 1.1, 1.2]):.2f}" if rng.random() < 0.3 else None,
                    "approved_yn": "Y" if rng.random() < 0.8 else "N",
                    "created_at": ts(rng, dt.date(fy, 1, 1) - dt.timedelta(days=rng.randint(5, 40))),
                })

        if status == "P":                        # planned site: budget only, no contracts / POs
            continue

        site_end = end or dt.date(2026, 9, 30)
        for _ in range(rng.randint(*CONTRACTS_PER_SITE)):
            contract_id += 1
            cc = rng.choice(list(COST_CODES))
            trade, ctype, items = COST_CODES[cc]
            vendor = rng.choice(vendors[cc])
            cdate = rand_day(rng, start, min(site_end, dt.date(2026, 9, 30)))
            cstatus = rng.choices(["DRAFT", "APPROVED", "CLOSED", "CANCELLED"], weights=[1, 6, 3, 1])[0]
            n_lines = 0 if (cstatus == "DRAFT" and rng.random() < 0.2) else rng.randint(*LINES_PER_CONTRACT)
            total = 0
            for line_no in range(1, n_lines + 1):
                code, name, spec, unit, (lo, hi) = rng.choice(items)
                qty = round(rng.uniform(1, 400), 3) if unit not in ("month", "set", "ea") else rng.randint(1, 12)
                price = round(rng.uniform(lo, hi), -1)
                amount = round(qty * price)      # KRW, no decimals
                total += amount
                lines.append({
                    "contract_id": contract_id, "line_no": line_no, "item_code": code,
                    "item_name": name, "spec": spec, "unit": unit,
                    "quantity": f"{qty:.3f}", "unit_price": f"{price:.2f}",
                    "amount": f"{amount:.2f}", "cost_code": cc,
                })
            contracts.append({
                "contract_id": contract_id,
                "contract_no": f"CT-{cdate.year}-{contract_id:06d}",
                "site_id": site_id, "vendor_name": vendor, "contract_type": ctype,
                "contract_date": d(cdate),
                "start_date": d(cdate + dt.timedelta(days=rng.randint(0, 30))) if rng.random() < 0.95 else None,
                "end_date": d(cdate + dt.timedelta(days=rng.randint(60, 540))) if rng.random() < 0.85 else None,
                "currency": "KRW",
                "total_amount": f"{total:.2f}", "vat_amount": f"{round(total * 0.1):.2f}",
                "status": cstatus,
                "retention_rate": rng.choice(["5.00", "3.00", "10.00", None]),
                "remarks": rng.choice(REMARK_POOL) if rng.random() < 0.35 else None,
                "created_at": ts(rng, cdate),
                "updated_at": ts(rng, cdate + dt.timedelta(days=rng.randint(1, 90))) if rng.random() < 0.6 else None,
            })
            if cstatus == "DRAFT" or total == 0:
                continue
            for _ in range(rng.randint(*POS_PER_CONTRACT)):
                po_id += 1
                pdate = cdate + dt.timedelta(days=rng.randint(0, 400))
                pos.append(make_po(rng, po_id, site_id, contract_id, vendor, pdate, cc,
                                   round(total * rng.uniform(0.02, 0.25)), cstatus == "CANCELLED"))

        for _ in range(rng.randint(*SPOT_POS_PER_SITE)):   # spot purchases (no contract)
            po_id += 1
            cc = rng.choice(list(COST_CODES))
            pdate = rand_day(rng, start, site_end)
            pos.append(make_po(rng, po_id, site_id, None, rng.choice(vendors[cc]), pdate, cc,
                               round(rng.uniform(0.3, 40), 1) * 1_000_000, False))

    write(args.out, "site.csv", sites)
    write(args.out, "budget.csv", budgets)
    write(args.out, "contract_hdr.csv", contracts)
    write(args.out, "contract_dtl.csv", lines)
    write(args.out, "purchase_order.csv", pos)
    # Oracle sequence state (USER_SEQUENCES.LAST_NUMBER) incl. CACHE gaps
    write(args.out, "user_sequences.csv", [
        {"sequence_name": "SITE_SEQ", "last_number": N_SITES + 1},
        {"sequence_name": "CONTRACT_SEQ", "last_number": contract_id + SEQ_CACHE_GAP},
        {"sequence_name": "PO_SEQ", "last_number": po_id + SEQ_CACHE_GAP},
        {"sequence_name": "BUDGET_SEQ", "last_number": budget_id + SEQ_CACHE_GAP},
    ])
    total = len(sites) + len(budgets) + len(contracts) + len(lines) + len(pos)
    print(f"site={len(sites)} budget={len(budgets)} contract_hdr={len(contracts)} "
          f"contract_dtl={len(lines)} purchase_order={len(pos)} total={total}")
    assert total <= 100_000, "row budget exceeded"


def make_po(rng, po_id, site_id, contract_id, vendor, pdate, cc, amount, cancelled):
    status = "CANCELLED" if cancelled and rng.random() < 0.7 else \
        rng.choices(["ISSUED", "RECEIVED", "CANCELLED"], weights=[3, 6, 1])[0]
    return {
        "po_id": po_id, "po_no": f"PO-{pdate.year}-{po_id:07d}", "site_id": site_id,
        "contract_id": contract_id, "vendor_name": vendor, "po_date": d(pdate),
        "delivery_date": d(pdate + dt.timedelta(days=rng.randint(3, 45))) if rng.random() < 0.9 else None,
        "cost_code": cc, "po_amount": f"{amount:.2f}", "status": status,
        "urgent_yn": "Y" if rng.random() < 0.1 else "N",
        "remarks": rng.choice(REMARK_POOL) if rng.random() < 0.2 else None,
        "created_at": ts(rng, pdate),
    }


def write(out_dir, name, rows):
    with open(os.path.join(out_dir, name), "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)


if __name__ == "__main__":
    main()
