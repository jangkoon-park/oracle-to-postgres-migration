--------------------------------------------------------------------------------
-- Pre-migration data profiling against the source (ora_src).
-- Each check guards a lossy or failing conversion in 02_migrate.sql.
-- Any non-zero count aborts the run (ON_ERROR_STOP + RAISE).
--------------------------------------------------------------------------------
\set ON_ERROR_STOP on

CREATE TEMP TABLE precheck AS
SELECT * FROM (VALUES
  -- DATE -> date is only lossless when the time part is 00:00:00
  ('site.start_date has time part',          (SELECT count(*) FROM ora_src.site WHERE start_date <> date_trunc('day', start_date))),
  ('site.end_date has time part',            (SELECT count(*) FROM ora_src.site WHERE end_date <> date_trunc('day', end_date))),
  ('contract_hdr.contract_date has time',    (SELECT count(*) FROM ora_src.contract_hdr WHERE contract_date <> date_trunc('day', contract_date))),
  ('contract_hdr.start/end_date has time',   (SELECT count(*) FROM ora_src.contract_hdr WHERE start_date <> date_trunc('day', start_date) OR end_date <> date_trunc('day', end_date))),
  ('purchase_order.po/delivery has time',    (SELECT count(*) FROM ora_src.purchase_order WHERE po_date <> date_trunc('day', po_date) OR delivery_date <> date_trunc('day', delivery_date))),
  -- CHAR(1) Y/N -> boolean
  ('purchase_order.urgent_yn not Y/N',       (SELECT count(*) FROM ora_src.purchase_order WHERE urgent_yn NOT IN ('Y','N'))),
  ('budget.approved_yn not Y/N',             (SELECT count(*) FROM ora_src.budget WHERE approved_yn NOT IN ('Y','N'))),
  -- NUMBER(4) fiscal_year -> smallint, NUMBER(5) line_no -> integer: integral values only
  ('budget.fiscal_year not integral',        (SELECT count(*) FROM ora_src.budget WHERE fiscal_year <> trunc(fiscal_year))),
  -- remarks VARCHAR2(4000 CHAR) -> text + CHECK(char_length <= 4000)
  ('contract_hdr.remarks > 4000 chars',      (SELECT count(*) FROM ora_src.contract_hdr WHERE char_length(remarks) > 4000)),
  -- orphan rows would break the FKs that are enabled on the target
  ('purchase_order orphan contract_id',      (SELECT count(*) FROM ora_src.purchase_order p WHERE p.contract_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ora_src.contract_hdr h WHERE h.contract_id = p.contract_id))),
  -- whitespace-only strings: Oracle keeps ' ' (not NULL); flag for business review
  ('whitespace-only remarks/spec',           (SELECT count(*) FROM ora_src.contract_dtl WHERE spec ~ '^\s+$') +
                                             (SELECT count(*) FROM ora_src.contract_hdr WHERE remarks ~ '^\s+$'))
) AS t(check_name, bad_rows);

SELECT check_name, bad_rows, CASE WHEN bad_rows = 0 THEN 'OK' ELSE 'BLOCKER' END AS result
  FROM precheck;

DO $$
DECLARE n bigint;
BEGIN
    SELECT sum(bad_rows) INTO n FROM precheck;
    IF n > 0 THEN
        RAISE EXCEPTION 'Pre-check failed: % offending rows - fix mapping before migrating', n;
    END IF;
END $$;
