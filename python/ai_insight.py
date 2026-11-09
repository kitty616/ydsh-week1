#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
ai_insight.py —— 第 3 周子任务 5：异常归因与自动化经营分析摘要

思路（先统计，后生成）：
  1) 用「对前 7 日均值的偏离度」找出异常日，而不是拍脑袋看曲线。
  2) 对每个异常日，把偏差分解到渠道和品类两个维度，算出各自贡献了多少金额。
     归因必须落到「哪个维度贡献了偏差的多少」，否则只是一句「昨天跌了」。
  3) 数字部分全部由脚本算出，文本部分可交给大模型润色——
     先有数据结论，再让模型组织语言，避免模型自己编原因。

输出：
  data/insight_result.json   结构化结论
  docs/AI洞察报告.md          可读版摘要（脚本生成骨架）
"""
import json
import os

import numpy as np
import pandas as pd

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(BASE, "data")


def load():
    daily = pd.read_csv(os.path.join(D, "daily_gmv.csv"), sep="\t", parse_dates=["dt"])
    ch = pd.read_csv(os.path.join(D, "channel_day.csv"), sep="\t", parse_dates=["dt"])
    cat = pd.read_csv(os.path.join(D, "category_day.csv"), sep="\t", parse_dates=["dt"])
    return daily.sort_values("dt").reset_index(drop=True), ch, cat


def detect_anomalies(daily, threshold=0.25):
    d = daily.copy()
    d["ma7_prev"] = d["gmv"].shift(1).rolling(7).mean()   # 不含当日
    d["dev"] = (d["gmv"] - d["ma7_prev"]) / d["ma7_prev"]
    d["z"] = (d["gmv"] - d["ma7_prev"]) / d["gmv"].shift(1).rolling(7).std()
    a = d[d["dev"].abs() >= threshold].copy()
    return d, a.sort_values("dev", key=lambda s: s.abs(), ascending=False)


def attribute(day, ch, cat, window=7):
    """把当日与基线（前 7 日均值）的差额拆到渠道 / 品类"""
    lo, hi = day - pd.Timedelta(days=window), day - pd.Timedelta(days=1)

    def decompose(df, key):
        base = (df[(df["dt"] >= lo) & (df["dt"] <= hi)]
                .groupby(key)["gmv"].mean())
        cur = df[df["dt"] == day].set_index(key)["gmv"]
        diff = (cur - base.reindex(cur.index).fillna(0)).sort_values()
        total = diff.sum()
        out = []
        for k, v in diff.items():
            out.append({
                "key": str(k),
                "current": round(float(cur.get(k, 0)), 2),
                "baseline": round(float(base.get(k, 0)), 2),
                "delta": round(float(v), 2),
                "share_of_delta": round(float(v / total), 4) if total else None,
            })
        return out, float(total)

    ch_d, ch_t = decompose(ch, "channel_code")
    cat_d, cat_t = decompose(cat, "category")
    return {"channel": ch_d, "category": cat_d,
            "channel_total_delta": round(ch_t, 2),
            "category_total_delta": round(cat_t, 2)}


def main():
    daily, ch, cat = load()
    d, anomalies = detect_anomalies(daily)

    print("=" * 62)
    print("异常日检测（偏离前 7 日均值 ≥ 25%）")
    print("=" * 62)
    print(f"共命中 {len(anomalies)} 天，占全年 {len(anomalies) / len(d):.1%}")
    print(f"\n{'日期':<12}{'当日GMV':>12}{'前7日均值':>12}{'偏离':>10}{'z值':>8}")
    for _, r in anomalies.head(10).iterrows():
        print(f"{r['dt']:%Y-%m-%d}  {r['gmv']:>12,.2f}{r['ma7_prev']:>12,.2f}"
              f"{r['dev']:>9.1%}{r['z']:>8.2f}")

    print("\n" + "=" * 62)
    print("Top 3 异常日归因")
    print("=" * 62)
    results = []
    for _, r in anomalies.head(3).iterrows():
        day = r["dt"]
        attr = attribute(day, ch, cat)
        print(f"\n【{day:%Y-%m-%d}】GMV {r['gmv']:,.2f}，较前 7 日均值 {r['dev']:+.1%}")
        print("  渠道贡献（负值=拖累）：")
        for x in sorted(attr["channel"], key=lambda z: z["delta"])[:3]:
            print(f"    {x['key']}  当期 {x['current']:>10,.2f}  基线 {x['baseline']:>10,.2f}"
                  f"  差额 {x['delta']:>+10,.2f}")
        print("  品类贡献（负值=拖累）：")
        for x in sorted(attr["category"], key=lambda z: z["delta"])[:3]:
            print(f"    {x['key']}  当期 {x['current']:>10,.2f}  基线 {x['baseline']:>10,.2f}"
                  f"  差额 {x['delta']:>+10,.2f}")
        results.append({
            "dt": day.strftime("%Y-%m-%d"),
            "gmv": round(float(r["gmv"]), 2),
            "baseline_ma7": round(float(r["ma7_prev"]), 2),
            "deviation": round(float(r["dev"]), 4),
            "z_score": round(float(r["z"]), 2),
            "attribute": attr,
        })

    payload = {
        "anomaly_threshold": 0.25,
        "anomaly_days": len(anomalies),
        "anomaly_ratio": round(len(anomalies) / len(d), 4),
        "top_anomalies": results,
    }
    with open(os.path.join(D, "insight_result.json"), "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(f"\n结构化结论已写入 data/insight_result.json")


if __name__ == "__main__":
    main()
