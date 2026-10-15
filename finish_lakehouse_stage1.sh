#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/lakehouse-lab1"

trino_sql() {
  docker compose exec -T trino trino --output-format TSV --execute "$1"
}
wait_trino() {
  local i
  for i in {1..90}; do
    if trino_sql 'SELECT 1' >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo 'Trino не стал готовым. Проверь: docker compose logs --tail=50 trino' >&2
  return 1
}
insert_range() {
  local lo="$1" hi="$2" existing expected
  echo "--- Диапазон orderkey [$lo, $hi) ---"
  existing=$(trino_sql "SELECT count(*) FROM iceberg.bronze.lineitem WHERE orderkey >= $lo AND orderkey < $hi" | tr -d '\r[:space:]')
  expected=$(trino_sql "SELECT count(*) FROM tpch.sf1.lineitem WHERE orderkey >= $lo AND orderkey < $hi" | tr -d '\r[:space:]')
  echo "В Bronze: $existing, ожидается: $expected"
  if [[ "$existing" == "$expected" ]]; then
    echo 'Уже загружено; пропускаем.'
  elif [[ "$existing" == 0 ]]; then
    docker compose exec -T trino trino --session task_concurrency=1 --session iceberg.compression_codec=GZIP --execute "INSERT INTO iceberg.bronze.lineitem SELECT * FROM tpch.sf1.lineitem WHERE orderkey >= $lo AND orderkey < $hi"
    local got
    got=$(trino_sql "SELECT count(*) FROM iceberg.bronze.lineitem WHERE orderkey >= $lo AND orderkey < $hi" | tr -d '\r[:space:]')
    if [[ "$got" != "$expected" ]]; then echo "После загрузки: $got, ожидалось $expected. Останавливаемся." >&2; exit 1; fi
  else
    echo 'Обнаружена неполная загрузка диапазона. Не вставляем повторно, чтобы не сделать дубликаты.' >&2
    exit 1
  fi
  echo 'Перезапускаем только Trino для освобождения памяти JVM...'
  docker compose restart trino >/dev/null
  wait_trino
}

wait_trino
actual=$(trino_sql 'SELECT count(*) FROM iceberg.bronze.lineitem WHERE orderkey < 1500000' | tr -d '\r[:space:]')
[[ "$actual" == 1499574 ]] || { echo "Неожиданное состояние первой партии: $actual; ничего не меняем." >&2; exit 1; }
for low in 1500000 3000000 4500000 6000000; do
  insert_range "$low" "$((low+1500000))"
done

echo '--- Проверка Bronze ---'
trino_sql 'SELECT count(*) FROM iceberg.bronze.lineitem'
# Используем явный партиционный фильтр для более компактной Silver таблицы.
if ! trino_sql "SHOW TABLES FROM iceberg.silver LIKE 'shipping_orders'" | grep -q 'shipping_orders'; then
  echo '--- Создаём Silver ---'
  docker compose exec -T trino trino --session task_concurrency=1 --session iceberg.compression_codec=GZIP --execute "CREATE TABLE iceberg.silver.shipping_orders WITH (format = 'PARQUET') AS SELECT o.orderkey, o.orderdate, o.shippriority, l.extendedprice, l.discount FROM iceberg.bronze.customer c JOIN iceberg.bronze.orders o ON c.custkey = o.custkey JOIN iceberg.bronze.lineitem l ON o.orderkey = l.orderkey WHERE c.mktsegment = 'BUILDING' AND o.orderdate < DATE '1995-03-15' AND l.shipdate > DATE '1995-03-15'"
fi
if ! trino_sql "SHOW TABLES FROM iceberg.gold LIKE 'top_orders'" | grep -q 'top_orders'; then
  echo '--- Создаём Gold ---'
  docker compose exec -T trino trino --session task_concurrency=1 --session iceberg.compression_codec=GZIP --execute "CREATE TABLE iceberg.gold.top_orders WITH (format = 'PARQUET') AS SELECT orderkey, sum(extendedprice * (1 - discount)) AS revenue, orderdate, shippriority FROM iceberg.silver.shipping_orders GROUP BY orderkey, orderdate, shippriority ORDER BY revenue DESC LIMIT 10"
fi

echo '--- Финальная проверка ---'
trino_sql "SELECT 'customer' AS tbl, count(*) AS n FROM iceberg.bronze.customer UNION ALL SELECT 'orders', count(*) FROM iceberg.bronze.orders UNION ALL SELECT 'lineitem', count(*) FROM iceberg.bronze.lineitem UNION ALL SELECT 'silver', count(*) FROM iceberg.silver.shipping_orders UNION ALL SELECT 'gold', count(*) FROM iceberg.gold.top_orders"
echo 'ГОТОВО. Если строки соответствуют ожидаемым, переходим к ZSTD и тестам.'
