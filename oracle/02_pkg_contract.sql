--------------------------------------------------------------------------------
-- PKG_CONTRACT : business logic of the (fictional) BuildCo ERP contract module.
-- Oracle PL/SQL source. Converted to PL/pgSQL in postgres/02_contract_logic.sql.
--
-- The code deliberately uses the Oracle idioms that need attention during a
-- migration: NVL, NVL2, DECODE, ROWNUM, SYSDATE, SQL%ROWCOUNT, NO_DATA_FOUND,
-- RAISE_APPLICATION_ERROR, OUT parameters, '||' with NULL, package constants.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE pkg_contract AS

    c_vat_rate CONSTANT NUMBER := 0.1;     -- package constant (10% VAT)

    -- Sum of detail line amounts for one contract (0 when no lines)
    FUNCTION fn_contract_total (p_contract_id IN contract_hdr.contract_id%TYPE)
        RETURN NUMBER;

    -- Re-calculate CONTRACT_HDR.total_amount / vat_amount from the lines
    PROCEDURE pr_recalc_contract_total (p_contract_id IN contract_hdr.contract_id%TYPE);

    -- Human readable status (DECODE)
    FUNCTION fn_status_name (p_status IN VARCHAR2) RETURN VARCHAR2;

    -- Status workflow: DRAFT -> APPROVED -> CLOSED, DRAFT/APPROVED -> CANCELLED
    PROCEDURE pr_change_contract_status (
        p_contract_id IN contract_hdr.contract_id%TYPE,
        p_new_status  IN contract_hdr.status%TYPE,
        p_reason      IN VARCHAR2 DEFAULT NULL);

    -- PO amount / effective budget * 100 for one site and fiscal year
    FUNCTION fn_budget_usage_rate (
        p_site_id     IN site.site_id%TYPE,
        p_fiscal_year IN NUMBER) RETURN NUMBER;

    -- Site totals returned through OUT parameters
    PROCEDURE pr_site_summary (
        p_site_id      IN  site.site_id%TYPE,
        o_contract_amt OUT NUMBER,
        o_po_amt       OUT NUMBER,
        o_budget_amt   OUT NUMBER);

    -- Vendor with the largest approved contract amount on a site (ROWNUM)
    FUNCTION fn_top_vendor (p_site_id IN site.site_id%TYPE) RETURN VARCHAR2;

    -- Display label: "<contract_no> <vendor> <remarks>" (NULL-safe concat in Oracle)
    FUNCTION fn_contract_label (p_contract_id IN contract_hdr.contract_id%TYPE)
        RETURN VARCHAR2;

END pkg_contract;
/

