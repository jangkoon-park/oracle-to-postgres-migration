#!/usr/bin/env bash
# End-to-end demo: generate fictional data -> load simulated Oracle source ->
# create PostgreSQL target -> pre-check -> migrate -> validate -> report.
#
# Requirements: PostgreSQL 14+ (psql on PATH, a role allowed to CREATE DATABASE),
#               Python 3.8+ (standard library only).
# Connection:   standard libpq env vars (PGHOST, PGPORT, PGUSER, PGPASSWORD).
# Usage:        ./run_demo.sh            # database name defaults to erp_migration_demo
#               DB=mydb ./run_demo.sh
set -euo pipefail
cd "$(dirname "$0")"

DB="${DB:-erp_migration_demo}"
OUT=results
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")
mkdir -p "$OUT"
LOG="$OUT/run_output.log"
: > "$LOG"

step() { printf '\n==> %s\n' "$*" | tee -a "$LOG"; }

step "1/8 Generate fictional data (deterministic seed)"
python3 data/generate_data.py --out data/csv | tee -a "$LOG"

step "2/8 Create database $DB"
dropdb --if-exists "$DB" >>"$LOG" 2>&1
createdb -E UTF8 -T template0 "$DB"

step "3/8 Simulated Oracle source: schema ora_src + load CSV"
"${PSQL[@]}" -f simulation/01_ora_src_schema.sql >>"$LOG" 2>&1
"${PSQL[@]}" -f simulation/02_load_source.sql    >>"$LOG" 2>&1

step "4/8 PostgreSQL target: schema erp + converted PL/pgSQL (pkg_contract)"
"${PSQL[@]}" -f postgres/01_schema.sql      >>"$LOG" 2>&1
"${PSQL[@]}" -f postgres/02_pkg_contract.sql >>"$LOG" 2>&1

step "5/8 Pre-migration checks"
"${PSQL[@]}" -f migration/01_precheck.sql | tee -a "$LOG"

step "6/8 Migrate data"
START=$(date +%s.%N)
"${PSQL[@]}" -f migration/02_migrate.sql 2>&1 | tee -a "$LOG"
END=$(date +%s.%N)
MIGRATE_SECONDS=$(python3 -c "print(f'{$END-$START:.2f}')")

step "7/8 Validate"
"${PSQL[@]}" -f validation/01_checks.sql >>"$LOG" 2>&1
"${PSQL[@]}" --csv -c "SELECT * FROM mig_check.run_all()"                 > "$OUT/validation_results.csv"
"${PSQL[@]}" --csv -c "SELECT * FROM mig_check.site_totals ORDER BY site_id" > "$OUT/site_totals.csv"
"${PSQL[@]}" --csv -f validation/02_test_procedures.sql | grep -v -E '^(BEGIN|ROLLBACK|DO|CREATE TABLE)$' > "$OUT/procedure_tests.csv"
"${PSQL[@]}" --csv -f validation/03_negative_test.sql   | grep -v -E '^(BEGIN|ROLLBACK|DELETE [0-9]+|UPDATE [0-9]+)$' > "$OUT/negative_test.csv"

step "8/8 Report"
{
  echo "run at        : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "postgresql    : $("${PSQL[@]}" -Atc 'SHOW server_version')"
  echo "python        : $(python3 --version 2>&1)"
  echo "source rows   : $("${PSQL[@]}" -Atc "SELECT (SELECT count(*) FROM ora_src.site)+(SELECT count(*) FROM ora_src.contract_hdr)+(SELECT count(*) FROM ora_src.contract_dtl)+(SELECT count(*) FROM ora_src.purchase_order)+(SELECT count(*) FROM ora_src.budget)")"
  echo "migrate step  : ${MIGRATE_SECONDS}s (wall clock, incl. psql start-up and ANALYZE)"
} > "$OUT/environment.txt"
python3 validation/report.py "$OUT" | tee -a "$LOG"
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') run finished" >> "$OUT/run_history.txt"

FAILS=$(cat "$OUT/validation_results.csv" "$OUT/procedure_tests.csv" | { grep -c ',FAIL$' || true; })
if [ "$FAILS" -ne 0 ]; then
  echo "!! $FAILS check(s) failed - see $OUT/validation_report.md" | tee -a "$LOG"
  exit 1
fi
echo "All checks passed - see $OUT/validation_report.md" | tee -a "$LOG"
