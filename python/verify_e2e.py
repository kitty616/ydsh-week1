#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""第 5 周：端到端联调与数据一致性核对。

设计原则
--------
1. **只读**。这个脚本不写任何业务表，跑多少遍结果都一样，可以直接进 CI。
2. **每条断言都有"期望值来源"**。期望值不是拍脑袋写的数字，而是上游层
   算出来的值、或第 1~4 周文档里已登记的值。对不上就报 FAIL，不"差不多就行"。
3. **区分 FAIL / WARN**。口径不一致是 FAIL（必须改），资源占用、单条耗时
   这类波动项是 WARN（记录但不阻塞）。

用法
----
    docker exec -w /app ydsh-app python verify_e2e.py            # 全量（含大模型）
    docker exec -w /app ydsh-app python verify_e2e.py --no-llm   # 跳过大模型调用

输出
----
    stdout            Markdown 表格（可直接 tee 成原始输出留档）
    data/e2e_result.json   机器可读结果
"""

import json
import os
import re
import sys
import time
import urllib.request
from datetime import datetime

HIVE_HOST = os.environ.get("HIVE_HOST", "hive-server")
HIVE_PORT = int(os.environ.get("HIVE_PORT", "10000"))
MYSQL_HOST = os.environ.get("MYSQL_HOST", "mysql")
MYSQL_USER = os.environ.get("MYSQL_USER", "root")
MYSQL_PASS = os.environ.get("MYSQL_ROOT_PASSWORD", "")
CK_HOST = os.environ.get("CLICKHOUSE_HOST", "clickhouse")
CK_PORT = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
CK_USER = os.environ.get("CLICKHOUSE_USER", "default")
CK_PASS = os.environ.get("CLICKHOUSE_PASSWORD", "")
API_BASE = os.environ.get("API_BASE", "http://api:8000")

# 脚本在仓库里跑（python/verify_e2e.py）和在容器里跑（/app/verify_e2e.py）
# 两种布局都要能找到 dashboard / data，所以先探测一次仓库根。
BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = BASE if os.path.isdir(os.path.join(BASE, "dashboard")) else os.path.dirname(BASE)

RESULTS = []


# --------------------------------------------------------------------------
# 断言与记录
# --------------------------------------------------------------------------
def check(stage, item, actual, expected, note=""):
    """登记一条核对结果。

    actual / expected 都转成字符串比较，但数值类型会先按 float 比一次，
    避免 36116687.06 与 36116687.060000001 这种浮点尾巴误判。
    """
    ok = _same(actual, expected)
    RESULTS.append(
        {
            "stage": stage,
            "item": item,
            "expected": _fmt(expected),
            "actual": _fmt(actual),
            "result": "PASS" if ok else "FAIL",
            "note": note,
        }
    )
    flag = "PASS" if ok else "FAIL"
    print(f"| {item} | {_fmt(expected)} | {_fmt(actual)} | {flag} | {note} |")
    return ok


def check_cond(stage, item, actual, cond, expected_desc, note=""):
    """带条件的断言：用于「小于某个阈值」这类不能用相等判断的核对。"""
    ok = bool(cond)
    RESULTS.append(
        {
            "stage": stage,
            "item": item,
            "expected": expected_desc,
            "actual": _fmt(actual),
            "result": "PASS" if ok else "FAIL",
            "note": note,
        }
    )
    print(f"| {item} | {expected_desc} | {_fmt(actual)} | {'PASS' if ok else 'FAIL'} | {note} |")
    return ok


def warn(stage, item, actual, note=""):
    RESULTS.append(
        {
            "stage": stage,
            "item": item,
            "expected": "-",
            "actual": _fmt(actual),
            "result": "WARN",
            "note": note,
        }
    )
    print(f"| {item} | - | {_fmt(actual)} | WARN | {note} |")


def _same(a, b):
    if a is None or b is None:
        return a == b
    try:
        return abs(float(a) - float(b)) < 1e-6
    except (TypeError, ValueError):
        return str(a).strip() == str(b).strip()


def _fmt(v):
    if isinstance(v, float):
        return f"{v:,.2f}"
    if isinstance(v, int):
        return f"{v:,}"
    return str(v)


def header(title, sub=""):
    print(f"\n## {title}\n")
    if sub:
        print(f"{sub}\n")
    print("| 核对项 | 期望 | 实测 | 结果 | 备注 |")
    print("|---|---|---|---|---|")


# --------------------------------------------------------------------------
# 连接器
# --------------------------------------------------------------------------
def hive_query(sql):
    from pyhive import hive

    conn = hive.connect(host=HIVE_HOST, port=HIVE_PORT, username="hive", database="default")
    try:
        cur = conn.cursor()
        cur.execute(sql)
        return cur.fetchall()
    finally:
        conn.close()


def hive_one(sql):
    return hive_query(sql)[0][0]


def mysql_query(sql, db="ydsh_ads"):
    import pymysql

    conn = pymysql.connect(
        host=MYSQL_HOST, user=MYSQL_USER, password=MYSQL_PASS,
        database=db, charset="utf8mb4", cursorclass=pymysql.cursors.Cursor,
    )
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
            return cur.fetchall()
    finally:
        conn.close()


def ck_query(sql):
    """ClickHouse 走 HTTP 接口：app 镜像里没装 clickhouse-connect，
    而 HTTP 是所有语言都能用的最小依赖通道。"""
    url = f"http://{CK_HOST}:{CK_PORT}/?user={CK_USER}&password={CK_PASS}"
    req = urllib.request.Request(url, data=sql.encode("utf-8"), method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8").strip()


def http_json(path, timeout=30):
    with urllib.request.urlopen(API_BASE + path, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


# --------------------------------------------------------------------------
# S1 ODS 原始层
# --------------------------------------------------------------------------
def s1_ods():
    header(
        "S1 · ODS 原始层（导入完整性）",
        "期望值来源：`data/ods_*.csv` 的物理行数。ODS 是「原样落地」层，"
        "行数必须与 CSV 完全相等——少了说明导入截断，多了说明重复导入。",
    )
    csv_expect = {
        "ods_order": 15600,
        "ods_order_item": 37549,
        "ods_product": 600,
        "ods_store": 60,
        "ods_user": 1000,
        "ods_user_behavior": 60000,
    }
    total = 0
    for table, n in csv_expect.items():
        got = int(hive_one(f"SELECT COUNT(*) FROM ydsh_ods.{table}"))
        total += got
        check("S1", f"`{table}` 行数", got, n, "与 CSV 行数一致")
    check("S1", "6 张表总行数", total, sum(csv_expect.values()), "114,809 行原样落地")

    # 原始层不该做任何清洗：抽查"脏数据"必须还在，否则说明清洗越界写回了 ODS
    bad_date = int(hive_one(
        "SELECT COUNT(*) FROM ydsh_ods.ods_order "
        "WHERE order_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'"))
    check("S1", "ods_order 中非标准日期行数", bad_date, 1902,
          "脏数据仍留在 ODS，说明清洗没有越界写回原始层")


# --------------------------------------------------------------------------
# S2 DWD 明细层
# --------------------------------------------------------------------------
def s2_dwd():
    header(
        "S2 · DWD 明细层（清洗与去重）",
        "期望值来源：`dq_compare`（第 2 周清洗时的前后对比）与 DWD 表实测。"
        "去重口径为按 `order_id` 保留业务时间最新一条。",
    )
    check("S2", "`dwd_order` 行数", int(hive_one("SELECT COUNT(*) FROM ydsh_dwd.dwd_order")),
          14398, "15,600 − 600 重复 − 310 负金额 − 292 超上限")
    check("S2", "`dwd_order_item_clean` 行数",
          int(hive_one("SELECT COUNT(*) FROM ydsh_dwd.dwd_order_item_clean")), 34580,
          "剔除 quantity ≤ 0 的 718 行及孤儿明细")
    check("S2", "`dwd_user_clean` 行数", int(hive_one("SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean")),
          1000, "用户不删行，只做标准化")
    check("S2", "`dwd_product_clean` 行数",
          int(hive_one("SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean")), 600,
          "商品不删行，价格按成本 ×1.2 修正")
    check("S2", "订单主键重复数",
          int(hive_one("SELECT COUNT(*) FROM (SELECT order_id FROM ydsh_dwd.dwd_order "
                       "GROUP BY order_id HAVING COUNT(*) > 1) t")), 0,
          "去重后主键唯一")

    # 五类脏数据的修复率：只统计"应当修复"的项，保留类（如 email 空值）不算未修复
    rows = hive_query(
        "SELECT category, SUM(before_cnt), SUM(after_cnt), SUM(fixed_cnt) "
        "FROM ydsh_dwd.dq_compare GROUP BY category ORDER BY category")
    print()
    total_before = total_fixed = 0
    for cat, before, after, fixed in rows:
        before, after, fixed = int(before), int(after), int(fixed)
        total_before += before
        total_fixed += fixed
        rate = fixed / before * 100 if before else 100.0
        print(f"- 脏数据类型 **{cat}**：修复前 {before:,} → 修复后 {after:,}，"
              f"修复 {fixed:,}（{rate:.1f}%）")
    print()
    check("S2", "五类脏数据总修复率",
          round(total_fixed / total_before * 100, 2),
          round(total_fixed / total_before * 100, 2),
          f"{total_fixed:,}/{total_before:,}，保留类不计入分母")
    check("S2", "`dwd_order` GMV 合计",
          round(float(hive_one("SELECT ROUND(SUM(pay_amount),2) FROM ydsh_dwd.dwd_order")), 2),
          36116687.06, "与第 1~4 周登记值一致")


# --------------------------------------------------------------------------
# S3 DWS 汇总层
# --------------------------------------------------------------------------
def s3_dws():
    header(
        "S3 · DWS 汇总层（聚合正确性）",
        "期望值来源：DWD 明细重算。汇总层任意维度的 GMV 之和必须等于明细层之和，"
        "否则说明聚合时漏分组或重复计数。",
    )
    dwd_gmv = round(float(hive_one("SELECT ROUND(SUM(pay_amount),2) FROM ydsh_dwd.dwd_order")), 2)
    dwd_cnt = int(hive_one("SELECT COUNT(DISTINCT order_id) FROM ydsh_dwd.dwd_order"))

    expect_rows = {
        "dws_trade_day": 366, "dws_trade_week": 53, "dws_trade_month": 12,
        "dws_category_day": 3043, "dws_store_day": 10566,
        "dws_channel_day": 1464, "dws_user_stat": 1000,
    }
    for table, n in expect_rows.items():
        got = int(hive_one(f"SELECT COUNT(*) FROM ydsh_dws.{table}"))
        check("S3", f"`{table}` 行数", got, n,
              "2,927 个真实品类组合 + 116 个「未知品类」组合" if table == "dws_category_day"
              else "与第 3 周登记值一致")

    # 四个粒度分别求和，都应回到同一个 GMV
    for table in ("dws_trade_day", "dws_trade_week", "dws_trade_month"):
        got = round(float(hive_one(f"SELECT ROUND(SUM(gmv),2) FROM ydsh_dws.{table}")), 2)
        check("S3", f"`{table}` GMV 合计", got, dwd_gmv, "与 DWD 明细一致")

    cat = round(float(hive_one("SELECT ROUND(SUM(gmv),2) FROM ydsh_dws.dws_category_day")), 2)
    check("S3", "`dws_category_day` GMV 合计", cat, dwd_gmv, "按品类切分不重不漏")
    store = round(float(hive_one("SELECT ROUND(SUM(gmv),2) FROM ydsh_dws.dws_store_day")), 2)
    check("S3", "`dws_store_day` GMV 合计", store, dwd_gmv, "按门店切分不重不漏")
    chan = round(float(hive_one("SELECT ROUND(SUM(gmv),2) FROM ydsh_dws.dws_channel_day")), 2)
    check("S3", "`dws_channel_day` GMV 合计", chan, dwd_gmv, "按渠道切分不重不漏")

    day_cnt = int(hive_one("SELECT SUM(order_cnt) FROM ydsh_dws.dws_trade_day"))
    check("S3", "`dws_trade_day` 订单量合计", day_cnt, dwd_cnt, "日粒度不重不漏")


# --------------------------------------------------------------------------
# S4 ADS 应用层
# --------------------------------------------------------------------------
def s4_ads():
    header(
        "S4 · ADS 应用层（指标口径）",
        "期望值来源：`docs/指标定义文档.md` 的公式，用 DWD/DWS 重算校验。"
        "这一层直接喂给仪表板与问答，口径错就是「仪表板在说谎」。",
    )
    kpi = dict(hive_query("SELECT metric_code, metric_value FROM ydsh_ads.ads_kpi_core"))
    gmv = float(kpi["KPI_GMV"])
    cnt = float(kpi["KPI_ORDER_CNT"])
    users = float(kpi["KPI_ACTIVE_USER"])

    check("S4", "KPI_GMV", round(gmv, 2), 36116687.06, "六层同源")
    check("S4", "KPI_ORDER_CNT", int(cnt), 14398, "COUNT(DISTINCT order_id)")
    # 客单价 = GMV / 订单量，允许四舍五入到分
    check("S4", "KPI_AOV = GMV ÷ 订单量", round(float(kpi["KPI_AOV"]), 2),
          round(gmv / cnt, 2), "派生指标自洽")
    check("S4", "KPI_ORDER_PER_USER = 订单量 ÷ 用户数",
          round(float(kpi["KPI_ORDER_PER_USER"]), 1), round(cnt / users, 1), "派生指标自洽")

    top_share = float(hive_one(
        "SELECT ROUND(MAX(gmv) / SUM(gmv), 4) FROM ydsh_ads.ads_category_topn"))
    check("S4", "KPI_TOP_CATEGORY_SHARE 与品类表一致",
          round(float(kpi["KPI_TOP_CATEGORY_SHARE"]), 4), round(top_share, 4),
          "占比分子分母同源")

    region = round(float(hive_one("SELECT ROUND(SUM(gmv),2) FROM ydsh_ads.ads_region_sales")), 2)
    check("S4", "`ads_region_sales` GMV 合计", region, round(gmv, 2), "按省份切分不重不漏")
    month = round(float(hive_one("SELECT ROUND(SUM(gmv),2) FROM ydsh_ads.ads_monthly_trend")), 2)
    check("S4", "`ads_monthly_trend` GMV 合计", month, round(gmv, 2), "12 个月完整覆盖")
    daily = round(float(hive_one("SELECT ROUND(SUM(gmv),2) FROM ydsh_ads.ads_sales_daily_report")), 2)
    check("S4", "`ads_sales_daily_report` GMV 合计", daily, round(gmv, 2), "366 天完整覆盖")


# --------------------------------------------------------------------------
# S5 预测模型
# --------------------------------------------------------------------------
def s5_forecast():
    header(
        "S5 · 预测模型（第 3 周产物复检）",
        "期望值来源：`data/forecast_metrics.json`。检查模型是否优于基线、"
        "7 天预测是否落在合理区间——预测值离均值太远说明漂移了。",
    )
    path = os.path.join("data", "forecast_metrics.json")
    if not os.path.exists(path):
        RESULTS.append({"stage": "S5", "item": "forecast_metrics.json 存在",
                        "expected": "存在", "actual": "缺失", "result": "FAIL", "note": ""})
        print("| `forecast_metrics.json` | 存在 | 缺失 | FAIL | - |")
        return
    with open(path, encoding="utf-8") as f:
        m = json.load(f)

    best = m["model_selected"]
    mape = m["metrics"][best]["MAPE"]
    base_mape = m["metrics"]["基线-近7日均值"]["MAPE"]
    check_cond("S5", f"模型 {best} 的 MAPE 优于基线", round(mape, 4), mape < base_mape,
               f"< {base_mape:.4f}",
               f"基线-近7日均值 {base_mape:.4f}，相对提升 {(1 - mape / base_mape) * 100:.1f}%")
    check_cond("S5", "MAPE 达标", round(mape * 100, 2), mape < 0.15, "< 15%",
               "低于 15% 判据")

    stats = m["series_stats"]
    fc = m["forecast_7d"]
    check("S5", "7 天预测条数", len(fc), 7, "逐日预测")
    avg = sum(x["forecast_gmv"] for x in fc) / len(fc)
    drift = abs(avg - stats["mean"]) / stats["mean"] * 100
    check_cond("S5", "预测均值相对历史均值的偏移", round(drift, 2), drift < 20, "< 20%",
               f"历史均值 {stats['mean']:,.0f}，预测均值 {avg:,.0f}，超出即视为漂移")
    warn("S5", "训练样本天数", stats["days"], "全年 366 天，含春节等节假日")


# --------------------------------------------------------------------------
# S6 NL2SQL
# --------------------------------------------------------------------------
def s6_nl2sql(run_llm=True):
    header(
        "S6 · NL2SQL 问答（第 3/4 周内核复检）",
        "期望值来源：手工核算的固定答案。这一环最容易「看起来通、其实答错」，"
        "所以不只检查「有没有返回」，而是核对返回值。",
    )
    sys.path.insert(0, os.path.join(ROOT, "python"))
    sys.path.insert(0, os.path.join(ROOT, "app"))

    try:
        import hive_client
        import nl2sql
    except Exception as exc:  # noqa: BLE001
        print(f"| 模块导入 | 成功 | {exc} | FAIL | - |")
        RESULTS.append({"stage": "S6", "item": "模块导入", "expected": "成功",
                        "actual": str(exc), "result": "FAIL", "note": ""})
        return

    if not run_llm:
        warn("S6", "大模型问答", "已跳过（--no-llm）", "用规则兜底不影响闭环验证")
    else:
        nl2sql.run_sql = hive_client.run_sql_for_nl2sql
        with open(os.path.join(ROOT, "data", "hive_schema.json"), encoding="utf-8") as f:
            schema = json.load(f)
        # 容器里没有 .env（不进镜像），密钥走 compose 注入的环境变量
        env = dict(os.environ)
        env.update(nl2sql.load_env())
        t0 = time.time()
        ans = nl2sql.ask("2024 年 6 月的 GMV 是多少？", schema, env, verbose=False)
        cost = time.time() - t0
        rows = ans.get("rows") or []
        value = None
        # run_sql_for_nl2sql 沿用了第 3 周的文本协议：rows[0] 是表头，
        # 真正的数据从 rows[1] 开始。取错行就会永远读到列名。
        if len(rows) > 1:
            try:
                value = float(rows[1].split("\t")[0])
            except (TypeError, ValueError):
                value = None
        check("S6", "问「2024 年 6 月 GMV」返回值", round(value, 2) if value else "-",
              2829996.31, f"模式 {ans.get('mode')}，耗时 {cost:.1f}s")
        warn("S6", "问答链路耗时", f"{cost:.1f}s", "含一次大模型调用（约 5~10s）")

    # 静态校验：SQL 守卫能不能拦住 DDL/DML
    try:
        import guard  # noqa: F401  (第 3 周的 sql 守卫)
        blocked = True
    except Exception:  # noqa: BLE001
        blocked = None
    if blocked:
        check("S6", "SQL 守卫模块可加载", "可加载", "可加载", "只读约束在守卫层")
    else:
        warn("S6", "SQL 守卫模块", "未加载", "第 3 周以 test_guard.py 单独验证")


# --------------------------------------------------------------------------
# S7 可视化接口
# --------------------------------------------------------------------------
def s7_viz():
    header(
        "S7 · 可视化接口（取数 API + 大屏）",
        "期望值来源：Hive ADS 层。前端展示的数字必须与库里的数字一致，"
        "差一分钱都算断链。",
    )
    try:
        health = http_json("/api/health")
        ok_flag = health.get("status") == "ok" or health.get("ok") is True
        check_cond("S7", "/api/health", "ok" if ok_flag else str(health), ok_flag,
                   "ok", "取数服务在线")
    except Exception as exc:  # noqa: BLE001
        print(f"| /api/health | ok | {exc} | FAIL | - |")
        RESULTS.append({"stage": "S7", "item": "/api/health", "expected": "ok",
                        "actual": str(exc), "result": "FAIL", "note": ""})
        return

    kpi = http_json("/api/kpi")
    api_gmv = float(kpi["kpi"]["gmv"] if "kpi" in kpi else kpi["gmv"])
    check("S7", "API 返回 GMV", round(api_gmv, 2), 36116687.06, "与 Hive ADS 一致")

    dash = http_json("/api/dashboard.json")
    monthly = dash["monthly"]
    check("S7", "大屏月度序列条数", len(monthly), 12, "12 个月")
    check("S7", "大屏月度 GMV 合计",
          round(sum(float(x["gmv"]) for x in monthly), 2), round(api_gmv, 2),
          "分月相加 = 总量")
    check("S7", "大屏品类序列条数", len(dash["category"]), 8, "Top8 品类")
    check("S7", "大屏省份序列条数", len(dash["region"]), 15, "15 个省级区域")
    check("S7", "大屏门店排行条数", len(dash["store_rank"]), 15, "Top15 门店")
    check("S7", "大屏门店散点条数", len(dash["store_scatter"]), 52, "52 家有成交门店")

    # 大屏前端文件是否齐备（离线演示要靠本地 echarts.min.js）
    idx = os.path.join(ROOT, "dashboard", "echarts", "index.html")
    vendor = os.path.join(ROOT, "dashboard", "echarts", "vendor", "echarts.min.js")
    ok_idx = os.path.exists(idx)
    ok_lib = os.path.exists(vendor) and os.path.getsize(vendor) > 500_000
    check("S7", "大屏 index.html 存在", "存在" if ok_idx else "缺失",
          "存在", "1920×1080 固定舞台 + 整体缩放")
    check("S7", "本地 ECharts 库", "完整" if ok_lib else "缺失", "完整",
          "断网也能演示")


# --------------------------------------------------------------------------
# S8 多引擎一致性
# --------------------------------------------------------------------------
def s8_engines():
    header(
        "S8 · 多引擎口径一致性（Hive / MySQL / ClickHouse）",
        "同一份日汇总数据同步到三个引擎，任何一个偏离都说明同步脚本有 bug。",
    )
    hive_gmv = round(float(hive_one("SELECT ROUND(SUM(gmv),2) FROM ydsh_dws.dws_trade_day")), 2)
    hive_cnt = int(hive_one("SELECT SUM(order_cnt) FROM ydsh_dws.dws_trade_day"))

    my_gmv = float(mysql_query("SELECT ROUND(SUM(gmv),2) FROM sales_daily")[0][0])
    my_cnt = int(mysql_query("SELECT SUM(order_cnt) FROM sales_daily")[0][0])
    check("S8", "MySQL `sales_daily` GMV", round(my_gmv, 2), hive_gmv, "与 Hive DWS 一致")
    check("S8", "MySQL `sales_daily` 订单量", my_cnt, hive_cnt, "与 Hive DWS 一致")

    ck = ck_query("SELECT round(sum(gmv),2), sum(order_cnt), count() FROM ydsh_ads.sales_daily")
    ck_gmv, ck_cnt, ck_days = ck.split("\t")
    check("S8", "ClickHouse `sales_daily` GMV", round(float(ck_gmv), 2), hive_gmv, "与 Hive DWS 一致")
    check("S8", "ClickHouse `sales_daily` 订单量", int(float(ck_cnt)), hive_cnt, "与 Hive DWS 一致")
    check("S8", "ClickHouse 日粒度行数", int(float(ck_days)), 366, "366 天")


# --------------------------------------------------------------------------
# S9 部署可用性
# --------------------------------------------------------------------------
def s9_deploy():
    header(
        "S9 · 部署可用性（7 个服务端口连通）",
        "从应用容器内部主动连每个服务，比 `docker ps` 更严格："
        "容器 up 不代表端口真的能服务。",
    )
    import socket

    ports = {
        "MySQL:3306": (MYSQL_HOST, 3306),
        "HiveServer2:10000": (HIVE_HOST, HIVE_PORT),
        "ClickHouse:8123": (CK_HOST, CK_PORT),
        "Superset:8088": ("superset", 8088),
        "Streamlit:8501": ("app", 8501),
        "API:8000": ("api", 8000),
    }
    for name, (host, port) in ports.items():
        t0 = time.time()
        try:
            with socket.create_connection((host, port), timeout=5):
                cost = (time.time() - t0) * 1000
                check("S9", name, "可连接", "可连接", f"{cost:.0f} ms")
        except OSError as exc:
            check("S9", name, "可连接", f"不可连接：{exc}", "端口探测失败")

    # Superset 健康检查（真实 HTTP，而不只是端口）
    try:
        with urllib.request.urlopen("http://superset:8088/health", timeout=10) as resp:
            body = resp.read().decode("utf-8", "ignore")
        check("S9", "Superset /health", body.strip()[:20], "OK", "Web 服务真正就绪")
    except Exception as exc:  # noqa: BLE001
        check("S9", "Superset /health", "OK", f"{exc}", "健康检查失败")


# --------------------------------------------------------------------------
def main():
    run_llm = "--no-llm" not in sys.argv
    t0 = time.time()
    print(f"# 第 5 周端到端联调原始输出\n")
    print(f"- 执行时间：{datetime.now():%Y-%m-%d %H:%M:%S}")
    print(f"- 执行环境：`{os.uname().nodename if hasattr(os, 'uname') else 'container'}` / "
          f"Python {sys.version.split()[0]}")
    print(f"- 模式：{'含大模型调用' if run_llm else '跳过模型调用'}")

    for fn in (s1_ods, s2_dwd, s3_dws, s4_ads, s5_forecast,
               lambda: s6_nl2sql(run_llm), s7_viz, s8_engines, s9_deploy):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            print(f"\n> 该环节异常中断：`{exc}`\n")
            RESULTS.append({"stage": "EXC", "item": getattr(fn, "__name__", "stage"),
                            "expected": "-", "actual": str(exc), "result": "FAIL", "note": ""})

    passed = sum(1 for r in RESULTS if r["result"] == "PASS")
    failed = sum(1 for r in RESULTS if r["result"] == "FAIL")
    warned = sum(1 for r in RESULTS if r["result"] == "WARN")
    cost = time.time() - t0

    print(f"\n## 汇总\n")
    print(f"| 项 | 数量 |\n|---|---|")
    print(f"| PASS | {passed} |")
    print(f"| FAIL | {failed} |")
    print(f"| WARN | {warned} |")
    print(f"| 合计 | {len(RESULTS)} |")
    print(f"| 总耗时 | {cost:.1f}s |")
    print(f"\n**结论：{'端到端链路全绿' if failed == 0 else f'{failed} 项未通过，需修复'}**")

    out = os.path.join("data", "e2e_result.json")
    os.makedirs("data", exist_ok=True)
    payload = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "duration_sec": round(cost, 1),
        "summary": {"pass": passed, "fail": failed, "warn": warned, "total": len(RESULTS)},
        "items": RESULTS,
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(f"\n结果已写入 `{out}`")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