CREATE OR REPLACE PACKAGE BODY pkg_contract AS

    FUNCTION fn_contract_total (p_contract_id IN contract_hdr.contract_id%TYPE)
        RETURN NUMBER
    IS
        v_total NUMBER;
    BEGIN
        SELECT NVL(SUM(amount), 0)
          INTO v_total
          FROM contract_dtl
         WHERE contract_id = p_contract_id;
        RETURN v_total;
    END fn_contract_total;


    PROCEDURE pr_recalc_contract_total (p_contract_id IN contract_hdr.contract_id%TYPE)
    IS
        v_total NUMBER;
    BEGIN
        v_total := fn_contract_total(p_contract_id);

        UPDATE contract_hdr
           SET total_amount = v_total,
               vat_amount   = ROUND(v_total * c_vat_rate, 0),
               updated_at   = SYSDATE
         WHERE contract_id  = p_contract_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20010, 'Contract not found: ' || p_contract_id);
        END IF;
    END pr_recalc_contract_total;


    FUNCTION fn_status_name (p_status IN VARCHAR2) RETURN VARCHAR2
    IS
    BEGIN
        -- DECODE treats NULL = NULL as a match, CASE WHEN x = NULL does not.
        RETURN DECODE(p_status,
                      'DRAFT',     'Draft',
                      'APPROVED',  'Approved',
                      'CLOSED',    'Closed',
                      'CANCELLED', 'Cancelled',
                      NULL,        '(no status)',
                                   'Unknown');
    END fn_status_name;


    PROCEDURE pr_change_contract_status (
        p_contract_id IN contract_hdr.contract_id%TYPE,
        p_new_status  IN contract_hdr.status%TYPE,
        p_reason      IN VARCHAR2 DEFAULT NULL)
    IS
        v_old_status contract_hdr.status%TYPE;
        v_total      contract_hdr.total_amount%TYPE;
        v_allowed    NUMBER(1);
    BEGIN
        SELECT status, total_amount
          INTO v_old_status, v_total
          FROM contract_hdr
         WHERE contract_id = p_contract_id
           FOR UPDATE;

        v_allowed := CASE
                        WHEN v_old_status = 'DRAFT'    AND p_new_status IN ('APPROVED','CANCELLED') THEN 1
                        WHEN v_old_status = 'APPROVED' AND p_new_status IN ('CLOSED','CANCELLED')   THEN 1
                        ELSE 0
                     END;

        IF v_allowed = 0 THEN
            RAISE_APPLICATION_ERROR(-20020,
                'Invalid status transition ' || v_old_status || ' -> ' || p_new_status);
        END IF;

        IF p_new_status = 'APPROVED' THEN
            pr_recalc_contract_total(p_contract_id);
            IF fn_contract_total(p_contract_id) = 0 THEN
                RAISE_APPLICATION_ERROR(-20021, 'Cannot approve a contract without lines');
            END IF;
        END IF;

        UPDATE contract_hdr
           SET status     = p_new_status,
               remarks    = NVL2(p_reason,
                                 SUBSTR(remarks || ' [' || p_new_status || '] ' || p_reason, 1, 4000),
                                 remarks),
               updated_at = SYSDATE
         WHERE contract_id = p_contract_id;

        -- Cancelling a contract cancels its open purchase orders
        IF p_new_status = 'CANCELLED' THEN
            UPDATE purchase_order
               SET status = 'CANCELLED'
             WHERE contract_id = p_contract_id
               AND status = 'ISSUED';
        END IF;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20010, 'Contract not found: ' || p_contract_id);
    END pr_change_contract_status;


    FUNCTION fn_budget_usage_rate (
        p_site_id     IN site.site_id%TYPE,
        p_fiscal_year IN NUMBER) RETURN NUMBER
    IS
        v_budget NUMBER;
        v_po     NUMBER;
    BEGIN
        SELECT NVL(SUM(NVL(revised_amount, budget_amount)), 0)
          INTO v_budget
          FROM budget
         WHERE site_id = p_site_id
           AND fiscal_year = p_fiscal_year;

        SELECT NVL(SUM(po_amount), 0)
          INTO v_po
          FROM purchase_order
         WHERE site_id = p_site_id
           AND status <> 'CANCELLED'
           AND TO_NUMBER(TO_CHAR(po_date, 'YYYY')) = p_fiscal_year;

        -- NULLIF avoids ORA-01476 (divisor is equal to zero); result is NULL then
        RETURN ROUND(v_po / NULLIF(v_budget, 0) * 100, 2);
    END fn_budget_usage_rate;


    PROCEDURE pr_site_summary (
        p_site_id      IN  site.site_id%TYPE,
        o_contract_amt OUT NUMBER,
        o_po_amt       OUT NUMBER,
        o_budget_amt   OUT NUMBER)
    IS
    BEGIN
        SELECT NVL(SUM(total_amount), 0) INTO o_contract_amt
          FROM contract_hdr WHERE site_id = p_site_id AND status <> 'CANCELLED';

        SELECT NVL(SUM(po_amount), 0) INTO o_po_amt
          FROM purchase_order WHERE site_id = p_site_id AND status <> 'CANCELLED';

        SELECT NVL(SUM(NVL(revised_amount, budget_amount)), 0) INTO o_budget_amt
          FROM budget WHERE site_id = p_site_id;
    END pr_site_summary;


    FUNCTION fn_top_vendor (p_site_id IN site.site_id%TYPE) RETURN VARCHAR2
    IS
        v_vendor contract_hdr.vendor_name%TYPE;
    BEGIN
        -- Classic Oracle top-N: ORDER BY in an inline view, ROWNUM outside.
        -- (WHERE ROWNUM = 1 ... ORDER BY at the same level would be a bug.)
        SELECT vendor_name
          INTO v_vendor
          FROM (SELECT vendor_name, SUM(total_amount) AS amt
                  FROM contract_hdr
                 WHERE site_id = p_site_id
                   AND status IN ('APPROVED','CLOSED')
                 GROUP BY vendor_name
                 ORDER BY amt DESC, vendor_name)
         WHERE ROWNUM = 1;
        RETURN v_vendor;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_top_vendor;


    FUNCTION fn_contract_label (p_contract_id IN contract_hdr.contract_id%TYPE)
        RETURN VARCHAR2
    IS
        v_label VARCHAR2(4000);
    BEGIN
        -- In Oracle  'A' || NULL = 'A'.  In PostgreSQL 'A' || NULL = NULL.
        SELECT contract_no || ' ' || vendor_name || ' ' || remarks
          INTO v_label
          FROM contract_hdr
         WHERE contract_id = p_contract_id;
        RETURN TRIM(v_label);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_contract_label;

END pkg_contract;
/
