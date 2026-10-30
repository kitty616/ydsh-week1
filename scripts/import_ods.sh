#!/usr/bin/env bash
# =============================================================
# import_ods.sh —— 一键完成：建库 → 建表 → 导入 → 行数校验
# 用法：bash scripts/import_ods.sh
# =============================================================
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=============================================="
echo " 云购生活 · ODS 层一键导入"
echo "=============================================="

# -------- 前置检查：CSV 是否齐全 --------
echo ""
echo "[0/4] 检查 data/ 目录中的 CSV ..."
missing=0
for f in ods_user ods_product ods_store ods_order ods_order_item ods_user_behavior; do
  if [[ -f "data/${f}.csv" ]]; then
    echo "  ✓ ${f}.csv"
  else
    echo "  ✗ 缺少 data/${f}.csv"
    missing=1
  fi
done
if [[ $missing -eq 1 ]]; then
  echo ""
  echo "✗ 存在缺失文件，已中止。请先把 6 个 CSV 放进 data/ 目录（文件名全小写）。"
  exit 1
fi

# -------- 容器检查 --------
echo ""
echo "[1/4] 检查容器状态 ..."
for c in ydsh-mysql ydsh-hive-metastore ydsh-hive-server; do
  if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
    echo "  ✓ ${c} 运行中"
  else
    echo "  ✗ ${c} 未运行，请先执行 docker compose up -d"
    exit 1
  fi
done

# -------- 依次执行 --------
echo ""
echo "[2/4] 建库 ..."
bash scripts/run_sql.sh sql/ods/00_init_database.sql

echo ""
echo "[3/4] 建表 + 导入 ..."
bash scripts/run_sql.sh sql/ods/01_create_ods_tables.sql
bash scripts/run_sql.sh sql/ods/02_load_data.sql

echo ""
echo "[4/4] 行数校验 ..."
bash scripts/run_sql.sh sql/ods/03_check_rowcount.sql

echo ""
echo "=============================================="
echo " ✓ 全部完成。请核对上面 diff 列，正常应为 0 或极小偏差。"
echo "=============================================="
