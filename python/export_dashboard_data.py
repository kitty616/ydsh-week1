#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
export_dashboard_data.py —— 为大屏与 Streamlit 导出可视化数据（JSON）

为什么单独导一份 JSON，而不是让前端直连 Hive：
  1. 浏览器不能直连 HiveServer2（thrift 协议），必须有一个出口；
  2. 大屏是纯静态页面，做成「导出快照 + 前端只读」后，断网也能演示，
     不会出现答辩现场因为网络/容器没起来而白屏；
  3. JSON 里的每个数字都能追溯到具体 SQL，改口径只需重跑本脚本。

数据来源（全部为四层数仓的真实产物）：
  ydsh_ads.ads_kpi_core            10 项核心指标
  ydsh_ads.ads_monthly_trend       12 个月趋势
  ydsh_ads.ads_sales_daily_report  366 天日序列
  ydsh_ads.ads_category_topn       品类 TOP8
  ydsh_ads.ads_region_sales        15 个省级区域
  ydsh_ads.ads_store_rank          门店排名
  ydsh_ads.ads_channel_sales       渠道占比
  ydsh_dwd.dwd_order + dim_pay_type          支付方式占比（现算）
  ydsh_dwd.dwd_order + item + dim_product    时段 × 品类热力图（现算）
  ydsh_dws.dws_store_day + dim_store          门店散点（GMV–客单价相关性）

用法：
  python python/export_dashboard_data.py
  python python/export_dashboard_data.py --out dashboard/echarts/data/dashboard.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime

CONTAINER = os.environ.get("YDSH_HIVE_CONTAINER", "ydsh-hive-server")
NOISE = ("SLF4J", "[WARN]", "Logging", "No such file or directory", "SLF4J: See")


def query(sql: str, db: str = "default") -> list[dict]:
    """执行一条 Hive SQL，返回 [{列名: 值}]；空值统一成 None。"""
    cmd = [
        "docker", "exec", CONTAINER,
        "beeline", "-u", f"jdbc:hive2://localhost:10000/{db}",
        "--outputformat=tsv2", "--silent=true", "-e", sql,
    ]
    env = dict(os.environ, MSYS2_ARG_CONV_EXCL="*")
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=env, timeout=600)
    if r.returncode != 0:
        raise RuntimeError(f"beeline 失败：{r.stderr[-400:]}")

    lines = []
    for line in r.stdout.splitlines():
        s = line.rstrip("\r")
        if not s.strip() or s.startswith(NOISE):
            continue
        lines.append(s)

    if len(lines) < 2:
        return []
    header = [h.strip() for h in lines[0].split("\t")]
    rows = []
    for line in lines[1:]:
        cells = line.split("\t")
        if len(cells) < len(header):
            cells += [""] * (len(header) - len(cells))
        d = {}
        for k, v in zip(header, cells):
            v = v.strip()
            d[k] = None if v in ("", "NULL", "null", "\\N") else v
        rows.append(d)
    return rows


def f(v, default=0.0) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def i(v, default=0) -> int:
    return int(f(v, default))


