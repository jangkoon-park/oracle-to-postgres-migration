--------------------------------------------------------------------------------
-- PKG_CONTRACT converted to PL/pgSQL (source: oracle/02_pkg_contract.sql)
--
-- PostgreSQL has no packages: the package becomes a schema (pkg_contract), so
-- callers keep the familiar  pkg_contract.fn_xxx(...)  notation.
--   FUNCTION              -> FUNCTION
--   PROCEDURE             -> PROCEDURE (CALL ...), PG 11+; OUT params need PG 14+
--   package constant      -> IMMUTABLE SQL function c_vat_rate()
--   RAISE_APPLICATION_ERROR(-200nn) -> RAISE EXCEPTION ... USING ERRCODE 'CT0nn'
--   SQL%ROWCOUNT          -> GET DIAGNOSTICS / FOUND
--   NO_DATA_FOUND         -> SELECT ... INTO STRICT  (plain INTO never raises)
--------------------------------------------------------------------------------
DROP SCHEMA IF EXISTS pkg_contract CASCADE;
CREATE SCHEMA pkg_contract;

-- c_vat_rate CONSTANT NUMBER := 0.1;
CREATE FUNCTION pkg_contract.c_vat_rate() RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT 0.1::numeric $$;


-- NVL(SUM(x),0) -> COALESCE(SUM(x),0)
CREATE FUNCTION pkg_contract.fn_contract_total(p_contract_id bigint)
RETURNS numeric
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_total numeric;
BEGIN
    SELECT COALESCE(SUM(amount), 0)
      INTO v_total
      FROM erp.contract_dtl
     WHERE contract_id = p_contract_id;
    RETURN v_total;
END;
$$;


