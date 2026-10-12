--------------------------------------------------------------------------------
-- Source system : "BuildCo ERP" (fictional construction company)
-- Database      : Oracle 11g/12c+ (legacy style: sequences + BEFORE INSERT triggers)
-- Schema owner  : ERP
-- Purpose       : Contract management module - the SOURCE side of the migration.
--
-- NOTE: This file is provided as the Oracle source of truth. It was NOT executed
--       against a live Oracle instance in this demo environment (see README).
--------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Sequences
-- ---------------------------------------------------------------------------
CREATE SEQUENCE site_seq      START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE contract_seq  START WITH 1 INCREMENT BY 1 CACHE 20 NOCYCLE;
CREATE SEQUENCE po_seq        START WITH 1 INCREMENT BY 1 CACHE 20 NOCYCLE;
CREATE SEQUENCE budget_seq    START WITH 1 INCREMENT BY 1 CACHE 20 NOCYCLE;

-- ---------------------------------------------------------------------------
-- SITE : construction site (현장)
-- ---------------------------------------------------------------------------
CREATE TABLE site (
    site_id        NUMBER(10)          NOT NULL,
    site_code      VARCHAR2(20)        NOT NULL,
    site_name      VARCHAR2(200 CHAR)  NOT NULL,
    region         VARCHAR2(50)        NOT NULL,
    client_name    VARCHAR2(200 CHAR),
    start_date     DATE                NOT NULL,
    end_date       DATE,
    status         CHAR(1)             DEFAULT 'P' NOT NULL,   -- P=Planned, A=Active, C=Closed
    manager_name   VARCHAR2(100 CHAR),
    created_at     DATE                DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_site        PRIMARY KEY (site_id),
    CONSTRAINT uk_site_code   UNIQUE (site_code),
    CONSTRAINT ck_site_status CHECK (status IN ('P','A','C'))
);

-- ---------------------------------------------------------------------------
-- CONTRACT_HDR : contract header (계약 헤더)
-- ---------------------------------------------------------------------------
CREATE TABLE contract_hdr (
    contract_id    NUMBER(12)          NOT NULL,
    contract_no    VARCHAR2(30)        NOT NULL,
    site_id        NUMBER(10)          NOT NULL,
    vendor_name    VARCHAR2(200 CHAR)  NOT NULL,
    contract_type  VARCHAR2(3)         NOT NULL,                -- SUB/MAT/EQP/SVC
    contract_date  DATE                NOT NULL,
    start_date     DATE,
    end_date       DATE,
    currency       CHAR(3)             DEFAULT 'KRW' NOT NULL,
    total_amount   NUMBER(18,2)        DEFAULT 0 NOT NULL,      -- sum of CONTRACT_DTL.amount
    vat_amount     NUMBER(18,2)        DEFAULT 0 NOT NULL,
    status         VARCHAR2(10)        DEFAULT 'DRAFT' NOT NULL,
    retention_rate NUMBER(5,2),                                 -- e.g. 5.00 (%)
    remarks        VARCHAR2(4000 CHAR),
    created_at     DATE                DEFAULT SYSDATE NOT NULL,
    updated_at     DATE,
    CONSTRAINT pk_contract_hdr    PRIMARY KEY (contract_id),
    CONSTRAINT uk_contract_no     UNIQUE (contract_no),
    CONSTRAINT fk_contract_site   FOREIGN KEY (site_id) REFERENCES site (site_id),
    CONSTRAINT ck_contract_type   CHECK (contract_type IN ('SUB','MAT','EQP','SVC')),
    CONSTRAINT ck_contract_status CHECK (status IN ('DRAFT','APPROVED','CLOSED','CANCELLED'))
);
CREATE INDEX ix_contract_hdr_site ON contract_hdr (site_id);

-- ---------------------------------------------------------------------------
-- CONTRACT_DTL : contract line items (계약 상세 내역)
-- ---------------------------------------------------------------------------
CREATE TABLE contract_dtl (
    contract_id    NUMBER(12)          NOT NULL,
    line_no        NUMBER(5)           NOT NULL,
    item_code      VARCHAR2(30)        NOT NULL,
    item_name      VARCHAR2(200 CHAR)  NOT NULL,
    spec           VARCHAR2(200 CHAR),                          -- '' is stored as NULL by Oracle
    unit           VARCHAR2(10)        NOT NULL,
    quantity       NUMBER(15,3)        NOT NULL,
    unit_price     NUMBER(15,2)        NOT NULL,
    amount         NUMBER(18,2)        NOT NULL,
    cost_code      VARCHAR2(20)        NOT NULL,
    CONSTRAINT pk_contract_dtl     PRIMARY KEY (contract_id, line_no),
    CONSTRAINT fk_contract_dtl_hdr FOREIGN KEY (contract_id) REFERENCES contract_hdr (contract_id)
);

