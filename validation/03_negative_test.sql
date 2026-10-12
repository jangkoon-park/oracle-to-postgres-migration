--------------------------------------------------------------------------------
-- Negative test: proves the checks actually catch typical migration defects.
-- Three defects are injected into the target, mig_check.run_all() is executed,
-- and everything is ROLLED BACK.
--   D1  one purchase order lost                     (e.g. failed batch)
--   D2  NULL spec written as ''                     (naive NVL(spec,'') port)
--   D3  one line amount off by 0.01                 (float / rounding bug)
--------------------------------------------------------------------------------
\set ON_ERROR_STOP on
BEGIN;

DELETE FROM erp.purchase_order
 WHERE po_id = (SELECT max(po_id) FROM erp.purchase_order);                     -- D1

UPDATE erp.contract_dtl SET spec = ''
 WHERE (contract_id, line_no) = (SELECT contract_id, line_no FROM erp.contract_dtl
                                  WHERE spec IS NULL ORDER BY 1, 2 LIMIT 1);    -- D2

UPDATE erp.contract_dtl SET amount = amount + 0.01
 WHERE (contract_id, line_no) = (SELECT contract_id, line_no FROM erp.contract_dtl
                                  ORDER BY 1 DESC, 2 LIMIT 1);                  -- D3

SELECT check_no, category, check_name, source_value, target_value, detail, status
  FROM mig_check.run_all()
 WHERE status = 'FAIL';

ROLLBACK;
