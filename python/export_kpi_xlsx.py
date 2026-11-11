#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
export_kpi_xlsx.py —— 从 Hive ADS 层导出第 3 周 KPI 指标结果表（.xlsx）

为什么不手工贴数：作业要求「KPI 指标结果表」必须是 ADS 层的真实执行结果，
手抄一遍就失去了与 SQL 的可追溯关系。这里直接查 beeline，数值与
sql/ads/60_build_ads_kpi.sql、61_build_ads_app.sql 的产物一一对应。

产出 4 个工作表：
  1. 核心KPI       ads_kpi_core        10 项指标的取值、单位与口径
  2. 月度趋势      ads_monthly_trend   12 个月的 GMV / 单量 / 人数 / 客单价 / 环比 / 占比
  3. 品类TOP       ads_category_topn   8 个品类的 GMV 排名与累计占比
  4. 用户分层      ads_user_segment     5 个价值分层的用户数与贡献

用法：
  python python/export_kpi_xlsx.py
  python python/export_kpi_xlsx.py --out docs/第3周_KPI指标结果表.xlsx
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

CONTAINER = os.environ.get("YDSH_HIVE_CONTAINER", "ydsh-hive-server")
DB = "ydsh_ads"

HEAD_FILL = PatternFill("solid", fgColor="DCE6F1")
TITLE_FONT = Font(name="微软雅黑", size=13, bold=True, color="1F3864")
HEAD_FONT = Font(name="微软雅黑", size=10, bold=True, color="1F3864")
BODY_FONT = Font(name="微软雅黑", size=10)
THIN = Side(style="thin", color="9BA7B8")
BORDER = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)


def query(sql: str) -> list[list[str]]:
    """跑一条 Hive SQL，返回二维字符串列表（含表头行）。"""
    cmd = [
        "docker", "exec", CONTAINER,
        "beeline", "-u", f"jdbc:hive2://localhost:10000/{DB}",
        "--outputformat=tsv2", "--silent=true", "-e", sql,
    ]
    env = dict(os.environ, MSYS2_ARG_CONV_EXCL="*")
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=env, timeout=300)
    if r.returncode != 0:
        raise RuntimeError(f"beeline 失败：{r.stderr[-500:]}")

    rows = []
    for line in r.stdout.splitlines():
        s = line.strip()
        if not s or s.startswith("SLF4J") or s.startswith("[WARN]") or s.startswith("Logging"):
            continue
        rows.append(s.split("\t"))
    if not rows:
        raise RuntimeError(f"查询无结果：{sql}")
    # 去掉 beeline 的表名前缀（ads_kpi_core.metric_code -> metric_code）
    head = [c.split(".")[-1] for c in rows[0]]
    return [head] + rows[1:]


def fill_sheet(ws, title, subtitle, data, widths, num_cols=None, pct_cols=None):
    """统一的表头 / 标题 / 边框排版。"""
    ncol = len(data[0])
    ws.merge_cells(start_row=1, start_column=1, end_row=1, end_column=ncol)
    c = ws.cell(row=1, column=1, value=title)
    c.font = TITLE_FONT
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[1].height = 26

    ws.merge_cells(start_row=2, start_column=1, end_row=2, end_column=ncol)
    c = ws.cell(row=2, column=1, value=subtitle)
    c.font = Font(name="微软雅黑", size=9, italic=True, color="595959")
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[2].height = 18

    for j, h in enumerate(data[0], start=1):
        c = ws.cell(row=4, column=j, value=h)
        c.font = HEAD_FONT
        c.fill = HEAD_FILL
        c.border = BORDER
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    ws.row_dimensions[4].height = 24

    for i, row in enumerate(data[1:], start=5):
        for j, v in enumerate(row, start=1):
            val = v
            if v not in ("", "NULL"):
                if num_cols and j in num_cols:
                    try:
                        val = float(v)
                    except ValueError:
                        val = v
                elif pct_cols and j in pct_cols:
                    try:
                        val = float(v)
                    except ValueError:
                        val = v
            c = ws.cell(row=i, column=j, value=val)
            c.font = BODY_FONT
            c.border = BORDER
            if isinstance(val, float):
                if pct_cols and j in pct_cols:
                    c.number_format = "0.00%"
                    c.alignment = Alignment(horizontal="center")
                elif abs(val) >= 1000:
                    c.number_format = "#,##0.00"
                    c.alignment = Alignment(horizontal="right")
                else:
                    c.number_format = "0.00##"
                    c.alignment = Alignment(horizontal="center")
            elif j == 1 or (num_cols is None and len(str(val)) < 12):
                c.alignment = Alignment(horizontal="left" if j == len(row) else "center",
                                        vertical="center", wrap_text=True)
            else:
                c.alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)

    for j, w in enumerate(widths, start=1):
        ws.column_dimensions[get_column_letter(j)].width = w
    ws.freeze_panes = "A5"


