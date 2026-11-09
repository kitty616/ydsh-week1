#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
schema_extract.py —— 从 Hive 自动抽取表结构，生成供大模型理解的数据库元信息

为什么不用 pyhive：
  Windows 上 pyhive 依赖的 sasl 需要 C 编译环境，装不上；
  改用 beeline（Hive 自带客户端）执行 DESCRIBE，效果等价。

为什么还要手工补业务语义：
  Hive metastore 里的字段注释在容器 locale 下会输出成乱码，
  而字段名的英文缩写对大模型来说信息量不足（status_code 到底是订单状态还是商品状态？）。
  所以「结构自动抽 + 语义人工补」，语义字典见 TABLE_META。
"""
import json
import os
import re
import subprocess

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(BASE, "data", "hive_schema.json")
CONTAINER = "ydsh-hive-server"

# 参与 NL2SQL 的表（只暴露必要的，避免模型去查一堆中间表）
TABLES = [
    ("ydsh_ads", "ads_kpi_core"),
    ("ydsh_ads", "ads_sales_daily_report"),
    ("ydsh_ads", "ads_category_topn"),
    ("ydsh_ads", "ads_user_segment"),
    ("ydsh_ads", "ads_monthly_trend"),
    ("ydsh_dws", "dws_trade_day"),
    ("ydsh_dws", "dws_trade_month"),
    ("ydsh_dws", "dws_category_day"),
    ("ydsh_dws", "dws_store_day"),
    ("ydsh_dws", "dws_channel_day"),
    ("ydsh_dwd", "dwd_order"),
    ("ydsh_dwd", "dim_product"),
    ("ydsh_dwd", "dim_store"),
    ("ydsh_dwd", "dim_channel"),
]

# 业务语义字典：告诉模型这张表是干什么的、字段的中文含义
TABLE_META = {
    "ads_kpi_core": ("核心 KPI 指标长表，每个指标一行，含口径说明",
                     {"metric_code": "指标编码，如 KPI_GMV",
                      "metric_name": "指标中文名，如 GMV 成交总额",
                      "metric_value": "指标值（数值）",
                      "unit": "单位",
                      "calc_rule": "计算口径说明"}),
    "ads_sales_daily_report": ("销售日报，每天一行，含环比与 7 日移动平均",
                               {"dt": "日期 yyyy-MM-dd",
                                "gmv": "当日成交总额（元）",
                                "order_cnt": "当日订单量",
                                "user_cnt": "当日下单用户数",
                                "aov": "当日客单价（元/单）",
                                "dod_rate": "GMV 日环比（小数）",
                                "wow_rate": "GMV 周同比（对 7 天前，小数）",
                                "ma7_gmv": "近 7 日 GMV 移动平均"}),
    "ads_category_topn": ("品类销售排名，按全年 GMV 降序",
                          {"rank_no": "排名，1 为最高",
                           "category": "一级品类名称",
                           "gmv": "该品类全年 GMV（元）",
                           "gmv_share": "占全站 GMV 比重（小数）",
                           "cum_share": "累计占比，帕累托分析用",
                           "order_cnt": "关联订单数",
                           "item_qty": "销售件数",
                           "avg_item_price": "件单价（元/件）"}),
    "ads_user_segment": ("用户价值分层汇总（基于 RFM）",
                         {"user_segment": "用户分层名称，如 重要价值用户",
                          "user_cnt": "该层用户数",
                          "user_share": "用户占比",
                          "gmv": "该层 GMV",
                          "gmv_share": "GMV 占比",
                          "avg_gmv": "人均 GMV",
                          "avg_order_cnt": "人均订单数"}),
    "ads_monthly_trend": ("月度经营趋势",
                          {"month": "月份 yyyy-MM",
                           "month_seq": "月份序号 1-12",
                           "gmv": "当月 GMV",
                           "order_cnt": "当月订单量",
                           "user_cnt": "当月下单用户数",
                           "aov": "当月客单价",
                           "mom_rate": "GMV 环比（小数）",
                           "gmv_share": "占全年 GMV 比重"}),
    "dws_trade_day": ("天粒度全站交易汇总，按日期分区表",
                      {"dt": "日期 yyyy-MM-dd（与 order_date 同值）",
                       "gmv": "成交总额",
                       "order_cnt": "订单量",
                       "user_cnt": "下单用户数",
                       "store_cnt": "有成交门店数",
                       "discount_sum": "优惠金额合计",
                       "cancel_cnt": "取消订单数",
                       "aov": "客单价"}),
    "dws_trade_month": ("月粒度交易汇总",
                        {"month": "月份 yyyy-MM", "gmv": "成交总额",
                         "order_cnt": "订单量", "user_cnt": "下单用户数",
                         "aov": "客单价", "cancel_cnt": "取消订单数", "mom_rate": "GMV 环比"}),
    "dws_category_day": ("天×品类销售汇总，GMV 已按订单实付金额分摊",
                         {"dt": "日期", "category": "一级品类",
                          "order_cnt": "关联订单数", "item_qty": "销售件数", "gmv": "分摊后成交金额"}),
    "dws_store_day": ("天×门店销售汇总",
                      {"dt": "日期", "store_id": "门店编号", "gmv": "成交总额",
                       "order_cnt": "订单量", "user_cnt": "下单用户数", "aov": "客单价"}),
    "dws_channel_day": ("天×渠道销售汇总",
                        {"dt": "日期", "channel_code": "渠道编码（关联 dim_channel）",
                         "gmv": "成交总额", "order_cnt": "订单量",
                         "user_cnt": "下单用户数", "aov": "客单价"}),
    "dwd_order": ("订单事实表（明细粒度，已清洗），按 order_date 分区",
                  {"order_id": "订单号", "user_id": "用户编号", "store_id": "门店编号",
                   "order_timestamp": "下单时间 yyyy-MM-dd HH:mm:ss",
                   "pay_amount": "实付金额（元）", "discount_amount": "优惠金额",
                   "pay_type_code": "支付方式编码", "order_status_code": "订单状态编码（OS04=已取消）",
                   "channel_code": "渠道编码", "order_cnt": "固定为 1，用于计数",
                   "order_date": "订单日期 yyyy-MM-dd，分区字段"}),
    "dim_product": ("商品维度表",
                    {"product_id": "商品编号", "category": "一级品类",
                     "brand": "品牌", "price": "吊牌价"}),
    "dim_store": ("门店维度表",
                  {"store_id": "门店编号", "store_name": "门店名称",
                   "province": "省份", "city": "城市"}),
    "dim_channel": ("渠道维度表",
                    {"channel_code": "渠道编码", "channel_name": "渠道名称"}),
}


def beeline(sql, db="default"):
    """调用容器内的 beeline 执行 SQL，返回 TSV 文本行"""
    cmd = ["docker", "exec", CONTAINER, "beeline",
           "-u", f"jdbc:hive2://localhost:10000/{db}",
           "--silent=true", "--outputformat=tsv2", "-e", sql]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    lines = []
    for ln in r.stdout.splitlines():
        if not ln.strip() or ln.startswith("SLF4J") or "beeline" in ln.lower():
            continue
        lines.append(ln)
    return lines


def extract():
    schema = {}
    for db, tbl in TABLES:
        rows = beeline(f"DESCRIBE {db}.{tbl}", db)
        cols = []
        for ln in rows[1:]:                      # 跳过表头
            parts = ln.split("\t")
            if len(parts) < 2 or not parts[0].strip():
                continue
            name, dtype = parts[0].strip(), parts[1].strip()
            if name.startswith("#") or dtype == "NULL":
                continue
            cols.append({"name": name, "type": dtype})
        desc, col_meta = TABLE_META.get(tbl, ("", {}))
        schema[f"{db}.{tbl}"] = {
            "table": tbl,
            "db": db,
            "description": desc,
            "columns": [dict(c, comment=col_meta.get(c["name"], "")) for c in cols],
        }
        print(f"  {db}.{tbl:<28} {len(cols):>2} 列")

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(schema, f, ensure_ascii=False, indent=2)
    print(f"\n已写入 {OUT}（{len(schema)} 张表）")
    return schema


def render_prompt_schema(schema):
    """把 schema 渲染成给大模型看的紧凑文本"""
    out = []
    for full, meta in schema.items():
        out.append(f"-- {full}（{meta['description']}）")
        cols = []
        for c in meta["columns"]:
            piece = f"{c['name']} {c['type']}"
            if c["comment"]:
                piece += f"  // {c['comment']}"
            cols.append(piece)
        out.append("   " + ",\n   ".join(cols))
        out.append("")
    return "\n".join(out)


if __name__ == "__main__":
    print("抽取 Hive 表结构：")
    s = extract()
    txt = render_prompt_schema(s)
    with open(os.path.join(BASE, "data", "schema_prompt.txt"), "w", encoding="utf-8") as f:
        f.write(txt)
    print(f"\nPrompt 版 schema 已写入 data/schema_prompt.txt（{len(txt)} 字符）")
