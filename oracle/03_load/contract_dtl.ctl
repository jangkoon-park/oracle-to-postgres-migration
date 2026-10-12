-- SQL*Loader control file: loads data/csv/contract_dtl.csv into ERP.CONTRACT_DTL
-- sqlldr userid=erp/***@//host:1521/FREEPDB1 control=oracle/03_load/contract_dtl.ctl
OPTIONS (SKIP=1, DIRECT=TRUE)
LOAD DATA
CHARACTERSET AL32UTF8
INFILE 'data/csv/contract_dtl.csv'
APPEND
INTO TABLE contract_dtl
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
  contract_id, line_no, item_code, item_name CHAR(800), spec CHAR(800), unit,
  quantity, unit_price, amount, cost_code
)
