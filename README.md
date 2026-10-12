# Oracle → PostgreSQL migration demo: construction ERP contracts

This project moves the contract module of a **fictional** construction-company ERP from Oracle to
PostgreSQL. It covers the schema, data types, sequences, and PL/SQL business logic, and it
reconciles row counts and money totals site by site to show that nothing was lost or changed.

* 5 tables: sites, contract headers, contract lines, purchase orders, budgets. 46,266 rows in total.
* 1 PL/SQL package with 8 functions and procedures (total calculation, status workflow, budget usage,
  top-N), converted to PL/pgSQL.
* 28 reconciliation checks, 9 procedure behaviour tests, and a negative test that injects defects
  to prove the checks catch them.
* Result: **28/28 checks PASS, 9/9 tests PASS, 60/60 sites match on every amount.** See
  [`results/validation_report.md`](results/validation_report.md).

> **All data is synthetic.** Every site, client, vendor, and manager name comes from random word
> lists in `data/generate_data.py`. No real company data was used.

---

## Honest notes: what was and wasn't executed

| Component | Status |
|---|---|
| Oracle DDL, PL/SQL package, SQL*Loader files, source check queries (`oracle/`) | **Written, not executed.** No Oracle instance was available. I tried Oracle Free in Docker, but both registries were blocked from the build sandbox (Docker Hub `429`, GHCR blob `403`). |
| Oracle source database | **Simulated** in PostgreSQL 16.15 as schema `ora_src`, with types that keep Oracle's behaviour (`DATE` → `timestamp(0)`, `NUMBER` → `numeric`, `CHECK (col <> '')` to imitate Oracle's "empty string is NULL" rule). |
| PostgreSQL target, converted PL/pgSQL, migration, validation | **Executed** on PostgreSQL 16.15 (local, Ubuntu 24.04). |
| SQLite fallback | Not needed, because PostgreSQL was available. |

Because the source is simulated, this repo proves that the **PostgreSQL side** is correct: the
types, the conversion SQL, the PL/pgSQL, and the reconciliation method. It does **not** prove that
the Oracle scripts compile on a real Oracle server. The simulation has the same shape that
`oracle_fdw`'s `IMPORT FOREIGN SCHEMA` produces, so in a real project the same migration and
validation scripts run unchanged against live Oracle through
[`migration/oracle_fdw_setup.sql`](migration/oracle_fdw_setup.sql).

**Run budget:** the brief allowed at most 3 runs of the same experiment. The end-to-end pipeline ran
**3 times** in total:
1. Aborted in the validation step. A PL/pgSQL OUT column named `status` clashed with a table column.
   Fixed with `#variable_conflict use_column`.
2. 28/28 checks passed. 1 procedure test failed because of a bug in the **test's** expected string
   (`195380338` vs `195380338.00`), not in the migrated code. The expected value was fixed.
3. Clean run: everything passed. The committed `results/` folder is from this run.

---

## Scenario and data model

```
SITE (60) ──< CONTRACT_HDR (2,008) ──< CONTRACT_DTL (29,269)
   │                 │
   │                 └──< PURCHASE_ORDER (13,115)   (contract_id NULL = spot purchase)
   └──< BUDGET (1,814)   (site × fiscal year × cost code)
```

| Table | Korean | Rows | Notes |
|---|---|---:|---|
| `site` | 현장 | 60 | Planned sites have a budget only, with no contracts or POs |
| `contract_hdr` | 계약 헤더 | 2,008 | `total_amount` = sum of the lines, VAT 10%, status workflow |
| `contract_dtl` | 계약 상세 내역 | 29,269 | Item names mix Korean and English (UTF-8), so `VARCHAR2 BYTE/CHAR` semantics matter |
| `purchase_order` | 발주 | 13,115 | `urgent_yn CHAR(1)` → `boolean` |
| `budget` | 예산 | 1,814 | `revised_amount` is NULL when the budget was never revised |
| **Total** | | **46,266** | Below the 100,000-row limit |

The generator includes the Oracle quirks a real extract has: about 20k NULLs in optional text
columns, `DATE` values with a time part on audit columns and midnight on business dates, Y/N flags,
and sequence `CACHE` gaps (`LAST_NUMBER` > `max(id)`).