def build() -> dict:
    print("▶ 查询核心 KPI ...")
    kpi_rows = query("SELECT metric_code, metric_name, metric_value, unit FROM ydsh_ads.ads_kpi_core", "ydsh_ads")
    kpi_map = {r["metric_code"]: r for r in kpi_rows}

    def kv(code, default=0.0):
        r = kpi_map.get(code)
        return f(r["metric_value"]) if r else default

    kpi = {
        "gmv": kv("KPI_GMV"),
        "order_cnt": int(kv("KPI_ORDER_CNT")),
        "aov": kv("KPI_AOV"),
        "active_user": int(kv("KPI_ACTIVE_USER")),
        "cancel_rate": kv("KPI_CANCEL_RATE"),
        "discount_rate": kv("KPI_DISCOUNT_RATE"),
        "repurchase_rate": kv("KPI_REPURCHASE_RATE"),
        "top_category_share": kv("KPI_TOP_CATEGORY_SHARE"),
    }

    print("▶ 查询月度趋势 / 日序列 ...")
    monthly = [
        {
            "month": r["month"],
            "gmv": round(f(r["gmv"]), 2),
            "order_cnt": i(r["order_cnt"]),
            "user_cnt": i(r["user_cnt"]),
            "aov": round(f(r["aov"]), 2),
            "mom_rate": None if r["mom_rate"] is None else round(f(r["mom_rate"]), 6),
        }
        for r in query("SELECT month, gmv, order_cnt, user_cnt, aov, mom_rate "
                       "FROM ydsh_ads.ads_monthly_trend ORDER BY month_seq", "ydsh_ads")
    ]

    daily = [
        {"dt": r["dt"], "gmv": round(f(r["gmv"]), 2),
         "order_cnt": i(r["order_cnt"]), "user_cnt": i(r["user_cnt"])}
        for r in query("SELECT dt, gmv, order_cnt, user_cnt "
                       "FROM ydsh_ads.ads_sales_daily_report ORDER BY dt", "ydsh_ads")
    ]

    print("▶ 查询品类 / 区域 / 渠道 / 门店排名 ...")
    category = [
        {"category": r["category"], "gmv": round(f(r["gmv"]), 2),
         "share": round(f(r["gmv_share"]), 6), "order_cnt": i(r["order_cnt"]),
         "item_qty": i(r["item_qty"])}
        for r in query("SELECT category, gmv, gmv_share, order_cnt, item_qty "
                       "FROM ydsh_ads.ads_category_topn ORDER BY rank_no", "ydsh_ads")
    ]

    region = [
        {"province": r["province"], "gmv": round(f(r["gmv"]), 2),
         "order_cnt": i(r["order_cnt"]), "user_cnt": i(r["user_cnt"]),
         "aov": round(f(r["aov"]), 2), "ratio": round(f(r["gmv_ratio"]), 6)}
        for r in query("SELECT province, gmv, order_cnt, user_cnt, aov, gmv_ratio "
                       "FROM ydsh_ads.ads_region_sales ORDER BY gmv DESC", "ydsh_ads")
    ]

    channel = [
        {"name": r["channel_name"], "gmv": round(f(r["gmv"]), 2),
         "order_cnt": i(r["order_cnt"]), "ratio": round(f(r["gmv_ratio"]), 6)}
        for r in query("SELECT channel_name, gmv, order_cnt, gmv_ratio "
                       "FROM ydsh_ads.ads_channel_sales ORDER BY gmv DESC", "ydsh_ads")
    ]

    store_rank = [
        {"rank": i(r["rank_no"]), "store_name": r["store_name"], "province": r["province"],
         "gmv": round(f(r["gmv"]), 2), "order_cnt": i(r["order_cnt"]),
         "aov": round(f(r["aov"]), 2)}
        for r in query("SELECT rank_no, store_name, province, gmv, order_cnt, aov "
                       "FROM ydsh_ads.ads_store_rank ORDER BY rank_no", "ydsh_ads")
    ]

    print("▶ 现算支付方式占比 ...")
    pay_type = []
    for r in query(
        "SELECT p.pay_name AS name, SUM(o.pay_amount) AS gmv, COUNT(*) AS cnt "
        "FROM ydsh_dwd.dwd_order o JOIN ydsh_dwd.dim_pay_type p "
        "ON o.pay_type_code = p.pay_code "
        "GROUP BY p.pay_name ORDER BY gmv DESC", "ydsh_dwd"
    ):
        pay_type.append({"name": r["name"], "gmv": round(f(r["gmv"]), 2), "cnt": i(r["cnt"])})
    pay_total = sum(x["gmv"] for x in pay_type) or 1.0
    for x in pay_type:
        x["ratio"] = round(x["gmv"] / pay_total, 6)

    print("▶ 现算时段 × 品类热力图 ...")
    # 口径说明（踩过的坑）：
    #   一开始用 SUM(quantity*unit_price) 做热力值，合计得到 6.17 亿，
    #   而订单实付合计只有 3,611 万，差 17 倍。核对发现明细表的 unit_price
    #   是商品标价（dim_product.price 口径），不等于成交价，用它做金额占比
    #   会整体失真。因此热力图改为「订单数」口径：COUNT(DISTINCT order_id)，
    #   既不受价格口径影响，也正好回答「哪个时段谁在下单」。
    heat_raw = query(
        "SELECT SUBSTR(o.order_timestamp, 12, 2) AS hh, p.category AS category, "
        "       COUNT(DISTINCT o.order_id) AS orders "
        "FROM ydsh_dwd.dwd_order o "
        "JOIN ydsh_dwd.dwd_order_item_clean i ON o.order_id = i.order_id "
        "JOIN ydsh_dwd.dim_product p ON i.product_id = p.product_id "
        "GROUP BY SUBSTR(o.order_timestamp, 12, 2), p.category", "ydsh_dwd"
    )
    cats = [c["category"] for c in category]
    hours = [f"{h:02d}" for h in range(24)]
    cat_idx = {c: n for n, c in enumerate(cats)}
    hm = {}
    for r in heat_raw:
        try:
            h = int(r["hh"])
        except (TypeError, ValueError):
            continue
        c = r["category"]
        if c not in cat_idx:
            continue
        hm[(h, cat_idx[c])] = hm.get((h, cat_idx[c]), 0) + i(r["orders"])

    # 行内归一化：value 用「该品类在该时段的订单 ÷ 该品类全天订单」的百分比。
    # 为什么不用绝对值：各品类的单量基数不同（运动户外 vs 母婴玩具差一个量级），
    # 绝对数画在同一张图上只有「大类整体更亮」，时段结构被埋掉；
    # 行内占比让每一行自己跟自己比，才能看出「哪个时段是这个品类的高峰」。
    row_sum = {}
    for (h, c), v in hm.items():
        row_sum[c] = row_sum.get(c, 0) + v
    heat_data = [
        [h, c, round(v / row_sum[c] * 100, 2) if row_sum.get(c) else 0, v]
        for (h, c), v in sorted(hm.items())
    ]
    heat_max = max((d[2] for d in heat_data), default=0)

    print("▶ 现算门店散点（GMV–客单价）...")
    scatter = []
    for r in query(
        "SELECT s.store_name AS name, s.province AS province, "
        "       SUM(d.gmv) AS gmv, SUM(d.order_cnt) AS cnt "
        "FROM ydsh_dws.dws_store_day d JOIN ydsh_dwd.dim_store s "
        "ON d.store_id = s.store_id "
        "GROUP BY s.store_name, s.province ORDER BY gmv DESC", "ydsh_dws"
    ):
        gmv, cnt = f(r["gmv"]), i(r["cnt"])
        scatter.append({
            "name": r["name"], "province": r["province"],
            "gmv": round(gmv, 2), "order_cnt": cnt,
            "aov": round(gmv / cnt, 2) if cnt else 0,
        })

    payload = {
        "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "source": {
            "engine": "Apache Hive 4.0.0 (Tez) / Docker",
            "layers": ["ydsh_ads（应用层指标）", "ydsh_dws（汇总层）", "ydsh_dwd（明细层）"],
            "period": "2024-01-01 ~ 2024-12-31",
            "reproduce": "python python/export_dashboard_data.py",
        },
        "kpi": kpi,
        "monthly": monthly,
        "daily": daily,
        "category": category,
        "region": region,
        "channel": channel,
        "pay_type": pay_type,
        "store_rank": store_rank,
        "store_scatter": scatter,
        "heatmap": {
            "hours": hours,
            "categories": cats,
            "metric": "orders",
            "data": heat_data,
            "max": heat_max,
        },
    }
    return payload


