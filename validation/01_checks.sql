--------------------------------------------------------------------------------
-- Reconciliation checks: source (ora_src) vs target (erp)
--
--   SELECT * FROM mig_check.run_all();        -- one row per check, PASS/FAIL
--   SELECT * FROM mig_check.site_totals;      -- per-site amounts side by side
--
-- Categories
--   1 ROW COUNT     rows per table
--   2 SITE TOTALS   per-site contract / contract-line / PO / budget amounts
--   3 ROW DIFF      full-row comparison (EXCEPT both ways) after type mapping
--   4 SEMANTICS     NULL vs '' parity, Y/N -> boolean, identity restart
--   5 PL/pgSQL      converted functions/procedures vs results computed on source
--------------------------------------------------------------------------------
DROP SCHEMA IF EXISTS mig_check CASCADE;
CREATE SCHEMA mig_check;

-- ---------------------------------------------------------------------------
-- Per-site totals, source and target side by side
-- ---------------------------------------------------------------------------
CREATE VIEW mig_check.site_totals AS
WITH src AS (
    SELECT s.site_id::bigint AS site_id,
           (SELECT COALESCE(SUM(total_amount), 0) FROM ora_src.contract_hdr h WHERE h.site_id = s.site_id) AS contract_amt,
           (SELECT COALESCE(SUM(d.amount), 0) FROM ora_src.contract_dtl d
              JOIN ora_src.contract_hdr h ON h.contract_id = d.contract_id WHERE h.site_id = s.site_id)    AS line_amt,
           (SELECT COALESCE(SUM(po_amount), 0) FROM ora_src.purchase_order p WHERE p.site_id = s.site_id)   AS po_amt,
           (SELECT COALESCE(SUM(budget_amount), 0) FROM ora_src.budget b WHERE b.site_id = s.site_id)       AS budget_amt,
           (SELECT COALESCE(SUM(COALESCE(revised_amount, budget_amount)), 0)
              FROM ora_src.budget b WHERE b.site_id = s.site_id)                                            AS eff_budget_amt
      FROM ora_src.site s
), tgt AS (
    SELECT s.site_id,
           (SELECT COALESCE(SUM(total_amount), 0) FROM erp.contract_hdr h WHERE h.site_id = s.site_id) AS contract_amt,
           (SELECT COALESCE(SUM(d.amount), 0) FROM erp.contract_dtl d
              JOIN erp.contract_hdr h ON h.contract_id = d.contract_id WHERE h.site_id = s.site_id)    AS line_amt,
           (SELECT COALESCE(SUM(po_amount), 0) FROM erp.purchase_order p WHERE p.site_id = s.site_id)   AS po_amt,
           (SELECT COALESCE(SUM(budget_amount), 0) FROM erp.budget b WHERE b.site_id = s.site_id)       AS budget_amt,
           (SELECT COALESCE(SUM(COALESCE(revised_amount, budget_amount)), 0)
              FROM erp.budget b WHERE b.site_id = s.site_id)                                            AS eff_budget_amt
      FROM erp.site s
)
SELECT COALESCE(src.site_id, tgt.site_id) AS site_id,
       src.contract_amt   AS src_contract_amt,   tgt.contract_amt   AS tgt_contract_amt,
       src.line_amt       AS src_line_amt,       tgt.line_amt       AS tgt_line_amt,
       src.po_amt         AS src_po_amt,         tgt.po_amt         AS tgt_po_amt,
       src.budget_amt     AS src_budget_amt,     tgt.budget_amt     AS tgt_budget_amt,
       src.eff_budget_amt AS src_eff_budget_amt, tgt.eff_budget_amt AS tgt_eff_budget_amt,
       (src.site_id IS NOT NULL AND tgt.site_id IS NOT NULL
        AND src.contract_amt   = tgt.contract_amt
        AND src.line_amt       = tgt.line_amt
        AND src.po_amt         = tgt.po_amt
        AND src.budget_amt     = tgt.budget_amt
        AND src.eff_budget_amt = tgt.eff_budget_amt) AS all_match
  FROM src FULL JOIN tgt ON tgt.site_id = src.site_id;