---

## Repository layout

```
oracle/                      SOURCE (Oracle syntax, provided as files)
  01_schema.sql              tables, sequences, legacy BEFORE INSERT ID triggers
  02_pkg_contract.sql        PL/SQL package PKG_CONTRACT (spec + body)
  03_load/*.ctl              SQL*Loader control files for the CSV extract
  04_source_checks.sql       row counts / per-site sums / profiling on Oracle
data/generate_data.py        deterministic fictional data generator → data/csv/*.csv
simulation/                  Oracle source simulated in PostgreSQL (schema ora_src)
postgres/
  01_schema.sql              TARGET schema erp (converted DDL)
  02_pkg_contract.sql        converted PL/pgSQL (schema pkg_contract)
migration/
  01_precheck.sql            data profiling that blocks lossy conversions
  02_migrate.sql             transactional, re-runnable load + identity restart
  oracle_fdw_setup.sql       real-Oracle path (replaces simulation/)
validation/
  01_checks.sql              mig_check.run_all(): 28 reconciliation checks
  02_test_procedures.sql     behaviour tests for converted procedures (rolled back)
  03_negative_test.sql       injects 3 defects, shows the checks fail (rolled back)
  report.py                  CSV → results/validation_report.md
docs/conversion-notes.md     NVL, DECODE, ROWNUM, '' vs NULL, dates, PL/SQL traps
results/                     output of the last run (committed)
run_demo.sh                  one command, end to end
TASK.md                      original task brief
```

---

## Migration procedure

| # | Step | Script | What it does |
|---|---|---|---|
| 1 | Extract | `data/generate_data.py`, `oracle/03_load/*.ctl` | CSV extract (here: generated). NULLs are kept as empty unquoted fields. Dates use `YYYY-MM-DD HH24:MI:SS`. |
| 2 | Source | `simulation/*.sql` (or `migration/oracle_fdw_setup.sql`) | Exposes the Oracle tables to PostgreSQL as schema `ora_src` |
| 3 | Target DDL | `postgres/01_schema.sql` | Converted tables, constraints, indexes, identity columns |
| 4 | Code | `postgres/02_pkg_contract.sql` | PL/SQL package → schema `pkg_contract` with PL/pgSQL functions and procedures |
| 5 | Pre-check | `migration/01_precheck.sql` | 11 profiling checks: time part in "date" columns, non-Y/N flags, length overflow, orphan FKs, whitespace-only strings. Any hit aborts the run. |
| 6 | Load | `migration/02_migrate.sql` | One transaction. Parent → child order with FKs enabled. Explicit casts. Y/N → boolean. Original keys are kept. Each identity column restarts at `GREATEST(max(id)+1, USER_SEQUENCES.LAST_NUMBER)`. Then `ANALYZE`. Can be re-run. |
| 7 | Reconcile | `validation/01_checks.sql` | Counts, per-site totals, full-row `EXCEPT ALL` diff, NULL/'' semantics, identity, function parity |
| 8 | Behaviour | `validation/02_test_procedures.sql` | Calls the converted procedures, then rolls back |
| 9 | Prove the checks | `validation/03_negative_test.sql` | Corrupts the target on purpose and confirms the checks turn red |
| 10 | Report | `validation/report.py` | `results/validation_report.md` |

The migrate step for 46k rows took **0.82 s** (wall clock, including psql start-up and `ANALYZE`).

---

## Data type mapping

