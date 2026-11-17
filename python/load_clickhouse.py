#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
load_clickhouse.py —— 把 Hive 的 ADS/DWS 结果同步进 ClickHouse 服务层

链路：Hive（重计算）→ 导出 TSV → ClickHouse（列存服务层）
不引第三方库，直接用 ClickHouse 的 HTTP 接口做 INSERT。

用法：
  python python/load_clickhouse.py
  python python/load_clickhouse.py --host 127.0.0.1 --port 8123 --password clickhouse
"""

from __future__ import annotations

import argparse
import os
import sys
import urllib.parse
import urllib.request

TABLES = [
    # (ClickHouse 表, CSV 文件, 列顺序说明)
    ("ydsh_ads.sales_daily", "daily_gmv.csv", "dt,gmv,order_cnt,user_cnt,aov"),
    ("ydsh_ads.trade_monthly", "monthly.csv", "month,gmv,order_cnt,user_cnt,aov,mom_rate"),
    ("ydsh_ads.category_day", "category_day.csv", "dt,category,gmv,item_qty"),
    ("ydsh_ads.channel_day", "channel_day.csv", "dt,channel_code,gmv,order_cnt"),
]


def http(host: str, port: int, user: str, password: str, query: str,
         body: bytes | None = None, modify: bool = False) -> str:
    """调 ClickHouse HTTP 接口。

    注意：ClickHouse 的 HTTP 接口对 GET 请求强制只读，TRUNCATE / INSERT
    这类写操作必须用 POST（哪怕 body 为空）。这一点不写在文档显眼处，
    踩过一次 500 "Cannot execute query in readonly mode" 才记住。
    """
    url = f"http://{host}:{port}/?" + urllib.parse.urlencode({"query": query})
    use_post = modify or body is not None
    req = urllib.request.Request(url, data=(body if body is not None else (b"" if use_post else None)),
                                 method="POST" if use_post else "GET")
    req.add_header("X-ClickHouse-User", user)
    req.add_header("X-ClickHouse-Key", password)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read().decode("utf-8", "replace")


def to_tsv(path: str) -> tuple[bytes, int]:
    """把 beeline 导出的 tsv2 转成 ClickHouse 可吃的 TabSeparated。

    需要处理的两件事：
      1) 表头行要去掉（ClickHouse INSERT 不认表头）；
      2) 空值：beeline 输出 NULL 字面量，Nullable 列要写成 \\N。
    """
    lines = open(path, encoding="utf-8").read().splitlines()
    if not lines:
        return b"", 0
    body = []
    for ln in lines[1:]:
        if not ln.strip():
            continue
        cells = []
        for c in ln.split("\t"):
            c = c.strip()
            cells.append("\\N" if c in ("NULL", "null", "") else c)
        body.append("\t".join(cells))
    return ("\n".join(body) + "\n").encode("utf-8"), len(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("CLICKHOUSE_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("CLICKHOUSE_PORT", "8123")))
    ap.add_argument("--user", default=os.environ.get("CLICKHOUSE_USER", "default"))
    ap.add_argument("--password", default=os.environ.get("CLICKHOUSE_PASSWORD", "clickhouse"))
    ap.add_argument("--data-dir", default="data")
    args = ap.parse_args()

    print(f"▶ 目标 ClickHouse {args.host}:{args.port}")
    print("  版本：" + http(args.host, args.port, args.user, args.password, "SELECT version()").strip())

    for table, csv_name, cols in TABLES:
        path = os.path.join(args.data_dir, csv_name)
        if not os.path.exists(path):
            print(f"  ! 跳过 {table}：缺少 {path}")
            continue
        body, n = to_tsv(path)
        http(args.host, args.port, args.user, args.password,
             f"TRUNCATE TABLE IF EXISTS {table}", modify=True)
        http(args.host, args.port, args.user, args.password,
             f"INSERT INTO {table} ({cols}) FORMAT TabSeparated", body)
        cnt = http(args.host, args.port, args.user, args.password,
                   f"SELECT count() FROM {table}").strip()
        print(f"  ✓ {table:32s} 导入 {n:>6} 行，库内计数 {cnt}")

    print("\n▶ 口径校验（与 Hive 对齐）")
    gmv = http(args.host, args.port, args.user, args.password,
               "SELECT round(sum(gmv), 2) FROM ydsh_ads.sales_daily").strip()
    print(f"  ClickHouse 日表 GMV 合计：{gmv}")
    print("  Hive 侧基准值：36116687.06（见 docs/第3周遗留问题处置.md 六层对账）")


if __name__ == "__main__":
    sys.exit(main())