-- ---------------------------------------------------------------------------
-- Source rows projected into target types (the mapping under test)
-- ---------------------------------------------------------------------------
CREATE VIEW mig_check.src_site AS
SELECT site_id::bigint, site_code::text, site_name::text, region::text, client_name::text,
       start_date::date, end_date::date, rtrim(status)::text AS status, manager_name::text, created_at
  FROM ora_src.site;
CREATE VIEW mig_check.tgt_site AS
SELECT site_id, site_code::text, site_name::text, region::text, client_name::text,
       start_date, end_date, status::text, manager_name::text, created_at
  FROM erp.site;

CREATE VIEW mig_check.src_contract_hdr AS
SELECT contract_id::bigint, contract_no::text, site_id::bigint, vendor_name::text, contract_type::text,
       contract_date::date, start_date::date, end_date::date, currency::text, total_amount, vat_amount,
       status::text, retention_rate, remarks::text, created_at, updated_at
  FROM ora_src.contract_hdr;
CREATE VIEW mig_check.tgt_contract_hdr AS
SELECT contract_id, contract_no::text, site_id, vendor_name::text, contract_type::text,
       contract_date, start_date, end_date, currency::text, total_amount, vat_amount,
       status::text, retention_rate, remarks, created_at, updated_at
  FROM erp.contract_hdr;

CREATE VIEW mig_check.src_contract_dtl AS
SELECT contract_id::bigint, line_no::integer, item_code::text, item_name::text, spec::text, unit::text,
       quantity, unit_price, amount, cost_code::text
  FROM ora_src.contract_dtl;
CREATE VIEW mig_check.tgt_contract_dtl AS
SELECT contract_id, line_no, item_code::text, item_name::text, spec::text, unit::text,
       quantity, unit_price, amount, cost_code::text
  FROM erp.contract_dtl;

CREATE VIEW mig_check.src_purchase_order AS
SELECT po_id::bigint, po_no::text, site_id::bigint, contract_id::bigint, vendor_name::text, po_date::date,
       delivery_date::date, cost_code::text, po_amount, status::text, (urgent_yn = 'Y') AS is_urgent,
       remarks::text, created_at
  FROM ora_src.purchase_order;
CREATE VIEW mig_check.tgt_purchase_order AS
SELECT po_id, po_no::text, site_id, contract_id, vendor_name::text, po_date,
       delivery_date, cost_code::text, po_amount, status::text, is_urgent,
       remarks::text, created_at
  FROM erp.purchase_order;

CREATE VIEW mig_check.src_budget AS
SELECT budget_id::bigint, site_id::bigint, fiscal_year::integer, cost_code::text, budget_amount,
       revised_amount, (approved_yn = 'Y') AS is_approved, created_at
  FROM ora_src.budget;
CREATE VIEW mig_check.tgt_budget AS
SELECT budget_id, site_id, fiscal_year::integer, cost_code::text, budget_amount,
       revised_amount, is_approved, created_at
  FROM erp.budget;


-- ---------------------------------------------------------------------------
-- run_all(): every check as one result row
-- ---------------------------------------------------------------------------
CREATE FUNCTION mig_check.run_all()
RETURNS TABLE (check_no int, category text, check_name text,
               source_value text, target_value text, detail text, status text)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    t      text;
    n_src  numeric;
    n_tgt  numeric;
    n_bad  bigint;
    n_all  bigint;
    seq    record;
    r      record;
    v_c    numeric; v_p numeric; v_b numeric;
