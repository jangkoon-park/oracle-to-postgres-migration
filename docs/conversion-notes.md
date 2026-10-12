# Oracle → PostgreSQL conversion notes

These are the traps I check for on every Oracle → PostgreSQL project. Each one is
shown with the Oracle form, the PostgreSQL form, and where it appears in this repo.

---

## 1. Empty string vs NULL (the biggest one)

Oracle stores a zero-length string as NULL: `'' IS NULL` is **true**.
In PostgreSQL `''` and `NULL` are two different values.

| Expression | Oracle | PostgreSQL |
|---|---|---|
| `'' IS NULL` | TRUE | FALSE |
| `'abc' \|\| NULL` | `'abc'` | **NULL** |
| `LENGTH('')` | NULL | 0 |
| `NVL(col, '')` | does nothing (still NULL) | turns NULL into `''` |
| `WHERE col = ''` | never true | true for empty strings |
| `TRIM('   ')` | NULL | `''` |

What to do:
* **Data:** move NULLs as NULLs. Don't "clean" them into `''`. A naive `COALESCE(col,'')` in the
  extract changes how the application behaves. `validation/01_checks.sql` check #17 fails if any `''`
  shows up in the target, and the negative test injects exactly this defect (D2).
* **Code:** concatenation that relied on Oracle ignoring NULL needs `concat()` / `concat_ws()` or
  `COALESCE(x,'')`. See `fn_contract_label` and the `remarks || ...` line in
  `pr_change_contract_status` (`postgres/02_pkg_contract.sql`).
* **Parameters:** an application that used to send `''` to Oracle was really sending NULL.
  `pr_change_contract_status` uses `NULLIF(p_reason, '')` so it behaves the way it did before
  (test T8).

## 2. NVL / NVL2 / DECODE

| Oracle | PostgreSQL | Note |
|---|---|---|
| `NVL(a, b)` | `COALESCE(a, b)` | Oracle always evaluates `b`. COALESCE stops at the first non-NULL argument. |
| `NVL2(a, b, c)` | `CASE WHEN a IS NOT NULL THEN b ELSE c END` | |
| `DECODE(x, 'A', 1, 'B', 2, 0)` | `CASE x WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END` | |
| `DECODE(x, NULL, 'none', ...)` | `CASE WHEN x IS NULL THEN 'none' ...` | **DECODE treats NULL = NULL as a match. CASE does not.** A mechanical `CASE x WHEN NULL` never fires. |
| `DECODE` return type | | Comes from the first result. Numbers can quietly become strings. Cast explicitly. |

