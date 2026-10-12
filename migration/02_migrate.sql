--------------------------------------------------------------------------------
-- Data migration ora_src (Oracle, via oracle_fdw or the simulation) -> erp
--
-- * one transaction: either everything is migrated or nothing is
-- * parent -> child order so every FK stays enabled and is checked
-- * idempotent: target tables are truncated first, so it can be re-run
-- * identity columns restart from the Oracle sequence high-water mark
--------------------------------------------------------------------------------
\set ON_ERROR_STOP on
\timing on
BEGIN;

TRUNCATE erp.purchase_order, erp.contract_dtl, erp.contract_hdr, erp.budget, erp.site;

-- OVERRIDING SYSTEM VALUE is not needed for BY DEFAULT identities, but it makes
-- the intent explicit: keep the Oracle primary keys unchanged.
INSERT INTO erp.site (site_id, site_code, site_name, region, client_name,
                      start_date, end_date, status, manager_name, created_at)
OVERRIDING SYSTEM VALUE
SELECT site_id::bigint,
       site_code, site_name, region, client_name,
       start_date::date,                    -- DATE -> date  (pre-check: no time part)
       end_date::date,
       rtrim(status),                       -- CHAR(1) -> varchar(1)
       manager_name,
       created_at                           -- DATE -> timestamp(0), unchanged
  FROM ora_src.site;

INSERT INTO erp.contract_hdr (contract_id, contract_no, site_id, vendor_name, contract_type,
                              contract_date, start_date, end_date, currency,
                              total_amount, vat_amount, status, retention_rate, remarks,
                              created_at, updated_at)
OVERRIDING SYSTEM VALUE
SELECT contract_id::bigint, contract_no, site_id::bigint, vendor_name, contract_type,
       contract_date::date, start_date::date, end_date::date, currency,
       total_amount, vat_amount, status, retention_rate, remarks,
       created_at, updated_at
  FROM ora_src.contract_hdr;

INSERT INTO erp.contract_dtl (contract_id, line_no, item_code, item_name, spec, unit,
                              quantity, unit_price, amount, cost_code)
SELECT contract_id::bigint, line_no::integer, item_code, item_name, spec, unit,
       quantity, unit_price, amount, cost_code
  FROM ora_src.contract_dtl;

INSERT INTO erp.purchase_order (po_id, po_no, site_id, contract_id, vendor_name, po_date,
                                delivery_date, cost_code, po_amount, status, is_urgent,
                                remarks, created_at)
OVERRIDING SYSTEM VALUE
SELECT po_id::bigint, po_no, site_id::bigint, contract_id::bigint, vendor_name, po_date::date,
       delivery_date::date, cost_code, po_amount, status,
       (urgent_yn = 'Y'),                   -- CHAR(1) 'Y'/'N' -> boolean
       remarks, created_at
  FROM ora_src.purchase_order;

INSERT INTO erp.budget (budget_id, site_id, fiscal_year, cost_code, budget_amount,
                        revised_amount, is_approved, created_at)
OVERRIDING SYSTEM VALUE
SELECT budget_id::bigint, site_id::bigint, fiscal_year::smallint, cost_code, budget_amount,
       revised_amount, (approved_yn = 'Y'), created_at
  FROM ora_src.budget;

-- Sequences: restart each identity at Oracle's USER_SEQUENCES.LAST_NUMBER
-- (never at max(id)+1 only: cached Oracle values may already be used by
-- interfaces/logs, so take the greater of both).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES ('erp.site',           'site_id',     'SITE_SEQ'),
                              ('erp.contract_hdr',   'contract_id', 'CONTRACT_SEQ'),
                              ('erp.purchase_order', 'po_id',       'PO_SEQ'),
                              ('erp.budget',         'budget_id',   'BUDGET_SEQ')) v(tbl, col, seq)
    LOOP
        EXECUTE format(
            'SELECT setval(pg_get_serial_sequence(%L, %L),
                           GREATEST((SELECT COALESCE(max(%I), 0) + 1 FROM %s),
                                    (SELECT last_number FROM ora_src.user_sequences WHERE sequence_name = %L))::bigint,
                           false)',
            r.tbl, r.col, r.col, r.tbl, r.seq);
        RAISE NOTICE 'identity %.% restarted from Oracle %', r.tbl, r.col, r.seq;
    END LOOP;
END $$;

COMMIT;
\timing off

ANALYZE erp.site, erp.contract_hdr, erp.contract_dtl, erp.purchase_order, erp.budget;