# 省份 → (ISO 3166-2, 英文名) 映射
# 为什么需要：BI 工具的中国地图底图按 ISO 码或英文名匹配区域，
# 而数仓里存的是中文「广东省」。这一步转换必须显式做，
# 靠工具自己模糊匹配会大量落到未着色区域（看起来像数据缺失）。
PROVINCE_MAP = {
    "北京市": ("CN-BJ", "Beijing"), "天津市": ("CN-TJ", "Tianjin"),
    "河北省": ("CN-HE", "Hebei"), "山西省": ("CN-SX", "Shanxi"),
    "内蒙古自治区": ("CN-NM", "Nei Mongol"), "辽宁省": ("CN-LN", "Liaoning"),
    "吉林省": ("CN-JL", "Jilin"), "黑龙江省": ("CN-HL", "Heilongjiang"),
    "上海市": ("CN-SH", "Shanghai"), "江苏省": ("CN-JS", "Jiangsu"),
    "浙江省": ("CN-ZJ", "Zhejiang"), "安徽省": ("CN-AH", "Anhui"),
    "福建省": ("CN-FJ", "Fujian"), "江西省": ("CN-JX", "Jiangxi"),
    "山东省": ("CN-SD", "Shandong"), "河南省": ("CN-HA", "Henan"),
    "湖北省": ("CN-HB", "Hubei"), "湖南省": ("CN-HN", "Hunan"),
    "广东省": ("CN-GD", "Guangdong"), "广西壮族自治区": ("CN-GX", "Guangxi"),
    "海南省": ("CN-HI", "Hainan"), "重庆市": ("CN-CQ", "Chongqing"),
    "四川省": ("CN-SC", "Sichuan"), "贵州省": ("CN-GZ", "Guizhou"),
    "云南省": ("CN-YN", "Yunnan"), "西藏自治区": ("CN-XZ", "Xizang"),
    "陕西省": ("CN-SN", "Shaanxi"), "甘肃省": ("CN-GS", "Gansu"),
    "青海省": ("CN-QH", "Qinghai"), "宁夏回族自治区": ("CN-NX", "Ningxia"),
    "新疆维吾尔自治区": ("CN-XJ", "Xinjiang"),
    "台湾省": ("CN-71", "Taiwan"), "香港特别行政区": ("CN-HK", "Hong Kong"),
    "澳门特别行政区": ("CN-MO", "Macao"),
}


