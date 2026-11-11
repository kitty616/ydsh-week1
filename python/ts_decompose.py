#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
ts_decompose.py —— 第 3 周子任务 2：趋势分解与环比 / 同比分析

任务书原文要求「完成趋势分解、移动平均、同比 / 环比分析」。
ts_forecast.py 负责的是预测建模那一段，本脚本补齐前一段描述性分析：

  1. 移动平均：7 / 14 / 30 日三条水位线
  2. 趋势分解：STL（周期 7 天），拆成 趋势 / 季节 / 残差 三段
  3. 环比：日（DoD）、周（WoW）、月（MoM）
  4. 同比：本数据集只有 2024 一年，做不了年同比 —— 脚本会显式检查并说明，
     而不是假装算了。这一点写进报告比硬凑一个数字更有价值。

设计取舍：
  - statsmodels 未安装时自动降级为「经典加法分解」（居中移动平均 + 周内均值），
    保证换台机器也能跑，不把环境依赖变成交付风险。
  - 季节强度 / 趋势强度用 Wang & Hyndman 的定义，可量化「这份数据到底有没有季节性」，
    避免只凭肉眼下结论。

产出：
  data/ts_decompose.json      全部分析结果（结构化，供报告引用）
  docs/images/ts_decompose.png 四联图：原始 / 趋势 / 季节 / 残差

用法：
  python python/ts_decompose.py
