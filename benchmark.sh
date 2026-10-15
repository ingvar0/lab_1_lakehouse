#!/bin/bash
set -euo pipefail

mkdir -p results
docker compose cp sql/q3_benchmark.sql trino:/tmp/q3_benchmark.sql

for codec in GZIP ZSTD; do
  echo "=== $codec ==="

  if [ "$codec" = "GZIP" ]; then
    schema="bronze"
  else
    schema="bronze_zstd"
  fi

  for run in 1 2 3; do
    echo "Run $run"

    start=$(date +%s)

    docker compose exec -T trino trino \
      --session task_concurrency=1 \
      --execute "$(sed "s/iceberg\.bronze\./iceberg.${schema}./g" sql/q3_benchmark.sql)" \
      > "results/${codec}_${run}.csv"

    end=$(date +%s)
    elapsed=$((end - start))

    echo "$codec,$run,$elapsed" | tee -a results/timings.csv
  done
done
