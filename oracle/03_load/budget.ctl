-- SQL*Loader control file: loads data/csv/budget.csv into ERP.BUDGET
-- sqlldr userid=erp/***@//host:1521/FREEPDB1 control=oracle/03_load/budget.ctl
OPTIONS (SKIP=1, DIRECT=TRUE)
LOAD DATA
CHARACTERSET AL32UTF8
INFILE 'data/csv/budget.csv'
APPEND
INTO TABLE budget
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
  budget_id, site_id, fiscal_year, cost_code, budget_amount, revised_amount,
  approved_yn, created_at DATE "YYYY-MM-DD HH24:MI:SS"
)
