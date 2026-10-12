-- SQL*Loader control file: loads data/csv/contract_hdr.csv into ERP.CONTRACT_HDR
-- sqlldr userid=erp/***@//host:1521/FREEPDB1 control=oracle/03_load/contract_hdr.ctl
OPTIONS (SKIP=1, DIRECT=TRUE)
LOAD DATA
CHARACTERSET AL32UTF8
INFILE 'data/csv/contract_hdr.csv'
APPEND
INTO TABLE contract_hdr
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
  contract_id, contract_no, site_id, vendor_name CHAR(800), contract_type,
  contract_date DATE "YYYY-MM-DD HH24:MI:SS", start_date DATE "YYYY-MM-DD HH24:MI:SS", end_date DATE "YYYY-MM-DD HH24:MI:SS", currency,
  total_amount, vat_amount, status, retention_rate, remarks CHAR(16000),
  created_at DATE "YYYY-MM-DD HH24:MI:SS", updated_at DATE "YYYY-MM-DD HH24:MI:SS"
)
