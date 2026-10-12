--------------------------------------------------------------------------------
-- SIMULATED ORACLE SOURCE inside PostgreSQL (schema ora_src)
--
-- No Oracle instance was available in the build environment, so the Oracle
-- source is emulated in its own schema. Types are chosen to keep Oracle's
-- semantics, NOT to be good PostgreSQL design:
--   NUMBER(p,s)  -> numeric(p,s)      (same decimal arithmetic)
--   VARCHAR2(n)  -> varchar(n)
--   CHAR(n)      -> char(n)
--   DATE         -> timestamp(0)      (Oracle DATE = date + time to the second)
--   ''           -> forbidden by CHECK (col <> '') because Oracle turns '' into NULL
--
-- This is exactly the shape oracle_fdw's IMPORT FOREIGN SCHEMA would expose,
-- so migration/02_migrate.sql runs unchanged against real Oracle foreign tables
-- (see migration/oracle_fdw_setup.sql).
--------------------------------------------------------------------------------
DROP SCHEMA IF EXISTS ora_src CASCADE;
CREATE SCHEMA ora_src;
SET search_path = ora_src;

CREATE TABLE site (
    site_id        numeric(10)      NOT NULL PRIMARY KEY,
    site_code      varchar(20)      NOT NULL UNIQUE,
    site_name      varchar(200)     NOT NULL,
    region         varchar(50)      NOT NULL,
    client_name    varchar(200)     CHECK (client_name <> ''),
    start_date     timestamp(0)     NOT NULL,
    end_date       timestamp(0),
    status         char(1)          NOT NULL DEFAULT 'P' CHECK (status IN ('P','A','C')),
    manager_name   varchar(100)     CHECK (manager_name <> ''),
    created_at     timestamp(0)     NOT NULL
);

CREATE TABLE contract_hdr (
    contract_id    numeric(12)      NOT NULL PRIMARY KEY,
    contract_no    varchar(30)      NOT NULL UNIQUE,
    site_id        numeric(10)      NOT NULL REFERENCES site,
    vendor_name    varchar(200)     NOT NULL,
    contract_type  varchar(3)       NOT NULL CHECK (contract_type IN ('SUB','MAT','EQP','SVC')),
    contract_date  timestamp(0)     NOT NULL,
    start_date     timestamp(0),
    end_date       timestamp(0),
    currency       char(3)          NOT NULL DEFAULT 'KRW',
    total_amount   numeric(18,2)    NOT NULL DEFAULT 0,
    vat_amount     numeric(18,2)    NOT NULL DEFAULT 0,
    status         varchar(10)      NOT NULL DEFAULT 'DRAFT'
                   CHECK (status IN ('DRAFT','APPROVED','CLOSED','CANCELLED')),
    retention_rate numeric(5,2),
    remarks        varchar(4000)    CHECK (remarks <> ''),
    created_at     timestamp(0)     NOT NULL,
    updated_at     timestamp(0)
);

CREATE TABLE contract_dtl (
    contract_id    numeric(12)      NOT NULL REFERENCES contract_hdr,
    line_no        numeric(5)       NOT NULL,
    item_code      varchar(30)      NOT NULL,
    item_name      varchar(200)     NOT NULL,
    spec           varchar(200)     CHECK (spec <> ''),
    unit           varchar(10)      NOT NULL,
    quantity       numeric(15,3)    NOT NULL,
    unit_price     numeric(15,2)    NOT NULL,
    amount         numeric(18,2)    NOT NULL,
    cost_code      varchar(20)      NOT NULL,
    PRIMARY KEY (contract_id, line_no)
);

CREATE TABLE purchase_order (
    po_id          numeric(12)      NOT NULL PRIMARY KEY,
    po_no          varchar(30)      NOT NULL UNIQUE,
    site_id        numeric(10)      NOT NULL REFERENCES site,
    contract_id    numeric(12)      REFERENCES contract_hdr,
    vendor_name    varchar(200)     NOT NULL,
    po_date        timestamp(0)     NOT NULL,
    delivery_date  timestamp(0),
    cost_code      varchar(20)      NOT NULL,
    po_amount      numeric(18,2)    NOT NULL,
    status         varchar(10)      NOT NULL DEFAULT 'ISSUED'
                   CHECK (status IN ('ISSUED','RECEIVED','CANCELLED')),
    urgent_yn      char(1)          NOT NULL DEFAULT 'N' CHECK (urgent_yn IN ('Y','N')),
    remarks        varchar(1000)    CHECK (remarks <> ''),
    created_at     timestamp(0)     NOT NULL
);

CREATE TABLE budget (
    budget_id      numeric(12)      NOT NULL PRIMARY KEY,
    site_id        numeric(10)      NOT NULL REFERENCES site,
    fiscal_year    numeric(4)       NOT NULL,
    cost_code      varchar(20)      NOT NULL,
    budget_amount  numeric(18,2)    NOT NULL,
    revised_amount numeric(18,2),
    approved_yn    char(1)          NOT NULL DEFAULT 'N' CHECK (approved_yn IN ('Y','N')),
    created_at     timestamp(0)     NOT NULL,
    UNIQUE (site_id, fiscal_year, cost_code)
);

-- Stand-in for the Oracle data dictionary view USER_SEQUENCES
CREATE TABLE user_sequences (
    sequence_name  varchar(128)     NOT NULL PRIMARY KEY,
    last_number    numeric          NOT NULL
);

RESET search_path;
