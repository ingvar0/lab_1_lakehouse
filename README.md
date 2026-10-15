# Лабораторная №1 — вариант 1 (TPC-H Q3)

Стек: SeaweedFS (S3), PostgreSQL, Lakekeeper (Iceberg REST), Trino.

## Запуск

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps -a
```

Основные контейнеры должны работать, `migrate`, `bootstrap`, `warehouse-init` должны завершиться с кодом 0.

Проверка SQL:

```bash
docker compose exec trino trino --execute 'SHOW CATALOGS'
docker compose exec trino trino --execute 'SELECT count(*) FROM tpch.sf1.customer'
```

SeaweedFS S3: http://localhost:8333; filer UI: http://localhost:8888; Lakekeeper: http://localhost:8181/ui/; Trino: http://localhost:8080.

Пароли демонстрационные — не используйте эту конфигурацию на публичном сервере. Точное взаимодействие версий и доступность образов требуют проверки в локальном Docker.