| Oracle (source) | PostgreSQL (target) | Columns in this schema | Reason |
|---|---|---|---|
| `NUMBER(10)`, `NUMBER(12)` keys | `bigint` | `site_id`, `contract_id`, `po_id`, `budget_id` | `NUMBER(10)` can exceed int4 (2,147,483,647) |
| `NUMBER(5)` | `integer` | `line_no` | max 99,999 doesn't fit `smallint` |
| `NUMBER(4)` | `smallint` | `fiscal_year` | |
| `NUMBER(18,2)`, `NUMBER(15,2)` | `numeric(18,2)`, `numeric(15,2)` | all amounts, `unit_price` | exact decimal, never float for money |
| `NUMBER(15,3)`, `NUMBER(5,2)` | `numeric(15,3)`, `numeric(5,2)` | `quantity`, `retention_rate` | |
| `VARCHAR2(n)` / `VARCHAR2(n CHAR)` | `varchar(n)` | names, codes | PostgreSQL counts characters; BYTE columns gain capacity (safe direction) |
| `VARCHAR2(4000 CHAR)` | `text` + `CHECK (char_length <= 4000)` | `contract_hdr.remarks` | |
| `CHAR(1)` status code | `varchar(1)` + CHECK | `site.status` | avoids `char(n)` blank-padding rules |
| `CHAR(1)` `'Y'/'N'` | `boolean` (renamed `is_*`) | `urgent_yn` → `is_urgent`, `approved_yn` → `is_approved` | pre-check proves Y/N only |
| `CHAR(3)` | `char(3)` | `currency` | fixed-length ISO code |
| `DATE` (business date) | `date` | `start_date`, `end_date`, `contract_date`, `po_date`, `delivery_date` | only after the pre-check proves time = 00:00:00 |
| `DATE` (audit) | `timestamp(0)` | `created_at`, `updated_at` | Oracle DATE has seconds; `(0)` keeps the precision the same |
| `DEFAULT SYSDATE` | `DEFAULT LOCALTIMESTAMP(0)` | audit columns | |
| `SEQUENCE` + `BEFORE INSERT` trigger | `GENERATED BY DEFAULT AS IDENTITY` | 4 tables | BY DEFAULT so the original keys can be loaded |

## PL/SQL → PL/pgSQL objects

| Oracle (`PKG_CONTRACT`) | PostgreSQL (`pkg_contract.*`) | Conversion points |
|---|---|---|
| `c_vat_rate CONSTANT` | `c_vat_rate()` IMMUTABLE function | no package state in PostgreSQL |
| `fn_contract_total` | function | `NVL(SUM())` → `COALESCE(SUM())` |
| `pr_recalc_contract_total` | procedure | `SQL%ROWCOUNT` → `FOUND`, `SYSDATE` → `LOCALTIMESTAMP(0)`, `ORA-20010` → SQLSTATE `CT010` |
| `fn_status_name` | SQL function | `DECODE` with a NULL branch → `CASE WHEN x IS NULL` |
| `pr_change_contract_status` | procedure | `NO_DATA_FOUND` → `INTO STRICT`, `NVL2` → `CASE`, `NULL \|\| text` fix, `'' → NULL` parameter handling, cascade to POs |
| `fn_budget_usage_rate` | function | `TO_NUMBER(TO_CHAR(d,'YYYY'))` → range predicate, `NULLIF` against divide-by-zero |
| `pr_site_summary` (OUT params) | procedure with OUT params (PG 14+) | `CALL ... (id, NULL, NULL, NULL)` returns a row |
| `fn_top_vendor` | SQL function | `ROWNUM = 1` over an ordered inline view → `ORDER BY ... LIMIT 1`, `COLLATE "C"` for Oracle binary sort |
| `fn_contract_label` | SQL function | Oracle `\|\|` ignores NULL → `concat_ws()` |

All the traps (NVL, DECODE, ROWNUM, `''` vs NULL, SYSDATE vs `now()`, collation, implicit casts,
transaction semantics…) are written up in **[docs/conversion-notes.md](docs/conversion-notes.md)**.

---

## Validation results

From the final run (`results/validation_report.md`, PostgreSQL 16.15, 2026-10-12).

### Row counts

| Table | Source (`ora_src`) | Target (`erp`) | Result |
|---|---:|---:|---|
| site | 60 | 60 | PASS |
| contract_hdr | 2,008 | 2,008 | PASS |
| contract_dtl | 29,269 | 29,269 | PASS |
| purchase_order | 13,115 | 13,115 | PASS |
| budget | 1,814 | 1,814 | PASS |

### Per-site amounts (compared per site, sums shown for all 60 sites)

| Metric | Source total (KRW) | Target total (KRW) | Sites differing | Result |
|---|---:|---:|---:|---|
| Contract amount (header `total_amount`) | 1,887,465,771,726.00 | 1,887,465,771,726.00 | 0 / 60 | PASS |
| Contract line amount (detail `amount`) | 1,887,465,771,726.00 | 1,887,465,771,726.00 | 0 / 60 | PASS |
| Purchase order amount | 1,505,117,357,220.00 | 1,505,117,357,220.00 | 0 / 60 | PASS |
| Budget amount (original) | 2,385,370,000,000.00 | 2,385,370,000,000.00 | 0 / 60 | PASS |
| Budget amount (effective = `NVL(revised, original)`) | 2,423,768,200,000.00 | 2,423,768,200,000.00 | 0 / 60 | PASS |