-- ---------------------------------------------------------------------------
-- PURCHASE_ORDER : purchase orders (발주)
-- ---------------------------------------------------------------------------
CREATE TABLE purchase_order (
    po_id          NUMBER(12)          NOT NULL,
    po_no          VARCHAR2(30)        NOT NULL,
    site_id        NUMBER(10)          NOT NULL,
    contract_id    NUMBER(12),                                  -- NULL = spot purchase
    vendor_name    VARCHAR2(200 CHAR)  NOT NULL,
    po_date        DATE                NOT NULL,
    delivery_date  DATE,
    cost_code      VARCHAR2(20)        NOT NULL,
    po_amount      NUMBER(18,2)        NOT NULL,
    status         VARCHAR2(10)        DEFAULT 'ISSUED' NOT NULL,
    urgent_yn      CHAR(1)             DEFAULT 'N' NOT NULL,
    remarks        VARCHAR2(1000 CHAR),
    created_at     DATE                DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_purchase_order   PRIMARY KEY (po_id),
    CONSTRAINT uk_po_no            UNIQUE (po_no),
    CONSTRAINT fk_po_site          FOREIGN KEY (site_id)     REFERENCES site (site_id),
    CONSTRAINT fk_po_contract      FOREIGN KEY (contract_id) REFERENCES contract_hdr (contract_id),
    CONSTRAINT ck_po_status        CHECK (status IN ('ISSUED','RECEIVED','CANCELLED')),
    CONSTRAINT ck_po_urgent        CHECK (urgent_yn IN ('Y','N'))
);
CREATE INDEX ix_po_site     ON purchase_order (site_id);
CREATE INDEX ix_po_contract ON purchase_order (contract_id);

-- ---------------------------------------------------------------------------
-- BUDGET : execution budget per site / fiscal year / cost code (예산)
-- ---------------------------------------------------------------------------
CREATE TABLE budget (
    budget_id      NUMBER(12)          NOT NULL,
    site_id        NUMBER(10)          NOT NULL,
    fiscal_year    NUMBER(4)           NOT NULL,
    cost_code      VARCHAR2(20)        NOT NULL,
    budget_amount  NUMBER(18,2)        NOT NULL,
    revised_amount NUMBER(18,2),                                -- NULL = never revised
    approved_yn    CHAR(1)             DEFAULT 'N' NOT NULL,
    created_at     DATE                DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_budget       PRIMARY KEY (budget_id),
    CONSTRAINT uk_budget       UNIQUE (site_id, fiscal_year, cost_code),
    CONSTRAINT fk_budget_site  FOREIGN KEY (site_id) REFERENCES site (site_id),
    CONSTRAINT ck_budget_appr  CHECK (approved_yn IN ('Y','N'))
);

-- ---------------------------------------------------------------------------
-- Legacy ID triggers (pre-12c pattern; replaced by IDENTITY in PostgreSQL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_site_bi
BEFORE INSERT ON site FOR EACH ROW
WHEN (new.site_id IS NULL)
BEGIN
    SELECT site_seq.NEXTVAL INTO :new.site_id FROM dual;
END;
/

CREATE OR REPLACE TRIGGER trg_contract_hdr_bi
BEFORE INSERT ON contract_hdr FOR EACH ROW
WHEN (new.contract_id IS NULL)
BEGIN
    :new.contract_id := contract_seq.NEXTVAL;
END;
/

CREATE OR REPLACE TRIGGER trg_po_bi
BEFORE INSERT ON purchase_order FOR EACH ROW
WHEN (new.po_id IS NULL)
BEGIN
    :new.po_id := po_seq.NEXTVAL;
END;
/

CREATE OR REPLACE TRIGGER trg_budget_bi
BEFORE INSERT ON budget FOR EACH ROW
WHEN (new.budget_id IS NULL)
BEGIN
    :new.budget_id := budget_seq.NEXTVAL;
END;
/
