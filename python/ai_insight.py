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
from datetime import datetime

import numpy as np
import pandas as pd

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(BASE, "data")

# 异常判定阈值：偏离前 7 日均值的幅度。
# 初版用 0.25，全年 366 天命中 78 天（21.3%）——把五分之一的日子叫异常，
# 等于没有异常。按 2.2 节的敏感度对比，0.40 与 z>3 两条独立判据都收敛到
# 10-11 天，才改用 0.40。这个常量必须与 docs/AI洞察报告.md 的表述一致。
THRESHOLD = 0.40


def load():
    daily = pd.read_csv(os.path.join(D, "daily_gmv.csv"), sep="\t", parse_dates=["dt"])
    ch = pd.read_csv(os.path.join(D, "channel_day.csv"), sep="\t", parse_dates=["dt"])
    cat = pd.read_csv(os.path.join(D, "category_day.csv"), sep="\t", parse_dates=["dt"])
    return daily.sort_values("dt").reset_index(drop=True), ch, cat


def detect_anomalies(daily, threshold=THRESHOLD):
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


def narrate(payload):
    """把结构化结论交给大模型写成经营分析摘要

    分工必须划清楚：数字全部由脚本算好传进去，模型只负责组织语言。
    Prompt 里明确禁止它自行计算或补充新数字——否则一旦它"顺手"算出个
    增长率，那个数就没有任何可复算的来源，整篇摘要的可信度都会被拖下去。

    为什么要分三段调用
    ------------------
    glm-5.x 是「始终思考」模型，且思考长度跟着 max_tokens 上限走：给 2048
    能想 2,600 字，给 8192 想 16,000 字，给 16384 想 30,000 字，正文一个字
    都出不来（finish_reason=length）。这不是预算不够，是它的思考会撑满
    预算。唯一的解法是把任务切小——每段只要 100 多字，思考量就跟着降下来，
    三段的产出再拼接。实测这样每次都能正常返回。

    返回 (text, meta)。meta 记录这次到底是模型写的还是模板写的，以及失败
    原因——和 nl2sql 的模式标注同一个原则：不让降级结果冒充能力。
    """
    from nl2sql import load_env
    from llm_provider import resolve

    env = load_env()
    p = resolve(env)
    if p is None:
        return None, {"mode": "none", "reason": "未配置 API Key"}

    rows = []
    for a in payload["top_anomalies"][:2]:   # 只喂波动最大的两天
        ch = "、".join(f"{x['key']} {x['delta']:+,.0f}"
                      for x in sorted(a["attribute"]["channel"],
                                      key=lambda z: -abs(z["delta"]))[:2])
        cat = "、".join(f"{x['key']} {x['delta']:+,.0f}"
                       for x in sorted(a["attribute"]["category"],
                                       key=lambda z: -abs(z["delta"]))[:2])
        rows.append(f"{a['dt']}：GMV {a['gmv']:,.2f} 元，"
                    f"较前 7 日均值 {a['deviation']:+.1%}，z={a['z_score']}；"
                    f"渠道 {ch}；品类 {cat}")
    facts = "\n".join(rows)

    system = ("你是电商数据分析师，为运营负责人撰写经营分析。"
              "只能引用我给出的数字，禁止自行计算任何增长率、占比或合计；"
              "不要编造原因（促销、天气、竞品等数据里没有的信息一律不提）；"
              "纯文本，不要标题符号、表格或加粗；不要复述输入。")

    sections = [
        ("整体表现",
         "全年经营数据：GMV 36,116,687.06 元，订单 14,398 单，"
         "客单价 2,508.45 元，下单用户 1,000 人，人均下单 14.40 次，"
         "复购率 100%，订单取消率 14.05%，整体折扣率 11.77%。\n"
         "用 120 字左右概括这一年的整体表现。"),
        ("异常日分析",
         f"全年 366 天，偏离前 7 日均值 {payload['anomaly_threshold']:.0%} 以上"
         f"视为异常，共 {payload['anomaly_days']} 天"
         f"（{payload['anomaly_ratio']:.1%}）。波动最大的两天：\n{facts}\n"
         "用 130 字左右分析这两天的波动主要来自哪里。"),
        ("建议",
         "补充事实：八个品类的 GMV 占比只有 11.02%–14.95%，最大与最小相差 "
         "4 个百分点，分布异常均匀；下单用户 1,000 人，人均下单 14.40 次。\n"
         "用 110 字左右给出两条具体的运营建议。"),
    ]

    # 允许用 AI_INSIGHT_MODEL 指定写作模型。指定时不传厂商私有参数，
    # 避免把 thinking 参数带给不支持它的模型（会 400）。
    model = env.get("AI_INSIGHT_MODEL") or p.model
    budget = int(os.environ.get("AI_INSIGHT_MAX_TOKENS", "4096"))
    try:
        from openai import OpenAI
        client = OpenAI(api_key=p.key, base_url=p.base_url, timeout=180)
        kw = {}
        if p.extra_body and not env.get("AI_INSIGHT_MODEL"):
            kw["extra_body"] = p.extra_body

        parts = []
        for name, body in sections:
            resp = client.chat.completions.create(
                model=model,
                messages=[{"role": "system", "content": system},
                          {"role": "user", "content": body}],
                temperature=0.3,
                max_tokens=budget,
                **kw,
            )
            choice = resp.choices[0]
            text = (choice.message.content or "").strip()
            if not text:
                rc = getattr(choice.message, "reasoning_content", None) or ""
                return None, {"mode": "none",
                              "reason": f"「{name}」段返回空内容"
                                        f"（finish_reason={choice.finish_reason}，"
                                        f"思考段 {len(rc)} 字）"}
            parts.append(text)
        return "\n\n".join(parts), {"mode": "model", "provider": p.name,
                                      "model": model, "sections": len(parts)}
    except Exception as e:
        return None, {"mode": "none", "reason": f"{type(e).__name__}: {str(e)[:120]}"}


def main():
    daily, ch, cat = load()
    d, anomalies = detect_anomalies(daily)

    print("=" * 62)
    print(f"异常日检测（偏离前 7 日均值 ≥ {THRESHOLD:.0%}）")
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
        "anomaly_threshold": THRESHOLD,
        "anomaly_days": len(anomalies),
        "anomaly_ratio": round(len(anomalies) / len(d), 4),
        "top_anomalies": results,
    }

    print("\n" + "=" * 62)
    print("经营分析摘要生成")
    print("=" * 62)
    text, meta = narrate(payload)
    payload["narrative"] = {**meta, "text": text}
    if text:
        print(f"模式：{meta['provider']} / {meta['model']}（真实模型撰写）")
        print("-" * 62)
        print(text)
    else:
        print(f"模式：模板（{meta['reason']}）")
        print("已降级为固定模板，全文见 docs/AI洞察报告.md 第四节。")

    with open(os.path.join(D, "insight_result.json"), "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    if text:
        with open(os.path.join(D, "insight_narrative.md"), "w", encoding="utf-8") as f:
            f.write(f"<!-- 生成方式：{meta['provider']} / {meta['model']}，"
                    f"{datetime.now():%Y-%m-%d %H:%M} -->\n\n{text}\n")

    print(f"\n结构化结论已写入 data/insight_result.json")


if __name__ == "__main__":
    main()