"""

from __future__ import annotations

import json
import os
import sys

import numpy as np
import pandas as pd

DATA = os.path.join("data", "daily_gmv.csv")
OUT_JSON = os.path.join("data", "ts_decompose.json")
OUT_PNG = os.path.join("docs", "images", "ts_decompose.png")

PERIOD = 7  # 周周期


def load(path: str = DATA) -> pd.DataFrame:
    """读取 ADS 层导出的日序列，统一 dt 为日期类型并按日期排序。"""
    if not os.path.exists(path):
        sys.exit(
            f"找不到 {path}\n"
            "先按《预测建模分析报告》第七节从 ADS 层导出：\n"
            "  docker exec ydsh-hive-server beeline -u jdbc:hive2://localhost:10000/ydsh_ads \\\n"
            '    --outputformat=tsv2 -e "SELECT dt, gmv, order_cnt, user_cnt, aov '
            'FROM ads_sales_daily_report ORDER BY dt" > data/daily_gmv.csv'
        )
    df = pd.read_csv(path, sep=None, engine="python")
    df["dt"] = pd.to_datetime(df["dt"])
    for c in ("gmv", "order_cnt", "user_cnt", "aov"):
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df.sort_values("dt").reset_index(drop=True)


# ---------------------------------------------------------------- 移动平均

def moving_average(df: pd.DataFrame, windows=(7, 14, 30)) -> pd.DataFrame:
    """三条移动平均水位线。窗口越长越平滑，也越滞后。"""
    out = df[["dt", "gmv"]].copy()
    for w in windows:
        out[f"ma{w}"] = out["gmv"].rolling(w, min_periods=w).mean()
    return out


def ma_summary(ma: pd.DataFrame) -> dict:
    """比较三条均线的平滑程度：标准差越小越平滑，但滞后也越大。"""
    res = {}
    for w in (7, 14, 30):
        col = f"ma{w}"
        s = ma[col].dropna()
        res[col] = {
            "std": round(float(s.std()), 2),
            "mean": round(float(s.mean()), 2),
            "cv": round(float(s.std() / s.mean()), 4),
        }
    # 日均 GMV 的原始波动，作为对照
    raw = ma["gmv"]
    res["raw"] = {
        "std": round(float(raw.std()), 2),
        "mean": round(float(raw.mean()), 2),
        "cv": round(float(raw.std() / raw.mean()), 4),
    }
    return res


# ---------------------------------------------------------------- 趋势分解

def decompose_stl(series: pd.Series):
    """STL 分解。返回 (trend, seasonal, resid) 三个 Series。"""
    from statsmodels.tsa.seasonal import STL

    res = STL(series, period=PERIOD, robust=True).fit()
    return res.trend, res.seasonal, res.resid, "STL(period=7, robust=True)"


def decompose_classic(series: pd.Series):
    """
    经典加法分解（statsmodels 缺席时的降级方案）。

    趋势 = 居中 7 日移动平均；季节 = 各星期几相对趋势的平均偏差（去均值）；
    残差 = 原始 − 趋势 − 季节。
    """
    s = series.reset_index(drop=True)
    trend = s.rolling(PERIOD, center=True, min_periods=PERIOD).mean()
    detrended = s - trend
    dow = s.index.to_series().mod(PERIOD)
    seasonal_idx = detrended.groupby(dow).mean()
    seasonal_idx = seasonal_idx - seasonal_idx.mean()
    seasonal = dow.map(seasonal_idx)
    resid = s - trend - seasonal
    return (
        pd.Series(trend, index=series.index),
        pd.Series(seasonal, index=series.index),
        pd.Series(resid, index=series.index),
        "经典加法分解(居中 MA7)",
    )


def strength(resid: pd.Series, seasonal: pd.Series, trend: pd.Series) -> dict:
    """
    Wang & Hyndman 的强度指标：
      Fs = max(0, 1 - Var(R) / Var(S + R))
      Ft = max(0, 1 - Var(R) / Var(T + R))
    取值 0~1，越接近 1 说明该成分越强。小于 0.3 基本可以认定为「没有规律」。
    """
    r = resid.dropna()
    s = seasonal.dropna()
    t = trend.dropna()
    var_r = float(np.var(r))
    fs = max(0.0, 1.0 - var_r / float(np.var(s + r))) if np.var(s + r) > 0 else 0.0
    ft = max(0.0, 1.0 - var_r / float(np.var(t + r))) if np.var(t + r) > 0 else 0.0
    return {
        "seasonal_strength": round(fs, 4),
        "trend_strength": round(ft, 4),
        "resid_std": round(float(r.std()), 2),
        "resid_share_of_mean": None,  # 下面填充
    }


# ---------------------------------------------------------------- 环比 / 同比

def monthly(df: pd.DataFrame) -> list[dict]:
    """月度汇总 + 月环比 MoM。"""
    m = (
        df.assign(month=df["dt"].dt.strftime("%Y-%m"))
        .groupby("month")
        .agg(gmv=("gmv", "sum"), order_cnt=("order_cnt", "sum"), days=("dt", "count"))
        .reset_index()
    )
    m["mom"] = m["gmv"].pct_change() * 100
    rows = []
    for _, r in m.iterrows():
        rows.append(
            {
                "month": r["month"],
                "gmv": round(float(r["gmv"]), 2),
                "order_cnt": int(r["order_cnt"]),
                "days": int(r["days"]),
                "aov": round(float(r["gmv"] / r["order_cnt"]), 2),
                "mom_pct": None if pd.isna(r["mom"]) else round(float(r["mom"]), 2),
            }
        )
    return rows


def weekly(df: pd.DataFrame) -> dict:
    """
    周环比 WoW：按周一起算，统计波动幅度。

    必须剔除首尾不满 7 天的周。2024-01-01 是周一、2024-12-31 是周二，
    末尾那个「周」只有 2 天，GMV 天然只有整周的 2/7，算环比会得到 -71% 的假暴跌。
    这类残周不剔除，结论就会被一个假异常带偏。
    """
    w = (
        df.assign(week=df["dt"] - pd.to_timedelta(df["dt"].dt.day_of_week, unit="D"))
        .groupby("week")
        .agg(gmv=("gmv", "sum"), order_cnt=("order_cnt", "sum"), days=("dt", "count"))
        .reset_index()
    )
    full = w[w["days"] == 7].copy()
    dropped = int(len(w) - len(full))
    full["wow"] = full["gmv"].pct_change() * 100
    v = full["wow"].dropna()
    return {
        "week_count": int(len(full)),
        "partial_weeks_dropped": dropped,
        "wow_mean_abs_pct": round(float(v.abs().mean()), 2),
        "wow_max_up_pct": round(float(v.max()), 2),
        "wow_max_down_pct": round(float(v.min()), 2),
        "wow_std_pct": round(float(v.std()), 2),
    }


def daily_dod(df: pd.DataFrame) -> dict:
    d = df.copy()
    d["dod"] = d["gmv"].pct_change() * 100
    v = d["dod"].dropna()
    return {
        "dod_mean_abs_pct": round(float(v.abs().mean()), 2),
        "dod_std_pct": round(float(v.std()), 2),
        "dod_p95_abs_pct": round(float(v.abs().quantile(0.95)), 2),
    }


def yoy_check(df: pd.DataFrame) -> dict:
    """
    同比可行性检查。

    年同比要求同一指标在「去年同月」有值。本数据集只有 2024 一年，
    因此年同比在数据层面不成立。这里把检查结果显式写进产出，
    避免报告里出现一个算不出来的指标却被当成算过了。
    """
    years = sorted(df["dt"].dt.year.unique().tolist())
    return {
        "years_covered": years,
        "year_count": len(years),
        "yoy_feasible": len(years) >= 2,
        "note": (
            "仅覆盖 %s 年，缺少上年同期数据，年同比（YoY）无法计算。"
            "报告改用月环比（MoM）与周环比（WoW）描述短期变化，并在局限中说明。"
            % "、".join(str(y) for y in years)
            if len(years) < 2
            else "覆盖多年，可计算年同比。"
        ),
    }


# ---------------------------------------------------------------- 绘图

def plot(df, trend, seasonal, resid, ma, path=OUT_PNG):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager

    # 中文字体：优先微软雅黑，缺失则退回默认（图注可能显示方块，不影响数据）
    for name in ("Microsoft YaHei", "SimHei", "Noto Sans CJK SC"):
        if any(name.lower() in f.name.lower() for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.sans-serif"] = [name]
            break
    plt.rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(4, 1, figsize=(12, 11), sharex=True)
    ax = axes[0]
    ax.plot(df["dt"], df["gmv"], lw=0.8, color="#4C78A8", label="日 GMV")
    for w, c in ((7, "#F58518"), (14, "#54A24B"), (30, "#B279A2")):
        ax.plot(ma["dt"], ma[f"ma{w}"], lw=1.2, color=c, label=f"MA{w}")
    ax.set_ylabel("GMV（元）")
    ax.set_title("原始序列与三条移动平均", fontsize=12, loc="left")
    ax.legend(loc="upper right", fontsize=8, ncol=4)

    axes[1].plot(df["dt"], trend, color="#E45756", lw=1.2)
    axes[1].set_ylabel("趋势项")
    axes[1].set_title("趋势（STL）", fontsize=12, loc="left")

    axes[2].plot(df["dt"], seasonal, color="#72B7B2", lw=1.0)
    axes[2].set_ylabel("季节项")
    axes[2].set_title("季节项（周期 7 天）", fontsize=12, loc="left")

    axes[3].scatter(df["dt"], resid, s=4, color="#54A24B", alpha=0.7)
    axes[3].axhline(0, color="#333", lw=0.8, ls="--")
    axes[3].set_ylabel("残差")
    axes[3].set_title("残差", fontsize=12, loc="left")

    fig.suptitle("日 GMV 序列分解（2024 全年，366 天）", fontsize=13, y=0.995)
    fig.tight_layout()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fig.savefig(path, dpi=140)
    plt.close(fig)


# ---------------------------------------------------------------- 主流程

def main():
    df = load()
    print(f"样本区间：{df['dt'].min():%Y-%m-%d} ~ {df['dt'].max():%Y-%m-%d}，{len(df)} 天")
    print(f"日均 GMV：{df['gmv'].mean():,.2f} 元，标准差 {df['gmv'].std():,.2f} 元，"
          f"变异系数 {df['gmv'].std()/df['gmv'].mean():.4f}")

    ma = moving_average(df)
    ma_stat = ma_summary(ma)
    print("\n[移动平均]")
    for k in ("raw", "ma7", "ma14", "ma30"):
        v = ma_stat[k]
        print(f"  {k:5s} 均值 {v['mean']:>12,.2f}  标准差 {v['std']:>10,.2f}  CV {v['cv']:.4f}")

    series = df.set_index("dt")["gmv"].asfreq("D")
    try:
        trend, seasonal, resid, method = decompose_stl(series)
    except ImportError:
        trend, seasonal, resid, method = decompose_classic(series)
        print("\n[提示] 未安装 statsmodels，已降级为经典加法分解")
    st = strength(resid, seasonal, trend)
    st["resid_share_of_mean"] = round(st["resid_std"] / float(series.mean()) * 100, 2)
    print(f"\n[趋势分解] 方法：{method}")
    print(f"  季节强度 Fs = {st['seasonal_strength']:.4f}（<0.3 视为无季节性）")
    print(f"  趋势强度 Ft = {st['trend_strength']:.4f}")
    print(f"  残差标准差 {st['resid_std']:,.2f} 元，占均值 {st['resid_share_of_mean']:.2f}%")

    rows = monthly(df)
    print("\n[月度 GMV 与环比]")
    for r in rows:
        mom = "  —  " if r["mom_pct"] is None else f"{r['mom_pct']:+.2f}%"
        print(f"  {r['month']}  {r['gmv']:>14,.2f}  环比 {mom:>8s}  客单价 {r['aov']:,.2f}")

    wk = weekly(df)
    dd = daily_dod(df)
    yy = yoy_check(df)
    print(f"\n[周环比] {wk['week_count']} 个完整周，平均 |WoW| = {wk['wow_mean_abs_pct']:.2f}%，"
          f"最大涨 {wk['wow_max_up_pct']:+.2f}%，最大跌 {wk['wow_max_down_pct']:+.2f}%")
    print(f"[日环比] 平均 |DoD| = {dd['dod_mean_abs_pct']:.2f}%，95 分位 {dd['dod_p95_abs_pct']:.2f}%")
    print(f"[同比]   {yy['note']}")

    out = {
        "generated_by": "python/ts_decompose.py",
        "data_range": {
            "start": df["dt"].min().strftime("%Y-%m-%d"),
            "end": df["dt"].max().strftime("%Y-%m-%d"),
            "days": len(df),
        },
        "moving_average": ma_stat,
        "decompose": {"method": method, **st},
        "monthly": rows,
        "weekly": wk,
        "daily": dd,
        "yoy": yy,
    }
    os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"\n已写出 {OUT_JSON}")

    plot(df, trend, seasonal, resid, ma)
    print(f"已写出 {OUT_PNG}")


if __name__ == "__main__":
    main()