Sample rows from `mig_check.site_totals` (all 60 are in the report):

| Site | Status | Contract src = tgt | PO src = tgt | Budget src = tgt | Match |
|---|---|---:|---:|---:|---|
| ST-22-0001 | Closed | 63,982,767,450 | 54,660,911,966 | 22,279,000,000 | ✅ |
| ST-21-0002 | Active | 22,360,898,481 | 17,127,183,109 | 90,551,000,000 | ✅ |
| ST-21-0003 | Active | 21,107,597,788 | 17,550,386,935 | 36,404,000,000 | ✅ |
| ST-27-0014 | Planned | 0 | 0 | 44,601,000,000 | ✅ |

### Everything else

| Category | Checks | Result |
|---|---|---|
| Full-row diff (`EXCEPT ALL` both ways, every column, after type mapping) | 5 tables | 5/5 PASS, 0 rows differ |
| NULL count kept (spec / remarks) | 20,562 = 20,562 | PASS |
| No `''` introduced in the target | 0 | PASS |
| Y/N → boolean | 2,808 = 2,808 | PASS |
| Identity restart ≥ Oracle `LAST_NUMBER` | 4 sequences | 4/4 PASS |
| PL/pgSQL parity against values computed from source data | 2,008 contracts, 226 site-years, 60 sites, 6 DECODE inputs | 6/6 PASS, 0 mismatches |
| Procedure behaviour tests (status workflow, error codes, `''`/NULL, cascade, identity) | 9 | 9/9 PASS |

### Negative test: the checks catch real defects

Three typical bugs were injected in a rolled-back transaction: a lost purchase order, a NULL turned
into `''`, and a line amount off by 0.01. **10 checks turned FAIL**, including row count, PO and
line totals, the row diff, NULL parity, the empty-string check, and three function-parity checks.
A clean report from this harness therefore means something.

---

## How to run

Requirements: PostgreSQL **14+** (OUT parameters in procedures), `psql` and `createdb` on `PATH`,
a role allowed to create databases, and Python 3.8+ (standard library only).

```bash
git clone <this repo> && cd oracle-to-postgres-migration
# connection via the usual libpq variables, e.g.
export PGHOST=localhost PGUSER=postgres PGPASSWORD=...
./run_demo.sh                    # creates/overwrites database "erp_migration_demo"
# DB=other_db ./run_demo.sh      # choose a different database name
```

It finishes in a few seconds. The script exits non-zero if any check fails.
Outputs go to `results/`: `validation_report.md`, the CSVs, and `run_output.log`.

Useful queries afterwards:

```sql
SELECT * FROM mig_check.run_all();                          -- all checks
SELECT * FROM mig_check.site_totals WHERE NOT all_match;    -- per-site differences (none)
CALL pkg_contract.pr_site_summary(1, NULL, NULL, NULL);     -- converted OUT-param procedure
SELECT pkg_contract.fn_top_vendor(1), pkg_contract.fn_budget_usage_rate(2, 2023);
```

### Against a real Oracle database

1. Run `oracle/01_schema.sql` and `oracle/02_pkg_contract.sql` in Oracle, then load the CSVs with
   `sqlldr` using the control files in `oracle/03_load/`. Or point at an existing schema.
2. In PostgreSQL, run `migration/oracle_fdw_setup.sql` instead of `simulation/*.sql`. This needs
   `oracle_fdw` and the Oracle Instant Client.
3. Run `postgres/*.sql`, `migration/01_precheck.sql`, `migration/02_migrate.sql`, and
   `validation/*.sql` as in `run_demo.sh`.
4. Optionally spool `oracle/04_source_checks.sql` on the Oracle side and compare it with the
   independent source numbers.

For larger volumes the same design scales: one transaction per table or partition, parallel sessions,
oracle_fdw `prefetch`, and the reconciliation queries per partition.
