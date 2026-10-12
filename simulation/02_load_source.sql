--------------------------------------------------------------------------------
-- Load the fictional CSV extract into the simulated Oracle source (ora_src).
-- Plays the role of oracle/03_load/*.ctl (SQL*Loader) in the real setup.
-- Run from the repository root (paths are relative): psql -f simulation/02_load_source.sql
--------------------------------------------------------------------------------
\set ON_ERROR_STOP on
BEGIN;
TRUNCATE ora_src.purchase_order, ora_src.contract_dtl, ora_src.contract_hdr,
         ora_src.budget, ora_src.site, ora_src.user_sequences;

-- In CSV mode an empty unquoted field is NULL -> same as Oracle's '' handling.
\copy ora_src.site           FROM 'data/csv/site.csv'           WITH (FORMAT csv, HEADER true)
\copy ora_src.contract_hdr   FROM 'data/csv/contract_hdr.csv'   WITH (FORMAT csv, HEADER true)
\copy ora_src.contract_dtl   FROM 'data/csv/contract_dtl.csv'   WITH (FORMAT csv, HEADER true)
\copy ora_src.purchase_order FROM 'data/csv/purchase_order.csv' WITH (FORMAT csv, HEADER true)
\copy ora_src.budget         FROM 'data/csv/budget.csv'         WITH (FORMAT csv, HEADER true)
\copy ora_src.user_sequences FROM 'data/csv/user_sequences.csv' WITH (FORMAT csv, HEADER true)
COMMIT;

ANALYZE ora_src.site, ora_src.contract_hdr, ora_src.contract_dtl,
        ora_src.purchase_order, ora_src.budget;
