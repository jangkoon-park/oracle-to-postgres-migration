--------------------------------------------------------------------------------
-- Source-side reconciliation queries (run in Oracle with SQL*Plus / SQLcl).
-- Spool the output and compare with validation/01_checks.sql on PostgreSQL.
-- In the simulated run these exact numbers come from the ora_src schema.
--------------------------------------------------------------------------------
SET PAGESIZE 200 LINESIZE 200 FEEDBACK OFF
COLUMN table_name FORMAT A20

-- 1) Row counts per table
SELECT 'SITE'           AS table_name, COUNT(*) AS row_count FROM site           UNION ALL
SELECT 'CONTRACT_HDR',                 COUNT(*)              FROM contract_hdr   UNION ALL
SELECT 'CONTRACT_DTL',                 COUNT(*)              FROM contract_dtl   UNION ALL
SELECT 'PURCHASE_ORDER',               COUNT(*)              FROM purchase_order UNION ALL
SELECT 'BUDGET',                       COUNT(*)              FROM budget;

-- 2) Per-site amounts (contract / contract lines / PO / budget)
SELECT s.site_id,
       s.site_code,
       NVL(c.contract_amt, 0)  AS contract_amt,
       NVL(l.line_amt, 0)      AS contract_line_amt,
       NVL(p.po_amt, 0)        AS po_amt,
       NVL(b.budget_amt, 0)    AS budget_amt,
       NVL(b.eff_budget_amt,0) AS effective_budget_amt
  FROM site s
  LEFT JOIN (SELECT site_id, SUM(total_amount) contract_amt
               FROM contract_hdr GROUP BY site_id) c ON c.site_id = s.site_id
  LEFT JOIN (SELECT h.site_id, SUM(d.amount) line_amt
               FROM contract_dtl d JOIN contract_hdr h ON h.contract_id = d.contract_id
              GROUP BY h.site_id) l ON l.site_id = s.site_id
  LEFT JOIN (SELECT site_id, SUM(po_amount) po_amt
               FROM purchase_order GROUP BY site_id) p ON p.site_id = s.site_id
  LEFT JOIN (SELECT site_id, SUM(budget_amount) budget_amt,
                    SUM(NVL(revised_amount, budget_amount)) eff_budget_amt
               FROM budget GROUP BY site_id) b ON b.site_id = s.site_id
 ORDER BY s.site_id;

-- 3) Pre-migration data profiling used by migration/01_precheck.sql
SELECT 'contract_date has time part' AS check_name, COUNT(*) AS cnt
  FROM contract_hdr WHERE contract_date <> TRUNC(contract_date)
UNION ALL
SELECT 'po_date has time part', COUNT(*) FROM purchase_order WHERE po_date <> TRUNC(po_date)
UNION ALL
SELECT 'urgent_yn not in (Y,N)', COUNT(*) FROM purchase_order WHERE urgent_yn NOT IN ('Y','N')
UNION ALL
SELECT 'chars > 4000 bytes in remarks', COUNT(*) FROM contract_hdr WHERE LENGTHB(remarks) > 4000;

-- 4) Sequence high-water marks (target IDENTITY columns restart from here)
SELECT sequence_name, last_number FROM user_sequences ORDER BY sequence_name;