def fmt_kpi_value(code, raw):
    """按指标语义决定取值怎么写：金额、比率、计数各用各的写法。"""
    if raw in ("", "NULL"):
        return "—"
    v = float(raw)
    if code == "KPI_GMV":
        return f"{v / 10000:,.2f} 万元"
    if code in ("KPI_CANCEL_RATE", "KPI_REPURCHASE_RATE", "KPI_DISCOUNT_RATE",
                "KPI_TOP_CATEGORY_SHARE", "KPI_ONCE_BUYER_RATIO"):
        return f"{v * 100:.2f}%"
    if code in ("KPI_ACTIVE_USER", "KPI_ORDER_CNT"):
        return f"{v:,.0f}"
    if code == "KPI_AOV":
        return f"{v:,.2f}"
    if code == "KPI_ORDER_PER_USER":
        return f"{v:,.1f}"
    return raw


def build(out_path: str):
    wb = Workbook()

    # ---- 1. 核心 KPI ----
    kpi = query("SELECT metric_code, metric_name, metric_value, unit, calc_rule "
                "FROM ads_kpi_core ORDER BY metric_code")
    kpi[0] = ["指标编码", "指标名称", "取值", "单位", "口径定义"]
    for r in kpi[1:]:
        r[2] = fmt_kpi_value(r[0], r[2])
        if r[0] == "KPI_GMV":
            r[3] = "万元"  # 取值按万元展示，单位栏同步，避免「元」与「万元」打架

    ws = wb.active
    ws.title = "核心KPI"
    fill_sheet(
        ws, "第 3 周 KPI 指标结果表 · 核心指标",
        "来源：Hive ydsh_ads.ads_kpi_core（由 sql/ads/60_build_ads_kpi.sql 生成）　观察期：2024-01-01 ~ 2024-12-31",
        kpi, widths=[24, 22, 16, 9, 64],
    )

    # ---- 2. 月度趋势 ----
    mon = query("SELECT month, month_seq, gmv, order_cnt, user_cnt, aov, mom_rate, gmv_share "
                "FROM ads_monthly_trend ORDER BY month_seq")
    mon[0] = ["月份", "序号", "GMV（元）", "订单量", "下单用户数", "客单价（元）", "环比", "GMV 占比"]
    for r in mon[1:]:
        for idx in (6, 7):  # 环比、占比转百分比
            if r[idx] in ("NULL", ""):
                r[idx] = "—"
            else:
                r[idx] = f"{float(r[idx]) * 100:.2f}%"

    ws2 = wb.create_sheet("月度趋势")
    fill_sheet(
        ws2, "第 3 周 KPI 指标结果表 · 月度趋势",
        "来源：Hive ydsh_ads.ads_monthly_trend　序号 1 的环比为空（无上一月可比）",
        mon, widths=[12, 9, 15, 11, 12, 13, 11, 11],
        num_cols={2, 3, 4, 5, 6},
    )

    # ---- 3. 品类 TOP ----
    cat = query("SELECT rank_no, category, gmv, gmv_share, cum_share, order_cnt, item_qty, avg_item_price "
                "FROM ads_category_topn ORDER BY rank_no")
    cat[0] = ["排名", "品类", "GMV（元）", "GMV 占比", "累计占比", "订单量", "商品件数", "件单价（元）"]
    for r in cat[1:]:
        for idx in (3, 4):
            r[idx] = f"{float(r[idx]) * 100:.2f}%"

    ws3 = wb.create_sheet("品类TOP")
    fill_sheet(
        ws3, "第 3 周 KPI 指标结果表 · 品类 GMV TOP",
        "来源：Hive ydsh_ads.ads_category_topn　累计占比用于判断集中度（前 3 名占 41.23%，属分散型结构）",
        cat, widths=[7, 14, 15, 11, 11, 11, 12, 13],
        num_cols={1, 3, 6, 7, 8},
    )

    # ---- 4. 用户分层 ----
    seg = query("SELECT user_segment, user_cnt, user_share, gmv, gmv_share, avg_gmv, avg_order_cnt "
                "FROM ads_user_segment ORDER BY gmv DESC")
    seg[0] = ["用户分层", "用户数", "用户占比", "GMV（元）", "GMV 占比", "人均 GMV（元）", "人均下单次数"]
    for r in seg[1:]:
        for idx in (2, 4):
            r[idx] = f"{float(r[idx]) * 100:.2f}%"

    ws4 = wb.create_sheet("用户分层")
    fill_sheet(
        ws4, "第 3 周 KPI 指标结果表 · 用户价值分层",
        "来源：Hive ydsh_ads.ads_user_segment　分层阈值见《指标定义文档》3.4 节",
        seg, widths=[18, 11, 11, 15, 11, 15, 14],
        num_cols={2, 4, 6, 7},
    )

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    wb.save(out_path)
    return out_path


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="docs/第3周_KPI指标结果表.xlsx")
    a = ap.parse_args()
    p = build(a.out)
    print(f"已生成：{p}（{os.path.getsize(p) / 1024:.1f} KB）")
