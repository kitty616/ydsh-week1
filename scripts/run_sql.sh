#!/usr/bin/env bash
# =============================================================
# run_sql.sh —— 把任意 SQL 文件送进 HiveServer2 执行
# 用法：bash scripts/run_sql.sh sql/ods/00_init_database.sql
# =============================================================
set -euo pipefail

SQL_FILE="${1:-}"
if [[ -z "$SQL_FILE" ]]; then
  echo "用法: bash scripts/run_sql.sh <sql文件路径>"
  echo "示例: bash scripts/run_sql.sh sql/ods/01_create_ods_tables.sql"
  exit 1
fi

if [[ ! -f "$SQL_FILE" ]]; then
  echo "✗ 文件不存在: $SQL_FILE"
  exit 1
fi

CONTAINER="ydsh-hive-server"

# 1. 确认容器在跑
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "✗ 容器 ${CONTAINER} 未运行，请先执行: docker compose up -d"
  exit 1
fi

# 2. 把 SQL 拷进容器（容器里没有挂载 sql 目录）
BASENAME="$(basename "$SQL_FILE")"
docker cp "$SQL_FILE" "${CONTAINER}:/tmp/${BASENAME}" >/dev/null

# 3. 执行
echo "▶ 执行 ${SQL_FILE} ..."
docker exec "$CONTAINER" beeline \
  -u "jdbc:hive2://localhost:10000" \
  --silent=true \
  --showHeader=true \
  -f "/tmp/${BASENAME}"

echo "✓ ${SQL_FILE} 执行完成"
