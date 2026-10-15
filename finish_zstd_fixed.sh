#!/usr/bin/env bash
set -euo pipefail

# Run from the project directory containing docker-compose.yml.
if [[ ! -f docker-compose.yml ]]; then
  echo 'ERROR: Run this script from ~/lakehouse-lab1.' >&2
  exit 1
fi

sql() {
  docker compose exec -T trino trino --output-format TSV --execute "$1"
}

zsql() {
  docker compose exec -T trino trino \
    --session task_concurrency=1 \
    --session iceberg.compression_codec=ZSTD \
    --output-format TSV --execute "$1"
}

wait_trino() {
  local attempt
  for attempt in {1..60}; do
    if sql 'SELECT 1' >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  echo 'ERROR: Trino is not ready. Check docker compose logs trino.' >&2
  exit 1
}

get_count() {
  local out
  if ! out=$(sql "$1"); then
    echo "ERROR: SQL failed: $1" >&2
    exit 1
  fi
  out=${out//$'\r'/}
  out=${out//$'\n'/}
  [[ "$out" =~ ^[0-9]+$ ]] || { echo "ERROR: unexpected count: $out" >&2; exit 1; }
  printf '%s' "$out"
}

restart_trino() {
  echo 'Restarting Trino to free JVM memory...'
  docker compose restart trino >/dev/null
  wait_trino
}

wait_trino
schema=$(sql 'SHOW SCHEMAS FROM iceberg' | tr -d '"')
if ! grep -qx bronze_zstd <<< "$schema"; then
  sql 'CREATE SCHEMA iceberg.bronze_zstd'
fi

for table in customer orders; do
  if ! sql "SHOW TABLES FROM iceberg.bronze_zstd" | tr -d '"' | grep -qx "$table"; then
    echo "Creating ZSTD $table..."
    zsql "CREATE TABLE iceberg.bronze_zstd.$table WITH (format = 'PARQUET') AS SELECT * FROM tpch.sf1.$table"
    restart_trino
  else
    echo "ZSTD $table already exists, checking row count..."
  fi
  expected=$(get_count "SELECT count(*) FROM tpch.sf1.$table")
  current=$(get_count "SELECT count(*) FROM iceberg.bronze_zstd.$table")
  [[ "$current" == "$expected" ]] || { echo "ERROR: $table has $current rows; expected $expected" >&2; exit 1; }
  echo "$table: $current rows OK"
done

if ! sql 'SHOW TABLES FROM iceberg.bronze_zstd' | tr -d '"' | grep -qx lineitem; then
  echo 'Creating empty ZSTD lineitem table...'
  zsql "CREATE TABLE iceberg.bronze_zstd.lineitem WITH (format = 'PARQUET') AS SELECT * FROM tpch.sf1.lineitem WHERE false"
fi

bounds=(0 1500000 3000000 4500000 6000000 7500000)
for ((i=0; i<${#bounds[@]}-1; i++)); do
  lo=${bounds[i]}
  hi=${bounds[i+1]}
  predicate="orderkey >= $lo AND orderkey < $hi"
  current=$(get_count "SELECT count(*) FROM iceberg.bronze_zstd.lineitem WHERE $predicate")
  expected=$(get_count "SELECT count(*) FROM tpch.sf1.lineitem WHERE $predicate")
  echo "range [$lo,$hi): $current / $expected rows"
  if [[ "$current" == "$expected" ]]; then
    continue
  fi
  if [[ "$current" != 0 ]]; then
    echo "ERROR: Partial range [$lo,$hi) found; stopping to avoid duplicates." >&2
    exit 1
  fi
  zsql "INSERT INTO iceberg.bronze_zstd.lineitem SELECT * FROM tpch.sf1.lineitem WHERE $predicate"
  actual=$(get_count "SELECT count(*) FROM iceberg.bronze_zstd.lineitem WHERE $predicate")
  [[ "$actual" == "$expected" ]] || { echo "ERROR: mismatch after insert in [$lo,$hi)" >&2; exit 1; }
  restart_trino
done

final=$(get_count 'SELECT count(*) FROM iceberg.bronze_zstd.lineitem')
[[ "$final" == 6001215 ]] || { echo "ERROR: lineitem $final rows, expected 6001215" >&2; exit 1; }

echo '=== Total size of active Parquet data files, MiB ==='
for codec in bronze bronze_zstd; do
  echo "[$codec]"
  for table in customer orders lineitem; do
    echo -n "$table: "
    sql "SELECT ROUND(SUM(file_size_in_bytes)/1048576.0, 2) FROM iceberg.$codec.\"${table}\$files\""
  done
done

echo 'DONE: GZIP and ZSTD data present; no volumes were removed.'
