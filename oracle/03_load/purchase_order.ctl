-- SQL*Loader control file: loads data/csv/purchase_order.csv into ERP.PURCHASE_ORDER
-- sqlldr userid=erp/***@//host:1521/FREEPDB1 control=oracle/03_load/purchase_order.ctl
OPTIONS (SKIP=1, DIRECT=TRUE)
LOAD DATA
CHARACTERSET AL32UTF8
INFILE 'data/csv/purchase_order.csv'
APPEND
INTO TABLE purchase_order
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
  po_id, po_no, site_id, contract_id, vendor_name CHAR(800),
  po_date DATE "YYYY-MM-DD HH24:MI:SS", delivery_date DATE "YYYY-MM-DD HH24:MI:SS", cost_code, po_amount, status, urgent_yn,
  remarks CHAR(4000), created_at DATE "YYYY-MM-DD HH24:MI:SS"
)
