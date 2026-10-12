--------------------------------------------------------------------------------
-- Behaviour tests for the converted procedures (status change, recalculation,
-- error codes, Oracle '' / NULL semantics, identity restart).
-- Everything runs inside one transaction that is ROLLED BACK at the end, so the
-- migrated data is left untouched.
--------------------------------------------------------------------------------
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE test_result (
    test_no   serial,
    test_name text,
    expected  text,
    actual    text,
    status    text GENERATED ALWAYS AS (CASE WHEN expected IS NOT DISTINCT FROM actual THEN 'PASS' ELSE 'FAIL' END) STORED
);

DO $$
DECLARE
    v_id     bigint;
    v_txt    text;
    v_sum    numeric;
    v_state  text;
    v_last   numeric;
BEGIN
    -- T1: pr_recalc_contract_total repairs a wrong header total -------------
    SELECT contract_id INTO v_id FROM erp.contract_hdr h
     WHERE EXISTS (SELECT 1 FROM erp.contract_dtl d WHERE d.contract_id = h.contract_id)
     ORDER BY contract_id LIMIT 1;
    SELECT sum(amount) INTO v_sum FROM erp.contract_dtl WHERE contract_id = v_id;
    UPDATE erp.contract_hdr SET total_amount = 0, vat_amount = 0 WHERE contract_id = v_id;
    CALL pkg_contract.pr_recalc_contract_total(v_id);
    INSERT INTO test_result (test_name, expected, actual)
    SELECT 'pr_recalc_contract_total: total & 10% VAT rebuilt from lines',
           v_sum || ' / ' || round(v_sum * 0.1)::numeric(18,2), total_amount || ' / ' || vat_amount
      FROM erp.contract_hdr WHERE contract_id = v_id;

    -- T2: unknown contract -> custom SQLSTATE (was ORA-20010) --------------
    BEGIN
        CALL pkg_contract.pr_recalc_contract_total(-1);
        v_state := 'no error';
    EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE;
    END;
    INSERT INTO test_result (test_name, expected, actual)
    VALUES ('pr_recalc_contract_total: unknown id raises CT010 (ORA-20010)', 'CT010', v_state);

    -- T3: DRAFT -> APPROVED (contract with lines) --------------------------
    SELECT contract_id INTO v_id FROM erp.contract_hdr h
     WHERE status = 'DRAFT'
       AND EXISTS (SELECT 1 FROM erp.contract_dtl d WHERE d.contract_id = h.contract_id)
     ORDER BY contract_id LIMIT 1;
    CALL pkg_contract.pr_change_contract_status(v_id, 'APPROVED');
    INSERT INTO test_result (test_name, expected, actual)
    SELECT 'pr_change_contract_status: DRAFT -> APPROVED', 'APPROVED', status
      FROM erp.contract_hdr WHERE contract_id = v_id;

    -- T4: DRAFT without lines -> APPROVED is rejected, status unchanged -----
    SELECT contract_id INTO v_id FROM erp.contract_hdr h
     WHERE status = 'DRAFT'
       AND NOT EXISTS (SELECT 1 FROM erp.contract_dtl d WHERE d.contract_id = h.contract_id)
     ORDER BY contract_id LIMIT 1;
    BEGIN
        CALL pkg_contract.pr_change_contract_status(v_id, 'APPROVED');
        v_state := 'no error';
    EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE;
    END;
    INSERT INTO test_result (test_name, expected, actual)
    SELECT 'pr_change_contract_status: approve empty contract -> CT021, still DRAFT',
           'CT021 / DRAFT', v_state || ' / ' || status
      FROM erp.contract_hdr WHERE contract_id = v_id;

    -- T5: CLOSED -> APPROVED is an invalid transition ----------------------
    SELECT contract_id INTO v_id FROM erp.contract_hdr WHERE status = 'CLOSED' ORDER BY contract_id LIMIT 1;
    BEGIN
        CALL pkg_contract.pr_change_contract_status(v_id, 'APPROVED');
        v_state := 'no error';
    EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE;
    END;
    INSERT INTO test_result (test_name, expected, actual)
    VALUES ('pr_change_contract_status: CLOSED -> APPROVED raises CT020', 'CT020', v_state);

    -- T6: APPROVED -> CANCELLED cancels the contract's ISSUED purchase orders
    SELECT h.contract_id INTO v_id FROM erp.contract_hdr h
     WHERE h.status = 'APPROVED' AND h.remarks IS NULL
       AND EXISTS (SELECT 1 FROM erp.purchase_order p WHERE p.contract_id = h.contract_id AND p.status = 'ISSUED')
     ORDER BY h.contract_id LIMIT 1;
    CALL pkg_contract.pr_change_contract_status(v_id, 'CANCELLED', 'Client withdrew');
    INSERT INTO test_result (test_name, expected, actual)
    SELECT 'pr_change_contract_status: cancel cascades to ISSUED POs', '0 ISSUED POs left',
           count(*) FILTER (WHERE status = 'ISSUED') || ' ISSUED POs left'
      FROM erp.purchase_order WHERE contract_id = v_id;

    -- T7: NULL remarks || reason must not become NULL (Oracle '||' semantics)
    INSERT INTO test_result (test_name, expected, actual)
    SELECT 'NVL2/|| : NULL remarks + reason keeps the reason text',
           ' [CANCELLED] Client withdrew', remarks
      FROM erp.contract_hdr WHERE contract_id = v_id;

    -- T8: '' passed as reason behaves like Oracle NULL (remarks unchanged) --
    SELECT contract_id, remarks INTO v_id, v_txt FROM erp.contract_hdr
     WHERE status = 'APPROVED' AND remarks IS NOT NULL ORDER BY contract_id LIMIT 1;
    CALL pkg_contract.pr_change_contract_status(v_id, 'CLOSED', '');
    INSERT INTO test_result (test_name, expected, actual)
    SELECT 'Empty-string reason treated as NULL (remarks unchanged)', v_txt, remarks
      FROM erp.contract_hdr WHERE contract_id = v_id;

    -- T9: new rows get IDs beyond Oracle's sequence high-water mark ---------
    SELECT last_number INTO v_last FROM ora_src.user_sequences WHERE sequence_name = 'CONTRACT_SEQ';
    INSERT INTO erp.contract_hdr (contract_no, site_id, vendor_name, contract_type, contract_date)
    VALUES ('CT-TEST-000001', (SELECT min(site_id) FROM erp.site), 'Test Vendor Co., Ltd.', 'SVC', DATE '2026-10-12')
    RETURNING contract_id INTO v_id;
    INSERT INTO test_result (test_name, expected, actual)
    VALUES ('IDENTITY: first new contract_id = Oracle CONTRACT_SEQ.LAST_NUMBER',
            v_last::text, v_id::text);
END $$;

SELECT test_no, test_name, expected, actual, status FROM test_result ORDER BY test_no;

ROLLBACK;
