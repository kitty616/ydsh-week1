#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
test_guard.py —— 对抗测试：证明 SQL 静态校验器真的能拦住错误/危险的 SQL

为什么要有这个测试：
  NL2SQL 的失败往往不是「生成不出来」，而是「生成出来了但不能用」——
  表名是编的、字段不存在、或者直接给你一句 DELETE。
  如果不在执行前拦掉，轻则报错，重则改坏数据。

为什么要断言「改写后长什么样」：
  只判断 ok 布尔值是不够的。校验器会自己动手补库名，补错了照样返回 ok，
  测试却完全看不见——第 3 周 Code Review 就是这么漏掉一个 Blocker 的：
  dws_trade_day 被补成 ydsh_ads.dws_trade_day，用例显示 PASS。
  所以凡是涉及改写的用例，必须同时校验改写结果。
"""
import json
import os
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, "python"))

from nl2sql import validate, extract_sql  # noqa: E402

SCHEMA = json.load(open(os.path.join(BASE, "data", "hive_schema.json"), encoding="utf-8"))

CASES = [
    # (说明, 模型原始输出, 期望是否通过, 期望改写后包含的子串)
    ("正常查询（带库名）",
     "```sql\nSELECT category, gmv FROM ydsh_ads.ads_category_topn WHERE rank_no <= 5\n```",
     True, "ydsh_ads.ads_category_topn"),
    ("正常查询（裸表名，ads 层）",
     "```sql\nSELECT month, gmv FROM ads_monthly_trend\n```",
     True, "ydsh_ads.ads_monthly_trend"),
    ("裸表名应补到 dws 层而非 ads",
     "```sql\nSELECT dt, gmv FROM dws_trade_day\n```",
     True, "ydsh_dws.dws_trade_day"),
    ("裸表名应补到 dwd 层而非 ads",
     "```sql\nSELECT order_id, pay_amount FROM dwd_order\n```",
     True, "ydsh_dwd.dwd_order"),
    ("裸维表应补到 dwd 层",
     "```sql\nSELECT store_id, province FROM dim_store\n```",
     True, "ydsh_dwd.dim_store"),
    ("正常查询（聚合 + JOIN）",
     "```sql\nSELECT s.province, SUM(o.pay_amount) gmv FROM ydsh_dwd.dwd_order o "
     "JOIN ydsh_dwd.dim_store s ON o.store_id = s.store_id GROUP BY s.province\n```",
     True, "ydsh_dwd.dim_store"),
    ("危险：DELETE", "```sql\nDELETE FROM ydsh_dwd.dwd_order WHERE order_date='2024-01-01'\n```",
     False, None),
    ("危险：DROP TABLE", "```sql\nDROP TABLE ydsh_dwd.dwd_order\n```", False, None),
    ("危险：UPDATE", "```sql\nUPDATE ydsh_ads.ads_kpi_core SET metric_value = 0\n```", False, None),
    ("危险：多语句注入",
     "```sql\nSELECT 1;\nDROP TABLE ydsh_dwd.dwd_order\n```", False, None),
    ("错误：编造的库表", "```sql\nSELECT * FROM ydsh_ods.ods_sales_fact\n```", False, None),
    ("错误：非 SELECT 开头", "```sql\nSHOW TABLES IN ydsh_dwd\n```", False, None),
    ("错误：空输出", "", False, None),
    ("边界：子查询里的裸表名",
     "```sql\nSELECT * FROM (SELECT dt, gmv FROM dws_trade_day) t LIMIT 5\n```",
     True, "ydsh_dws.dws_trade_day"),
    ("边界：已带库名不应被重复补全",
     "```sql\nSELECT dt FROM ydsh_dws.dws_trade_day LIMIT 3\n```",
     True, "ydsh_dws.dws_trade_day"),
    # 以下两条来自真实模型第一次生成 SQL 时的实际输出（见报告 5.5 节）：
    # 模型用双引号包中文别名，而 Hive 把双引号当字符串字面量，别名位置直接语法错误。
    # 校验器按 Hive 语义归一化，因此必须断言"改成了什么"，不能只断言"放行了"。
    ("引号：双引号别名应改成反引号",
     '```sql\nSELECT ROUND(SUM(gmv), 2) AS "华东GMV" FROM ydsh_ads.ads_monthly_trend\n```',
     True, "AS `华东GMV`"),
    ("引号：双引号字符串应改成单引号",
     '```sql\nSELECT province FROM ydsh_dwd.dim_store WHERE province LIKE "%广东%"\n```',
     True, "LIKE '%广东%'"),
]

print("=" * 92)
print(f"{'用例':<38}{'期望':>6}{'实际':>8}{'改写校验':>10}{'判定':>8}")
print("=" * 92)

pass_cnt = 0
detail = []
for desc, raw, expect, expect_sql in CASES:
    sql = extract_sql(raw)
    ok, fixed, problems = validate(sql, SCHEMA)

    if expect_sql is None:
        rewrite_ok = True
    else:
        rewrite_ok = expect_sql in fixed

    verdict = "PASS" if (ok == expect and rewrite_ok) else "FAIL"
    if ok == expect and rewrite_ok:
        pass_cnt += 1
    rw_txt = "-" if expect_sql is None else ("OK" if rewrite_ok else "WRONG")
    print(f"{desc:<38}{str(expect):>6}{str(ok):>8}{rw_txt:>10}{verdict:>8}")
    detail.append({"case": desc, "expect": expect, "actual": ok,
                   "expect_sql": expect_sql, "rewrite_ok": rewrite_ok,
                   "problems": problems, "sql_after": fixed})

    if rewrite_ok is False:
        print(f"    改写结果不符，实际为：{fixed.replace(chr(10), ' ')}")

print("=" * 92)
print(f"通过 {pass_cnt}/{len(CASES)}")

print("\n被拦截的原因明细：")
for d in detail:
    if not d["actual"] and d["problems"]:
        print(f"  · {d['case']}：{'；'.join(d['problems'])}")

print("\n裸表名补全结果（应按真实库名，而非统一补 ads）：")
for d in detail:
    if d["expect_sql"] and d["rewrite_ok"]:
        first = d["sql_after"].replace("\n", " ").split("LIMIT")[0].strip()
        print(f"  · {d['case']} → {first[:88]}")

with open(os.path.join(BASE, "data", "guard_test_results.json"), "w", encoding="utf-8") as f:
    json.dump({"passed": pass_cnt, "total": len(CASES), "detail": detail},
              f, ensure_ascii=False, indent=2)
print("\n结果已写入 data/guard_test_results.json")

if pass_cnt != len(CASES):
    sys.exit(1)

