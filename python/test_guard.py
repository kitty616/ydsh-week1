#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
test_guard.py —— 对抗测试：证明 SQL 静态校验器真的能拦住错误/危险的 SQL

为什么要有这个测试：
  NL2SQL 的失败往往不是「生成不出来」，而是「生成出来了但不能用」——
  表名是编的、字段不存在、或者直接给你一句 DELETE。
  如果不在执行前拦掉，轻则报错，重则改坏数据。
  这里用 8 条典型的坏 SQL 和 3 条好 SQL，验证校验器的判断是否符合预期。
"""
import json
import os
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, "python"))

from nl2sql import validate, extract_sql  # noqa: E402

SCHEMA = json.load(open(os.path.join(BASE, "data", "hive_schema.json"), encoding="utf-8"))
TABLES = set(SCHEMA.keys()) | {k.split(".")[1] for k in SCHEMA}

CASES = [
    # (说明, 模型原始输出, 期望是否通过)
    ("正常查询（带库名）",
     "```sql\nSELECT category, gmv FROM ydsh_ads.ads_category_topn WHERE rank_no <= 5\n```", True),
    ("正常查询（裸表名，应自动补库名）",
     "```sql\nSELECT month, gmv FROM ads_monthly_trend\n```", True),
    ("正常查询（聚合 + JOIN）",
     "```sql\nSELECT s.province, SUM(o.pay_amount) gmv FROM ydsh_dwd.dwd_order o "
     "JOIN ydsh_dwd.dim_store s ON o.store_id = s.store_id GROUP BY s.province\n```", True),
    ("危险：DELETE", "```sql\nDELETE FROM ydsh_dwd.dwd_order WHERE order_date='2024-01-01'\n```", False),
    ("危险：DROP TABLE", "```sql\nDROP TABLE ydsh_dwd.dwd_order\n```", False),
    ("危险：UPDATE", "```sql\nUPDATE ydsh_ads.ads_kpi_core SET metric_value = 0\n```", False),
    ("危险：多语句注入",
     "```sql\nSELECT 1;\nDROP TABLE ydsh_dwd.dwd_order\n```", False),
    ("错误：编造的库表", "```sql\nSELECT * FROM ydsh_ods.ods_sales_fact\n```", False),
    ("错误：非 SELECT 开头", "```sql\nSHOW TABLES IN ydsh_dwd\n```", False),
    ("错误：空输出", "", False),
    ("边界：子查询里的裸表名",
     "```sql\nSELECT * FROM (SELECT dt, gmv FROM dws_trade_day) t LIMIT 5\n```", True),
]

print("=" * 74)
print(f"{'用例':<34}{'期望':>6}{'实际':>8}{'判定':>8}")
print("=" * 74)

pass_cnt = 0
detail = []
for desc, raw, expect in CASES:
    sql = extract_sql(raw)
    ok, fixed, problems = validate(sql, TABLES)
    verdict = "PASS" if ok == expect else "FAIL"
    if ok == expect:
        pass_cnt += 1
    print(f"{desc:<34}{str(expect):>6}{str(ok):>8}{verdict:>8}")
    detail.append({"case": desc, "expect": expect, "actual": ok,
                   "problems": problems, "sql_after": fixed})

print("=" * 74)
print(f"通过 {pass_cnt}/{len(CASES)}")

print("\n被拦截的原因明细：")
for d in detail:
    if not d["actual"] and d["problems"]:
        print(f"  · {d['case']}：{'；'.join(d['problems'])}")

print("\n裸表名自动补全示例：")
for d in detail:
    if d["actual"] and "ads_monthly_trend" in d["sql_after"] and "." in d["sql_after"].split("FROM")[1]:
        print("  " + d["sql_after"].replace("\n", " | "))
        break

with open(os.path.join(BASE, "data", "guard_test_results.json"), "w", encoding="utf-8") as f:
    json.dump({"passed": pass_cnt, "total": len(CASES), "detail": detail},
              f, ensure_ascii=False, indent=2)
print("\n结果已写入 data/guard_test_results.json")
