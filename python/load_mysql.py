#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
load_mysql.py —— 把 ADS 结果快照写入 MySQL（服务层）

为什么要有这一层：
  Hive 是「算得动」的地方，不是「点得动」的地方。Superset 里点一次筛选
  就要重跑一次 Hive 查询，交互体验会崩。企业里的常规做法是把 ADS 结果
  同步到 MySQL 这类行库存一份服务层，BI 直接打服务层。
  本周的压测也拿 MySQL 和 ClickHouse 做同口径对比。

实现上用 mysql 客户端而不是 pymysql：宿主机的 Python 不一定装了驱动，
但容器里的 mysql CLI 一定有，少一个依赖就少一处环境差异。
"""

from __future__ import annotations

import csv
import os
import subprocess
import sys

CONTAINER = os.environ.get("YDSH_MYSQL_CONTAINER", "ydsh-mysql")
USER = os.environ.get("MYSQL_USER", "root")
PASSWORD = os.environ.get("MYSQL_ROOT_PASSWORD", "root")
DB = "ydsh_ads"
CSV_DIR = os.environ.get("YDSH_CSV_DIR", "data/serving")

TABLES = {
    "sales_daily": """
        dt DATE, gmv DOUBLE, order_cnt INT, user_cnt INT
    """,
    "monthly": """
        month VARCHAR(7), gmv DOUBLE, order_cnt INT, user_cnt INT,
        aov DOUBLE, mom_rate DOUBLE NULL
    """,
    "category": """
        category VARCHAR(32), gmv DOUBLE, `share` DOUBLE,
        order_cnt INT, item_qty INT
    """,
    "region": """
        province VARCHAR(32), iso VARCHAR(8), name_en VARCHAR(32),
        gmv DOUBLE, order_cnt INT, user_cnt INT, aov DOUBLE, ratio DOUBLE
    """,
    "pay_type": """
        name VARCHAR(32), gmv DOUBLE, cnt INT, ratio DOUBLE
    """,
    "store_rank": """
        rank_no INT, store_name VARCHAR(64), province VARCHAR(32),
        gmv DOUBLE, order_cnt INT, aov DOUBLE
    """,
}


def mysql(sql: str, db: str | None = None) -> tuple[int, str]:
    cmd = ["docker", "exec", "-i", CONTAINER, "mysql",
           f"-u{USER}", f"-p{PASSWORD}", "--default-character-set=utf8mb4",
           "--batch", "--raw"]
    if db:
        cmd.append(db)
    env = dict(os.environ, MSYS2_ARG_CONV_EXCL="*")
    r = subprocess.run(cmd, input=sql, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=env, timeout=300)
    out = (r.stdout or "") + (r.stderr or "")
    return r.returncode, out.strip()


def clean_lines(out: str) -> list[str]:
    """过滤 mysql 客户端的安全告警，只留真实查询结果。"""
    return [ln for ln in out.splitlines()
            if ln.strip() and not ln.startswith(("mysql:", "Warning:"))]


def esc(v: str) -> str:
    if v == "":
        return "NULL"
    try:
        float(v)
        return v
    except ValueError:
        return "'" + v.replace("\\", "\\\\").replace("'", "''") + "'"


def main():
    print(f"▶ 目标 MySQL 容器 {CONTAINER}，库 {DB}")
    code, out = mysql(f"CREATE DATABASE IF NOT EXISTS {DB} "
                      f"DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
    if code != 0:
        print("✗ 建库失败：", out)
        return 1

    for table, cols in TABLES.items():
        path = os.path.join(CSV_DIR, f"{table}.csv")
        if not os.path.exists(path):
            print(f"  ! 跳过 {table}：缺少 {path}")
            continue

        with open(path, encoding="utf-8") as fh:
            rows = list(csv.reader(fh))
        header, body = rows[0], rows[1:]

        ddl = f"DROP TABLE IF EXISTS {table};\nCREATE TABLE {table} ({cols}) " \
              f"ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n"
        code, out = mysql(ddl, DB)
        if code != 0:
            print(f"  ✗ {table} 建表失败：{out[:300]}")
            continue

        if body:
            values = ",\n".join(
                "(" + ",".join(esc(c) for c in row) + ")" for row in body)
            sql = (f"INSERT INTO {table} ({','.join('`%s`' % h for h in header)}) "
                   f"VALUES\n{values};")
            code, out = mysql(sql, DB)
            if code != 0:
                print(f"  ✗ {table} 写入失败：{out[:300]}")
                continue

        code, cnt = mysql(f"SELECT COUNT(*) FROM {table};", DB)
        rows_out = clean_lines(cnt)
        n = rows_out[-1] if code == 0 and rows_out else "?"
        print(f"  ✓ {DB}.{table:12s} 写入 {len(body):>5} 行，库内计数 {n}")

    code, out = mysql("SELECT ROUND(SUM(gmv),2) FROM sales_daily;", DB)
    vals = clean_lines(out)
    print(f"\n▶ 口径校验：MySQL 日表 GMV 合计 {vals[-1] if code == 0 and vals else out}")
    print("  Hive 基准：36116687.06")
    return 0


if __name__ == "__main__":
    sys.exit(main())
