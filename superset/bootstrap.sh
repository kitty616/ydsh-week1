#!/usr/bin/env bash
# =============================================================
# Superset 启动引导
#
# 顺序不能乱：
#   1) 等 MySQL 可用并建好 superset 库（元数据要有地方放）
#   2) superset db upgrade  —— 建/升级元数据表结构
#   3) create-admin          —— 幂等：已存在时会报错，这里吞掉
#   4) superset init         —— 初始化默认权限与角色
#   5) 启动 Web 服务
#
# 为什么不把这些写进 Dockerfile：镜像要能在任何机器上「起来即用」，
# 而元数据库是运行时才存在的，构建期无法执行。
# =============================================================
set -euo pipefail

echo "[bootstrap] 等待 MySQL (${MYSQL_HOST:-mysql}:${MYSQL_PORT:-3306}) ..."
for i in $(seq 1 60); do
  if python - <<'PY' 2>/dev/null
import os, pymysql, sys
try:
    c = pymysql.connect(host=os.environ.get("MYSQL_HOST", "mysql"),
                        port=int(os.environ.get("MYSQL_PORT", "3306")),
                        user=os.environ.get("MYSQL_USER", "root"),
                        password=os.environ.get("MYSQL_ROOT_PASSWORD", "root"),
                        connect_timeout=3)
    cur = c.cursor()
    cur.execute("CREATE DATABASE IF NOT EXISTS superset "
                "DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
    c.commit(); c.close()
except Exception:
    sys.exit(1)
PY
  then
    echo "[bootstrap] MySQL 就绪，superset 库已确保存在"
    break
  fi
  echo "[bootstrap] 第 ${i} 次等待 ..."
  sleep 3
done

echo "[bootstrap] 升级元数据表结构 ..."
superset db upgrade

echo "[bootstrap] 创建管理员（已存在则跳过）..."
superset fab create-admin \
  --username "${SUPERSET_ADMIN_USER:-admin}" \
  --firstname "${SUPERSET_ADMIN_FIRSTNAME:-Admin}" \
  --lastname "${SUPERSET_ADMIN_LASTNAME:-User}" \
  --email "${SUPERSET_ADMIN_EMAIL:-admin@ydsh.local}" \
  --password "${SUPERSET_ADMIN_PASSWORD:-admin}" || echo "[bootstrap] 管理员已存在，跳过"

echo "[bootstrap] 初始化角色与权限 ..."
superset init

echo "[bootstrap] 启动 Superset Web ..."
exec /usr/bin/run-server.sh
