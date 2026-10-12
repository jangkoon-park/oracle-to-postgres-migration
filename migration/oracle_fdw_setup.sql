--------------------------------------------------------------------------------
-- REAL-ORACLE PATH (not executed in this demo - no Oracle instance available).
--
-- Replaces simulation/*.sql: instead of a local copy, ora_src becomes a set of
-- oracle_fdw foreign tables pointing at the live Oracle ERP schema. After this,
-- migration/01_precheck.sql, 02_migrate.sql and validation/*.sql run unchanged.
--
-- Requires: oracle_fdw extension + Oracle Instant Client on the PostgreSQL host.
--------------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS oracle_fdw;

CREATE SERVER erp_oracle FOREIGN DATA WRAPPER oracle_fdw
    OPTIONS (dbserver '//oracle-host:1521/ERPPDB', isolation_level 'read_only');

CREATE USER MAPPING FOR CURRENT_USER SERVER erp_oracle
    OPTIONS (user 'ERP_READONLY', password :'oracle_password');   -- psql -v oracle_password=...

DROP SCHEMA IF EXISTS ora_src CASCADE;
CREATE SCHEMA ora_src;

-- case 'smart' folds the upper-case Oracle names to lower case.
-- oracle_fdw maps Oracle DATE -> timestamp, NUMBER(p,s) -> numeric(p,s),
-- VARCHAR2 -> varchar: the same shape as simulation/01_ora_src_schema.sql.
IMPORT FOREIGN SCHEMA "ERP"
    LIMIT TO (SITE, CONTRACT_HDR, CONTRACT_DTL, PURCHASE_ORDER, BUDGET)
    FROM SERVER erp_oracle INTO ora_src
    OPTIONS (case 'smart', readonly 'true');

-- Oracle data dictionary view used to restart identity columns
CREATE FOREIGN TABLE ora_src.user_sequences (
    sequence_name varchar(128),
    last_number   numeric
) SERVER erp_oracle OPTIONS (table 'USER_SEQUENCES');

-- Tip: for big tables run 02_migrate.sql per table/partition in parallel sessions
-- and raise oracle_fdw's 'prefetch' option (e.g. ALTER FOREIGN TABLE ... OPTIONS (ADD prefetch '1000')).