The repo covers this in `fn_status_name` (check #28 tests the NULL input).

## 3. ROWNUM

```sql
-- Oracle: classic top-N. ORDER BY has to sit in an inline view
SELECT * FROM (SELECT ... ORDER BY amt DESC) WHERE ROWNUM = 1;
-- PostgreSQL
SELECT ... ORDER BY amt DESC LIMIT 1;          -- or FETCH FIRST 1 ROW ONLY
```

* `WHERE ROWNUM <= 10 ORDER BY x` in Oracle takes **any** 10 rows and then sorts them. Legacy code with
  this bug is common. Don't "fix" it silently during the port. Flag it to the business.
* `ROWNUM` used as a row counter becomes `row_number() OVER (...)`.
* Pagination `WHERE rn BETWEEN :a AND :b` becomes `LIMIT n OFFSET m`, or keyset pagination.
* **Tie-breaking and sort order:** Oracle's default `NLS_SORT=BINARY` sorts by code point. PostgreSQL
  sorts by the database collation (e.g. `en_US.UTF-8`), so `'a' < 'B'` comes out differently. Top-N
  results and reports can change. `fn_top_vendor` uses `COLLATE "C"` to match Oracle (check #26).

## 4. Data types

| Oracle | PostgreSQL | Watch out for |
|---|---|---|
| `NUMBER(p,0)`, p ≤ 4 | `smallint` | |
| `NUMBER(p,0)`, 5 ≤ p ≤ 9 | `integer` | |
| `NUMBER(p,0)`, 10 ≤ p ≤ 18 | `bigint` | `NUMBER(10)` can hold 9,999,999,999, which is more than int4's max |
| `NUMBER(p,s)` | `numeric(p,s)` | Never use `float`/`double` for money |
| `NUMBER` (no precision) | `numeric` | Profile the data. If it only holds integers, use `bigint`, which is much faster |
| `FLOAT`, `BINARY_DOUBLE` | `double precision` | |
| `VARCHAR2(n BYTE)` | `varchar(n)` | PostgreSQL counts **characters**, so the column can hold more. That's safe, but app-side length checks may need a look |
| `VARCHAR2(n CHAR)` | `varchar(n)` | |
| `VARCHAR2(4000)` "big text" | `text` (+ CHECK if the limit matters) | |
| `CHAR(n)` | `char(n)` or `varchar(n)` | Blank-padding comparison rules differ; codes are usually better as `varchar` + CHECK |
| `CHAR(1)` `'Y'/'N'` | `boolean` | Pre-check that only Y/N exist |
| `DATE` | `timestamp(0)` **or** `date` | Oracle DATE **always has a time part**. Use `date` only when profiling proves the time is 00:00:00 (`migration/01_precheck.sql`) |
| `TIMESTAMP` | `timestamp` | |
| `TIMESTAMP WITH TIME ZONE` | `timestamptz` | PostgreSQL stores UTC and does not keep the original zone name |
| `CLOB` / `NCLOB` | `text` | |
| `BLOB` / `RAW` | `bytea` | |
| `ROWID` | none (use a real key) | |

## 5. Dates and time

| Oracle | PostgreSQL |
|---|---|
| `SYSDATE` | `LOCALTIMESTAMP(0)` / `now()` |
| `SYSTIMESTAMP` | `clock_timestamp()` / `now()` |
| `TRUNC(d)` | `date_trunc('day', d)` or `d::date` |
| `d + 1` (add a day) | `d + 1` works for `date`; use `d + interval '1 day'` for timestamp |
| `ADD_MONTHS(d, n)` | `d + make_interval(months => n)` (month-end rules differ slightly: Oracle snaps the last day of the month to the last day) |
| `MONTHS_BETWEEN(a, b)` | no built-in. Write a function or use `age()` |
| `TO_CHAR(d, 'YYYY') = :y` | `d >= make_date(y,1,1) AND d < make_date(y+1,1,1)` (lets the index work; see `fn_budget_usage_rate`) |

* `SYSDATE` is the clock **at the moment of the call**. `now()` / `LOCALTIMESTAMP` is fixed for the
  **whole transaction**. Long batch jobs that log `SYSDATE` per step need `clock_timestamp()`.
* `SYSDATE` uses the DB server OS time zone. `LOCALTIMESTAMP` uses the session `TimeZone` setting.

## 6. Sequences and identity

* `seq.NEXTVAL` becomes `nextval('seq')`. `SELECT seq.NEXTVAL FROM dual` becomes `SELECT nextval('seq')`.
* The legacy "sequence + BEFORE INSERT trigger" pattern becomes `GENERATED BY DEFAULT AS IDENTITY`.
  Use BY DEFAULT, not ALWAYS, so the migration can insert the original keys.
* **Restart point:** use `USER_SEQUENCES.LAST_NUMBER`, not `max(id)+1`. With `CACHE 20`, values
  between `max(id)` and `LAST_NUMBER` may already exist in interfaces, logs or files. The migration takes
  `GREATEST(max(id)+1, LAST_NUMBER)` (checks #19–22, test T9).

## 7. PL/SQL → PL/pgSQL

| PL/SQL | PL/pgSQL |
|---|---|
| `CREATE PACKAGE` | no packages. Use a **schema** per package (`pkg_contract.fn_x()` keeps call sites unchanged) |
| package constants / variables | IMMUTABLE function, or `current_setting('pkg.var')` for session state |
| `PROCEDURE` | `PROCEDURE` (PG 11+), called with `CALL` |
| `OUT` params in a procedure | supported from PG 14. Alternative: a function with `OUT` params / `RETURNS TABLE` |
| `RAISE_APPLICATION_ERROR(-20010, msg)` | `RAISE EXCEPTION '%', msg USING ERRCODE = 'CT010'` (map the error numbers 1:1 and document them) |
| `SQL%ROWCOUNT` / `SQL%FOUND` | `GET DIAGNOSTICS n = ROW_COUNT` / `FOUND` |
| `SELECT ... INTO v` raising `NO_DATA_FOUND` / `TOO_MANY_ROWS` | `SELECT ... INTO STRICT v`. **Without STRICT nothing is raised** and the variable is just NULL |
| `EXCEPTION WHEN OTHERS` | same, but each `BEGIN ... EXCEPTION` block is a subtransaction. Keep these out of tight loops |
| `DBMS_OUTPUT.PUT_LINE` | `RAISE NOTICE` |
| `COMMIT` inside a procedure | allowed in PG 11+ procedures, but not when called inside an outer transaction block |
| `PRAGMA AUTONOMOUS_TRANSACTION` | none. Use `dblink` / `pg_background`, or redesign |
| `%TYPE`, `%ROWTYPE` | supported |
| `CONNECT BY` | `WITH RECURSIVE` |
| `(+)` outer join | ANSI `LEFT JOIN` |
| `MINUS` | `EXCEPT` |
| `MERGE` | `MERGE` (PG 15+) or `INSERT ... ON CONFLICT` |
| `FROM dual` | leave it out |
| `SUBSTR(s, -3)` | `right(s, 3)`. A negative start means something different in PostgreSQL |
| `INSTR(s, x)` | `strpos(s, x)` |

## 8. Other behaviour differences worth a test

* **Identifier case:** Oracle folds unquoted names to UPPER case, PostgreSQL to lower case. Quoted
  `"CONTRACT_HDR"` from tools like ora2pg or ORMs breaks queries. Prefer unquoted lower case.
* **Implicit casts:** Oracle converts freely between strings and numbers (`WHERE num_col = '10'`).
  PostgreSQL is stricter, so application SQL can fail at run time. Grep for it.
* **Integer division:** in Oracle `NUMBER` division is always decimal. In PostgreSQL `int / int`
  truncates (`7/2 = 3`).
* **Transactions:** in PostgreSQL an error aborts the whole transaction until ROLLBACK. Oracle only
  rolls back the failing statement. Batch code that "catches and continues" needs savepoints.
* **Empty-result aggregates:** `SUM()` over no rows is NULL in both databases. Keep the `NVL/COALESCE`.