CREATE PROCEDURE pkg_contract.pr_recalc_contract_total(p_contract_id bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total numeric;
BEGIN
    v_total := pkg_contract.fn_contract_total(p_contract_id);

    UPDATE erp.contract_hdr
       SET total_amount = v_total,
           vat_amount   = ROUND(v_total * pkg_contract.c_vat_rate(), 0),
           updated_at   = LOCALTIMESTAMP(0)            -- SYSDATE
     WHERE contract_id  = p_contract_id;

    IF NOT FOUND THEN                                  -- SQL%ROWCOUNT = 0
        RAISE EXCEPTION 'Contract not found: %', p_contract_id
              USING ERRCODE = 'CT010';                 -- was ORA-20010
    END IF;
END;
$$;


-- DECODE(x, 'A','a', NULL,'n', 'other') -> CASE; the NULL branch needs IS NULL,
-- because a simple  CASE x WHEN NULL  never matches.
CREATE FUNCTION pkg_contract.fn_status_name(p_status varchar)
RETURNS varchar
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT CASE
             WHEN p_status IS NULL         THEN '(no status)'
             WHEN p_status = 'DRAFT'       THEN 'Draft'
             WHEN p_status = 'APPROVED'    THEN 'Approved'
             WHEN p_status = 'CLOSED'      THEN 'Closed'
             WHEN p_status = 'CANCELLED'   THEN 'Cancelled'
             ELSE 'Unknown'
           END
$$;


CREATE PROCEDURE pkg_contract.pr_change_contract_status(
    p_contract_id bigint,
    p_new_status  varchar,
    p_reason      varchar DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_status erp.contract_hdr.status%TYPE;
    v_total      erp.contract_hdr.total_amount%TYPE;
    v_reason     varchar := NULLIF(p_reason, '');   -- Oracle: '' IS NULL, keep that contract
BEGIN
    BEGIN
        SELECT status, total_amount
          INTO STRICT v_old_status, v_total          -- STRICT => NO_DATA_FOUND like Oracle
          FROM erp.contract_hdr
         WHERE contract_id = p_contract_id
           FOR UPDATE;
    EXCEPTION
        WHEN no_data_found THEN
            RAISE EXCEPTION 'Contract not found: %', p_contract_id USING ERRCODE = 'CT010';
    END;

    IF NOT (   (v_old_status = 'DRAFT'    AND p_new_status IN ('APPROVED','CANCELLED'))
            OR (v_old_status = 'APPROVED' AND p_new_status IN ('CLOSED','CANCELLED'))) THEN
        RAISE EXCEPTION 'Invalid status transition % -> %', v_old_status, p_new_status
              USING ERRCODE = 'CT020';
    END IF;

    IF p_new_status = 'APPROVED' THEN
        CALL pkg_contract.pr_recalc_contract_total(p_contract_id);
        IF pkg_contract.fn_contract_total(p_contract_id) = 0 THEN
            RAISE EXCEPTION 'Cannot approve a contract without lines' USING ERRCODE = 'CT021';
        END IF;
    END IF;

    -- NVL2(reason, remarks || ..., remarks): in PostgreSQL NULL || 'x' IS NULL,
    -- so the NULL remarks must be COALESCEd to keep Oracle's result.
    UPDATE erp.contract_hdr
       SET status     = p_new_status,
           remarks    = CASE WHEN v_reason IS NOT NULL
                             THEN left(COALESCE(remarks, '') || ' [' || p_new_status || '] ' || v_reason, 4000)
                             ELSE remarks
                        END,
           updated_at = LOCALTIMESTAMP(0)
     WHERE contract_id = p_contract_id;

    IF p_new_status = 'CANCELLED' THEN
        UPDATE erp.purchase_order
           SET status = 'CANCELLED'
         WHERE contract_id = p_contract_id
           AND status = 'ISSUED';
    END IF;
END;
$$;


CREATE FUNCTION pkg_contract.fn_budget_usage_rate(p_site_id bigint, p_fiscal_year integer)
RETURNS numeric
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_budget numeric;
    v_po     numeric;
BEGIN
    SELECT COALESCE(SUM(COALESCE(revised_amount, budget_amount)), 0)
      INTO v_budget
      FROM erp.budget
     WHERE site_id = p_site_id
       AND fiscal_year = p_fiscal_year;

    -- TO_NUMBER(TO_CHAR(po_date,'YYYY')) = :y  -> sargable date range
    SELECT COALESCE(SUM(po_amount), 0)
      INTO v_po
      FROM erp.purchase_order
     WHERE site_id = p_site_id
       AND status <> 'CANCELLED'
       AND po_date >= make_date(p_fiscal_year, 1, 1)
       AND po_date <  make_date(p_fiscal_year + 1, 1, 1);

    RETURN ROUND(v_po / NULLIF(v_budget, 0) * 100, 2);
END;
$$;


-- OUT parameters: PROCEDURE with OUT args (PG 14+).  CALL returns them as a row:
--   CALL pkg_contract.pr_site_summary(1, NULL, NULL, NULL);
CREATE PROCEDURE pkg_contract.pr_site_summary(
    p_site_id        bigint,
    OUT o_contract_amt numeric,
    OUT o_po_amt       numeric,
    OUT o_budget_amt   numeric)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT COALESCE(SUM(total_amount), 0) INTO o_contract_amt
      FROM erp.contract_hdr WHERE site_id = p_site_id AND status <> 'CANCELLED';

    SELECT COALESCE(SUM(po_amount), 0) INTO o_po_amt
      FROM erp.purchase_order WHERE site_id = p_site_id AND status <> 'CANCELLED';

    SELECT COALESCE(SUM(COALESCE(revised_amount, budget_amount)), 0) INTO o_budget_amt
      FROM erp.budget WHERE site_id = p_site_id;
END;
$$;


-- ROWNUM top-N -> ORDER BY ... LIMIT 1.
-- COLLATE "C" reproduces Oracle's default NLS_SORT=BINARY for the tie-breaker.
CREATE FUNCTION pkg_contract.fn_top_vendor(p_site_id bigint)
RETURNS varchar
LANGUAGE sql STABLE
AS $$
    SELECT vendor_name
      FROM erp.contract_hdr
     WHERE site_id = p_site_id
       AND status IN ('APPROVED','CLOSED')
     GROUP BY vendor_name
     ORDER BY SUM(total_amount) DESC, vendor_name COLLATE "C"
     LIMIT 1
$$;


-- Oracle:  a || ' ' || NULL  = 'a '   PostgreSQL: = NULL.
-- concat_ws() skips NULLs; NULLIF(TRIM(..),'') mimics Oracle's TRIM('') = NULL.
CREATE FUNCTION pkg_contract.fn_contract_label(p_contract_id bigint)
RETURNS varchar
LANGUAGE sql STABLE
AS $$
    SELECT NULLIF(TRIM(concat_ws(' ', contract_no, vendor_name, remarks)), '')
      FROM erp.contract_hdr
     WHERE contract_id = p_contract_id
$$;
