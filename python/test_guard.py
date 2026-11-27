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

    # ==================================================================
    # 2026-11-27 增补：**正例防误拦**。
    # 事故：问「各支付方式的成交额占比」，模型生成的 SQL 完全正确，
    # 却被校验器判成「gmv_ratio 不属于 dwd_order」当场拦掉。
    # 原因：gmv_ratio 是 SELECT 里 AS 定义的别名，ORDER BY 引用别名是标准写法，
    # 校验器只认识表里的列，把别名当成了跨表串列。
    # 这个教训是：负例防漏拦，正例防误拦，**误拦比漏拦更伤**——
    # 漏拦至少 Hive 会报错，误拦是「对的东西不让你用」。
    # 下面每条都是合法 SQL，必须 PASS。
    # ==================================================================
    ("正例：窗口算占比 + ORDER BY 引用别名",
     "```sql\nSELECT pay_type_code, SUM(pay_amount) AS total_gmv, "
     "SUM(pay_amount) / SUM(SUM(pay_amount)) OVER () AS gmv_ratio\n"
     "FROM ydsh_dwd.dwd_order\nGROUP BY pay_type_code\nORDER BY gmv_ratio DESC\nLIMIT 200\n```",
     True, None),
    ("正例：JOIN 维表把编码换中文名",
     "```sql\nSELECT p.pay_name, ROUND(SUM(o.pay_amount), 2) AS gmv\n"
     "FROM ydsh_dwd.dwd_order o\n"
     "JOIN ydsh_dwd.dim_pay_type p ON o.pay_type_code = p.pay_code\n"
     "GROUP BY p.pay_name\n```",
     True, "ydsh_dwd.dim_pay_type"),
    ("正例：CAST AS DECIMAL 里的 AS 不是别名",
     "```sql\nSELECT dt, CAST(ROUND(SUM(gmv), 2) AS DECIMAL(18, 2)) AS gmv_day\n"
     "FROM ydsh_dws.dws_trade_day\nGROUP BY dt\n```",
     True, None),
    ("正例：CTE（WITH 临时表不在白名单里）",
     "```sql\nWITH m AS (SELECT dt, SUM(gmv) AS g\n"
     "FROM ydsh_dws.dws_trade_day GROUP BY dt)\n"
     "SELECT dt, g FROM m ORDER BY g DESC LIMIT 5\n```",
     True, None),
    ("正例：CASE WHEN 分桶",
     "```sql\nSELECT CASE WHEN pay_amount >= 500 THEN 'high' ELSE 'low' END AS band,\n"
     "       COUNT(1) AS cnt\n"
     "FROM ydsh_dwd.dwd_order\n"
     "GROUP BY CASE WHEN pay_amount >= 500 THEN 'high' ELSE 'low' END\n```",
     True, None),
    ("正例：子查询 + 外层别名前缀",
     "```sql\nSELECT t.province, t.gmv FROM (\n"
     "  SELECT province, SUM(gmv) AS gmv FROM ydsh_ads.ads_region_sales GROUP BY province\n"
     ") t ORDER BY t.gmv DESC LIMIT 5\n```",
     True, None),
    ("正例：UNION ALL 两条 SELECT",
     "```sql\nSELECT 'order' AS src, COUNT(1) AS c FROM ydsh_dwd.dwd_order\n"
     "UNION ALL\nSELECT 'store' AS src, COUNT(1) AS c FROM ydsh_dwd.dim_store\n```",
     True, None),
    ("正例：三表 JOIN",
     "```sql\nSELECT s.province, u.gender, SUM(o.pay_amount) AS gmv\n"
     "FROM ydsh_dwd.dwd_order o\n"
     "JOIN ydsh_dwd.dim_store s ON o.store_id = s.store_id\n"
     "JOIN ydsh_dwd.dim_user  u ON o.user_id  = u.user_id\n"
     "GROUP BY s.province, u.gender\n```",
     True, None),

    # 负例：这些必须拦住，否则就是「校验器被改松了」
    ("错误：维度列挂在汇总表上（本次事故的反面）",
     "```sql\nSELECT SUM(gmv) FROM ydsh_dws.dws_trade_day WHERE province LIKE '%广东%'\n```",
     False, None),
    ("错误：dwd_order 没有 product_id",
     "```sql\nSELECT p.category FROM ydsh_dwd.dwd_order o "
     "JOIN ydsh_dwd.dim_product p ON o.product_id = p.product_id\n```",
     False, None),
    ("错误：pay_code 挂在订单表上（编码在维表）",
     "```sql\nSELECT pay_code, COUNT(1) FROM ydsh_dwd.dwd_order GROUP BY pay_code\n```",
     False, None),
    ("错误：成品表里查明细字段",
     "```sql\nSELECT order_date FROM ydsh_ads.ads_region_sales\n```",
     False, None),
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

# ======================================================================
# 第二组：问句与 SQL 条件是否一致（check_time_scope）
# 2026-11-27 的静默错误：问「取消了多少订单」，自修复一轮后 SQL 自己加了
# WHERE dt LIKE '2024-06%'，答案从全年 2023 单缩成 6 月的 170 单，页面照样
# 显示「执行完成」。这类「合法但答非所问」的错不报错，只能靠这条检查拦。
# ======================================================================
TIME_CASES = [
    ("问句无时间 + SQL 加月过滤", "取消了多少订单",
     "SELECT SUM(cancel_cnt) FROM ydsh_dws.dws_trade_day WHERE dt LIKE '2024-06%'", False),
    ("问句无时间 + 无过滤（正确）", "取消了多少订单",
     "SELECT SUM(cancel_cnt) AS c FROM ydsh_dws.dws_trade_day", True),
    ("问句有月份（放行）", "2024 年 6 月的总 GMV 是多少？",
     "SELECT SUM(gmv) FROM ydsh_dws.dws_trade_month WHERE month = '2024-06'", True),
    ("问句有季度（放行）", "2024 年第一季度 GMV",
     "SELECT SUM(gmv) FROM ydsh_dws.dws_trade_month WHERE month IN ('2024-01','2024-02','2024-03')", True),
    ("问句问趋势、SQL 只 ORDER BY（放行）", "2024 年每个月的 GMV 趋势",
     "SELECT month, gmv FROM ydsh_dws.dws_trade_month ORDER BY month", True),
    ("问句无时间 + SQL 加单日过滤", "有多少用户下单",
     "SELECT COUNT(DISTINCT user_id) FROM ydsh_dwd.dwd_order WHERE order_date = '2024-06-01'", False),
]

time_pass = 0
print("-" * 92)
for desc, q, sql, expect in TIME_CASES:
    ok, _, problems = validate(sql, SCHEMA, q)
    good = ok == expect
    time_pass += 1 if good else 0
    print(f"{'✓' if good else '✗'} 时间范围 {desc:<28}{'期望 ' + str(expect):>14}{'实际 ' + str(ok):>14}")

print("=" * 92)
print(f"时间范围一致性通过 {time_pass}/{len(TIME_CASES)}")
pass_cnt += time_pass
total_cnt = len(CASES) + len(TIME_CASES)

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
    json.dump({"passed": pass_cnt, "total": total_cnt, "detail": detail},
              f, ensure_ascii=False, indent=2)
print("\n结果已写入 data/guard_test_results.json")

if pass_cnt != total_cnt:
    sys.exit(1)