BEGIN
    check_no := 0;

    -- 1. ROW COUNT ----------------------------------------------------------
    category := 'ROW COUNT';
    FOREACH t IN ARRAY ARRAY['site','contract_hdr','contract_dtl','purchase_order','budget'] LOOP
        EXECUTE format('SELECT count(*) FROM ora_src.%I', t) INTO n_src;
        EXECUTE format('SELECT count(*) FROM erp.%I', t)     INTO n_tgt;
        check_no := check_no + 1;
        check_name := t; source_value := n_src; target_value := n_tgt;
        detail := format('diff %s', n_tgt - n_src);
        status := CASE WHEN n_src = n_tgt THEN 'PASS' ELSE 'FAIL' END;
        RETURN NEXT;
    END LOOP;

    -- 2. SITE TOTALS --------------------------------------------------------
    category := 'SITE TOTALS';
    FOR r IN SELECT * FROM (VALUES
                ('contract_amt',   'Contract amount (header total_amount)'),
                ('line_amt',       'Contract line amount (detail amount)'),
                ('po_amt',         'Purchase order amount'),
                ('budget_amt',     'Budget amount (original)'),
                ('eff_budget_amt', 'Budget amount (effective = NVL(revised, original))')) v(col, label)
    LOOP
        EXECUTE format('SELECT sum(src_%1$s), sum(tgt_%1$s),
                               count(*) FILTER (WHERE src_%1$s IS DISTINCT FROM tgt_%1$s), count(*)
                          FROM mig_check.site_totals', r.col)
           INTO n_src, n_tgt, n_bad, n_all;
        check_no := check_no + 1;
        check_name := r.label;
        source_value := to_char(n_src, 'FM999,999,999,999,999,990.00');
        target_value := to_char(n_tgt, 'FM999,999,999,999,999,990.00');
        detail := format('%s of %s sites differ', n_bad, n_all);
        status := CASE WHEN n_bad = 0 AND n_src = n_tgt THEN 'PASS' ELSE 'FAIL' END;
        RETURN NEXT;
    END LOOP;

    -- 3. ROW DIFF -----------------------------------------------------------
    category := 'ROW DIFF';
    FOREACH t IN ARRAY ARRAY['site','contract_hdr','contract_dtl','purchase_order','budget'] LOOP
        EXECUTE format('SELECT (SELECT count(*) FROM (SELECT * FROM mig_check.src_%1$s EXCEPT ALL SELECT * FROM mig_check.tgt_%1$s) a),
                               (SELECT count(*) FROM (SELECT * FROM mig_check.tgt_%1$s EXCEPT ALL SELECT * FROM mig_check.src_%1$s) b)', t)
           INTO n_src, n_tgt;
        check_no := check_no + 1;
        check_name := t || ' (all columns)';
        source_value := format('%s only in source', n_src);
        target_value := format('%s only in target', n_tgt);
        detail := 'EXCEPT ALL in both directions';
        status := CASE WHEN n_src = 0 AND n_tgt = 0 THEN 'PASS' ELSE 'FAIL' END;
        RETURN NEXT;
    END LOOP;

    -- 4. SEMANTICS ----------------------------------------------------------
    category := 'SEMANTICS';

    check_no := check_no + 1;
    check_name := 'NULL count: contract_dtl.spec + contract_hdr.remarks + purchase_order.remarks';
    SELECT (SELECT count(*) FROM ora_src.contract_dtl WHERE spec IS NULL)
         + (SELECT count(*) FROM ora_src.contract_hdr WHERE remarks IS NULL)
         + (SELECT count(*) FROM ora_src.purchase_order WHERE remarks IS NULL) INTO n_src;
    SELECT (SELECT count(*) FROM erp.contract_dtl WHERE spec IS NULL)
         + (SELECT count(*) FROM erp.contract_hdr WHERE remarks IS NULL)
         + (SELECT count(*) FROM erp.purchase_order WHERE remarks IS NULL) INTO n_tgt;
    source_value := n_src; target_value := n_tgt; detail := 'Oracle NULLs must stay NULL';
    status := CASE WHEN n_src = n_tgt THEN 'PASS' ELSE 'FAIL' END;
    RETURN NEXT;

    check_no := check_no + 1;
    check_name := 'Empty strings ('''') in target text columns';
    SELECT (SELECT count(*) FROM erp.site WHERE client_name = '' OR manager_name = '')
         + (SELECT count(*) FROM erp.contract_hdr WHERE remarks = '')
         + (SELECT count(*) FROM erp.contract_dtl WHERE spec = '')
         + (SELECT count(*) FROM erp.purchase_order WHERE remarks = '') INTO n_tgt;
    source_value := '0 (impossible in Oracle)'; target_value := n_tgt;
    detail := 'Oracle cannot store '''', so none may appear';
    status := CASE WHEN n_tgt = 0 THEN 'PASS' ELSE 'FAIL' END;
    RETURN NEXT;

    check_no := check_no + 1;
    check_name := 'Y/N -> boolean (urgent_yn=Y vs is_urgent, approved_yn=Y vs is_approved)';
    SELECT (SELECT count(*) FROM ora_src.purchase_order WHERE urgent_yn = 'Y')
         + (SELECT count(*) FROM ora_src.budget WHERE approved_yn = 'Y') INTO n_src;
    SELECT (SELECT count(*) FROM erp.purchase_order WHERE is_urgent)
         + (SELECT count(*) FROM erp.budget WHERE is_approved) INTO n_tgt;
    source_value := n_src; target_value := n_tgt; detail := 'count of Y / true';
    status := CASE WHEN n_src = n_tgt THEN 'PASS' ELSE 'FAIL' END;
    RETURN NEXT;

    FOR seq IN SELECT * FROM (VALUES ('erp.site','site_id','SITE_SEQ'),
                                     ('erp.contract_hdr','contract_id','CONTRACT_SEQ'),
                                     ('erp.purchase_order','po_id','PO_SEQ'),
                                     ('erp.budget','budget_id','BUDGET_SEQ')) v(tbl, col, oseq)
    LOOP
        -- next value an INSERT would get, without consuming it
        EXECUTE format('SELECT CASE WHEN is_called THEN last_value + 1 ELSE last_value END FROM %s',
                       pg_get_serial_sequence(seq.tbl, seq.col)) INTO n_tgt;
        SELECT last_number INTO n_src FROM ora_src.user_sequences WHERE sequence_name = seq.oseq;
        EXECUTE format('SELECT COALESCE(max(%I),0) FROM %s', seq.col, seq.tbl) INTO v_c;
        check_no := check_no + 1;
        check_name := format('Identity %s.%s restarts after Oracle %s', seq.tbl, seq.col, seq.oseq);
        source_value := format('LAST_NUMBER %s', n_src);
        target_value := format('next %s', n_tgt);
        detail := format('max(id) %s', v_c);
        status := CASE WHEN n_tgt >= n_src AND n_tgt > v_c THEN 'PASS' ELSE 'FAIL' END;
        RETURN NEXT;
    END LOOP;

    -- 5. PL/pgSQL parity ----------------------------------------------------
    category := 'PL/pgSQL';

    check_no := check_no + 1;
    check_name := 'fn_contract_total() for every contract';
    SELECT count(*), count(*) FILTER (WHERE pkg_contract.fn_contract_total(h.contract_id::bigint)
                                            IS DISTINCT FROM COALESCE(x.s, 0))
      INTO n_all, n_bad
      FROM ora_src.contract_hdr h
      LEFT JOIN (SELECT contract_id, sum(amount) s FROM ora_src.contract_dtl GROUP BY contract_id) x
             ON x.contract_id = h.contract_id;
    source_value := n_all || ' contracts'; target_value := n_bad || ' mismatches';
    detail := 'vs NVL(SUM(amount),0) on source';
    status := CASE WHEN n_bad = 0 THEN 'PASS' ELSE 'FAIL' END;
    RETURN NEXT;

    check_no := check_no + 1;
    check_name := 'fn_budget_usage_rate() for every site x fiscal year';
    SELECT count(*), count(*) FILTER (WHERE pkg_contract.fn_budget_usage_rate(k.site_id::bigint, k.fy::int)
                                            IS DISTINCT FROM
                                            -- Oracle formula, evaluated on the source data
                                            ROUND((SELECT COALESCE(sum(po_amount),0) FROM ora_src.purchase_order p
                                                    WHERE p.site_id = k.site_id AND p.status <> 'CANCELLED'
                                                      AND to_char(p.po_date,'YYYY')::numeric = k.fy)
                                                  / NULLIF((SELECT COALESCE(sum(COALESCE(revised_amount,budget_amount)),0)
                                                              FROM ora_src.budget b
                                                             WHERE b.site_id = k.site_id AND b.fiscal_year = k.fy), 0) * 100, 2))
      INTO n_all, n_bad
      FROM (SELECT DISTINCT site_id, fiscal_year AS fy FROM ora_src.budget
            UNION
            SELECT DISTINCT site_id, extract(year FROM po_date) FROM ora_src.purchase_order) k;
    source_value := n_all || ' site-years'; target_value := n_bad || ' mismatches';
    detail := 'incl. years with PO but no budget (NULLIF -> NULL)';
    status := CASE WHEN n_bad = 0 THEN 'PASS' ELSE 'FAIL' END;
    RETURN NEXT;

    check_no := check_no + 1;
    check_name := 'pr_site_summary() OUT params for every site';
    n_bad := 0; n_all := 0;
    FOR r IN SELECT site_id FROM ora_src.site LOOP
        CALL pkg_contract.pr_site_summary(r.site_id::bigint, v_c, v_p, v_b);
        n_all := n_all + 1;
        IF (v_c, v_p, v_b) IS DISTINCT FROM (
               (SELECT COALESCE(sum(total_amount),0) FROM ora_src.contract_hdr WHERE site_id = r.site_id AND status <> 'CANCELLED'),
               (SELECT COALESCE(sum(po_amount),0) FROM ora_src.purchase_order WHERE site_id = r.site_id AND status <> 'CANCELLED'),
               (SELECT COALESCE(sum(COALESCE(revised_amount,budget_amount)),0) FROM ora_src.budget WHERE site_id = r.site_id))
        THEN n_bad := n_bad + 1;
        END IF;
    END LOOP;
    source_value := n_all || ' sites'; target_value := n_bad || ' mismatches';
    detail := 'contract / PO / effective budget';
    status := CASE WHEN n_bad = 0 THEN 'PASS' ELSE 'FAIL' END;
    RETURN NEXT;

    check_no := check_no + 1;
    check_name := 'fn_top_vendor() (ROWNUM -> LIMIT) for every site';
    SELECT count(*), count(*) FILTER (WHERE pkg_contract.fn_top_vendor(s.site_id::bigint) IS DISTINCT FROM ref.vendor_name)
      INTO n_all, n_bad
      FROM ora_src.site s
      LEFT JOIN (SELECT site_id, vendor_name,
                        row_number() OVER (PARTITION BY site_id
                                           ORDER BY sum(total_amount) DESC, vendor_name COLLATE "C") AS rn
                   FROM ora_src.contract_hdr
                  WHERE status IN ('APPROVED','CLOSED')
                  GROUP BY site_id, vendor_name) ref
             ON ref.site_id = s.site_id AND ref.rn = 1;
    source_value := n_all || ' sites'; target_value := n_bad || ' mismatches';
    detail := 'binary (NLS_SORT=BINARY) tie-break';
    status := CASE WHEN n_bad = 0 THEN 'PASS' ELSE 'FAIL' END;
    RETURN NEXT;

    check_no := check_no + 1;
    check_name := 'fn_contract_label() (Oracle || NULL semantics)';
    SELECT count(*), count(*) FILTER (WHERE pkg_contract.fn_contract_label(h.contract_id::bigint) IS DISTINCT FROM
                                            -- Oracle: NULL in || acts like '', TRIM('') is NULL
                                            NULLIF(TRIM(h.contract_no || ' ' || h.vendor_name || ' ' || COALESCE(h.remarks, '')), ''))
      INTO n_all, n_bad
      FROM ora_src.contract_hdr h;
    source_value := n_all || ' contracts'; target_value := n_bad || ' mismatches';
    detail := (SELECT count(*) FROM ora_src.contract_hdr WHERE remarks IS NULL) || ' have NULL remarks';
    status := CASE WHEN n_bad = 0 THEN 'PASS' ELSE 'FAIL' END;
    RETURN NEXT;

    check_no := check_no + 1;
    check_name := 'fn_status_name() (DECODE -> CASE, incl. NULL)';
    SELECT count(*), count(*) FILTER (WHERE pkg_contract.fn_status_name(v.s) IS DISTINCT FROM v.expected)
      INTO n_all, n_bad
      FROM (VALUES ('DRAFT','Draft'), ('APPROVED','Approved'), ('CLOSED','Closed'),
                   ('CANCELLED','Cancelled'), (NULL,'(no status)'), ('XYZ','Unknown')) v(s, expected);
    source_value := n_all || ' inputs'; target_value := n_bad || ' mismatches';
    detail := 'DECODE matches NULL = NULL';
    status := CASE WHEN n_bad = 0 THEN 'PASS' ELSE 'FAIL' END;
    RETURN NEXT;
END;
$$;
