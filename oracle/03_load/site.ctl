-- SQL*Loader control file: loads data/csv/site.csv into ERP.SITE
-- sqlldr userid=erp/***@//host:1521/FREEPDB1 control=oracle/03_load/site.ctl
OPTIONS (SKIP=1, DIRECT=TRUE)
LOAD DATA
CHARACTERSET AL32UTF8
INFILE 'data/csv/site.csv'
APPEND
INTO TABLE site
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
  site_id, site_code, site_name CHAR(800), region, client_name CHAR(800),
  start_date DATE "YYYY-MM-DD HH24:MI:SS", end_date DATE "YYYY-MM-DD HH24:MI:SS", status, manager_name CHAR(400), created_at DATE "YYYY-MM-DD HH24:MI:SS"
)