def write_csvs(payload: dict, out_dir: str) -> None:
    """把同一份快照落成 CSV，供 MySQL / ClickHouse 服务层导入。

    列名直接用英文，和 Hive 侧字段保持同名，这样 Superset 建数据集时
    不需要再解释一遍字段含义，也方便和三方库做逐列对账。
    """
    import csv

    os.makedirs(out_dir, exist_ok=True)

    def dump(name, header, rows):
        path = os.path.join(out_dir, name)
        with open(path, "w", encoding="utf-8", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(header)
            w.writerows(rows)
        print(f"  ✓ {path}  {len(rows)} 行")

    dump("sales_daily.csv",
         ["dt", "gmv", "order_cnt", "user_cnt"],
         [[r["dt"], r["gmv"], r["order_cnt"], r["user_cnt"]] for r in payload["daily"]])

    dump("monthly.csv",
         ["month", "gmv", "order_cnt", "user_cnt", "aov", "mom_rate"],
         [[r["month"], r["gmv"], r["order_cnt"], r["user_cnt"], r["aov"],
           "" if r["mom_rate"] is None else r["mom_rate"]] for r in payload["monthly"]])

    dump("category.csv",
         ["category", "gmv", "share", "order_cnt", "item_qty"],
         [[r["category"], r["gmv"], r["share"], r["order_cnt"], r["item_qty"]]
          for r in payload["category"]])

    dump("region.csv",
         ["province", "iso", "name_en", "gmv", "order_cnt", "user_cnt", "aov", "ratio"],
         [[r["province"], *PROVINCE_MAP.get(r["province"], ("", "")),
           r["gmv"], r["order_cnt"], r["user_cnt"], r["aov"], r["ratio"]]
          for r in payload["region"]])

    dump("pay_type.csv",
         ["name", "gmv", "cnt", "ratio"],
         [[r["name"], r["gmv"], r["cnt"], r["ratio"]] for r in payload["pay_type"]])

    dump("store_rank.csv",
         ["rank_no", "store_name", "province", "gmv", "order_cnt", "aov"],
         [[r["rank"], r["store_name"], r["province"], r["gmv"], r["order_cnt"], r["aov"]]
          for r in payload["store_rank"]])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join("dashboard", "echarts", "data", "dashboard.json"))
    args = ap.parse_args()

    payload = build()
    out_dir = os.path.dirname(args.out)
    os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)

    # 同时写一份 .js 副本：直接用浏览器打开 index.html（file:// 协议）时，
    # fetch 本地 JSON 会被 CORS 拦掉，而 <script> 引入不受限制。
    # 大屏优先请求后端 /api/dashboard.json，失败时才回落到这份内嵌快照。
    js_path = os.path.join(out_dir, "dashboard.js")
    with open(js_path, "w", encoding="utf-8") as fh:
        fh.write("// 由 python/export_dashboard_data.py 自动生成，请勿手工修改\n")
        fh.write("window.DASHBOARD_DATA = ")
        json.dump(payload, fh, ensure_ascii=False)
        fh.write(";\n")

    # 再落一份服务层用的 CSV（MySQL / ClickHouse 导入用）。
    # 为什么从 JSON 反写而不是重新查一遍 Hive：保证大屏、BI、服务层
    # 三处数字来自同一次取数，避免「同一指标三个值」。
    csv_dir = os.environ.get("YDSH_CSV_DIR", "data/serving")
    write_csvs(payload, csv_dir)

    k = payload["kpi"]
    print(f"\n✓ 已写出 {args.out}")
    print(f"  GMV {k['gmv']:,.2f} 元 / 订单 {k['order_cnt']:,} 单 / 客单价 {k['aov']:,.2f} 元")
    print(f"  日序列 {len(payload['daily'])} 天，月度 {len(payload['monthly'])} 个月，"
          f"品类 {len(payload['category'])} 个，区域 {len(payload['region'])} 个，"
          f"门店 {len(payload['store_scatter'])} 家")
    print(f"  热力格 {len(payload['heatmap']['data'])} 个，支付方式 {len(payload['pay_type'])} 种")


if __name__ == "__main__":
    sys.exit(main())
