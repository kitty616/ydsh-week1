#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
ts_forecast.py —— 第 3 周子任务 2：时间序列分析与预测建模

流程：
  1) 读取每日 GMV 序列（由 ADS 层 ads_sales_daily_report 导出）
  2) 描述性分析：趋势、移动平均、月度结构、星期效应
  3) 特征工程：滞后特征 + 移动平均 + 日历特征
  4) 建模：线性回归 / 随机森林，并与三条朴素基线对比
  5) 评估：MAE / MAPE / RMSE（滚动留出最后 28 天做测试）
  6) 用全量数据重训，预测未来 7 天

设计说明：
  - 不使用 lag1 之类的「昨天」特征做多步预测，因为预测第 2 天起 lag1 就是模型自己的输出，
    误差会逐日累积。改用 lag7 / lag14 / ma7 这类「截至预测起点已知」的特征，
    7 天预测可以一次性给出，不做递归。
  - 必须和朴素基线比。如果模型打不过「上周同一天」，那模型就没有存在价值。
"""
import json
import os
import sys
import warnings

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestRegressor
from sklearn.linear_model import LinearRegression

warnings.filterwarnings("ignore")

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(BASE, "data", "daily_gmv.csv")
OUT_CSV = os.path.join(BASE, "data", "forecast_7d.csv")
OUT_JSON = os.path.join(BASE, "data", "forecast_metrics.json")
OUT_PNG = os.path.join(BASE, "docs", "images", "ts_forecast.png")


def load_series(path=DATA):
    df = pd.read_csv(path, sep="\t")
    df["dt"] = pd.to_datetime(df["dt"])
    df = df.sort_values("dt").reset_index(drop=True)
    df["gmv"] = df["gmv"].astype(float)
    return df


def describe(df):
    g = df["gmv"]
    print("=" * 62)
    print("一、序列基本特征")
    print("=" * 62)
    print(f"样本区间      : {df['dt'].min():%Y-%m-%d} ~ {df['dt'].max():%Y-%m-%d}（{len(df)} 天）")
    print(f"日均 GMV      : {g.mean():,.2f} 元")
    print(f"标准差        : {g.std():,.2f} 元")
    print(f"变异系数 CV   : {g.std() / g.mean():.4f}  （<0.1 属高度平稳）")
    print(f"最小 / 最大   : {g.min():,.2f} / {g.max():,.2f}")
    print(f"极差倍数      : {g.max() / g.min():.2f}x")

    # 星期效应：真实零售周六日通常显著高于工作日
    df["dow"] = df["dt"].dt.dayofweek
    dow_stat = df.groupby("dow")["gmv"].mean().round(2)
    names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    print("\n星期效应（各星期几的日均 GMV）：")
    for i, v in dow_stat.items():
        print(f"  {names[i]}  {v:,.2f}")
    spread = dow_stat.max() / dow_stat.min()
    print(f"  周内极差倍数：{spread:.3f}x  → {'几乎无星期效应' if spread < 1.05 else '存在星期效应'}")

    # 月度结构
    m = df.set_index("dt")["gmv"].resample("ME").sum()
    print("\n月度 GMV（万元）：")
    for ts, v in m.items():
        print(f"  {ts:%Y-%m}  {v / 10000:8.2f}")
    return dow_stat


def build_features(df):
    """构造截至预测起点即可知的特征"""
    d = df.copy()
    d["lag7"] = d["gmv"].shift(7)
    d["lag14"] = d["gmv"].shift(14)
    d["lag21"] = d["gmv"].shift(21)
    d["ma7"] = d["gmv"].shift(1).rolling(7).mean()     # 不含当日，避免信息泄漏
    d["ma14"] = d["gmv"].shift(1).rolling(14).mean()
    d["ma30"] = d["gmv"].shift(1).rolling(30).mean()
    d["dow"] = d["dt"].dt.dayofweek
    d["month"] = d["dt"].dt.month
    d["day"] = d["dt"].dt.day
    d["is_weekend"] = (d["dow"] >= 5).astype(int)
    return d


FEATURES = ["lag7", "lag14", "lag21", "ma7", "ma14", "ma30", "dow", "month", "is_weekend"]


def metrics(y_true, y_pred):
    y_true = np.asarray(y_true, dtype=float)
    y_pred = np.asarray(y_pred, dtype=float)
    mae = np.mean(np.abs(y_true - y_pred))
    mape = np.mean(np.abs((y_true - y_pred) / y_true))
    rmse = np.sqrt(np.mean((y_true - y_pred) ** 2))
    return {"MAE": round(float(mae), 2), "MAPE": round(float(mape), 4), "RMSE": round(float(rmse), 2)}


def evaluate(d):
    print("\n" + "=" * 62)
    print("二、模型评估（滚动留出最后 28 天作为测试集）")
    print("=" * 62)
    d = d.dropna(subset=FEATURES).reset_index(drop=True)
    split = len(d) - 28
    train, test = d.iloc[:split], d.iloc[split:]
    Xtr, ytr = train[FEATURES], train["gmv"]
    Xte, yte = test[FEATURES], test["gmv"]

    results = {}

    # 三条朴素基线：不建模，直接用已知值
    results["基线-上周同日"] = metrics(yte, test["lag7"])
    results["基线-近7日均值"] = metrics(yte, test["ma7"])
    results["基线-近14日均值"] = metrics(yte, test["ma14"])

    lr = LinearRegression().fit(Xtr, ytr)
    results["线性回归"] = metrics(yte, lr.predict(Xte))

    rf = RandomForestRegressor(n_estimators=300, max_depth=8, min_samples_leaf=5,
                               random_state=42, n_jobs=-1).fit(Xtr, ytr)
    results["随机森林"] = metrics(yte, rf.predict(Xte))

    print(f"{'模型':<16}{'MAE':>10}{'MAPE':>10}{'RMSE':>12}")
    print("-" * 62)
    for k, v in results.items():
        print(f"{k:<16}{v['MAE']:>10,.2f}{v['MAPE']:>10.2%}{v['RMSE']:>12,.2f}")

    best = min(results, key=lambda k: results[k]["MAE"])
    print(f"\nMAE 最优：{best}（{results[best]['MAE']:,.2f} 元）")
    print(f"相对「上周同日」基线的改善：{(1 - results[best]['MAE'] / results['基线-上周同日']['MAE']):+.2%}")

    return results, test, lr, rf, best


def forecast_next7(df, model_name, lr, rf):
    """用全量数据重训，预测未来 7 天（特征只依赖已知历史，可一次给出）"""
    d = build_features(df).dropna(subset=FEATURES).reset_index(drop=True)
    model = lr if model_name == "线性回归" else rf
    model.fit(d[FEATURES], d["gmv"])

    last = df["dt"].max()
    hist = df["gmv"].tolist()
    rows = []
    for h in range(1, 8):
        dt = last + pd.Timedelta(days=h)
        feat = {
            "lag7": hist[-7],
            "lag14": hist[-14],
            "lag21": hist[-21],
            "ma7": float(np.mean(hist[-7:])),
            "ma14": float(np.mean(hist[-14:])),
            "ma30": float(np.mean(hist[-30:])),
            "dow": dt.dayofweek,
            "month": dt.month,
            "is_weekend": int(dt.dayofweek >= 5),
        }
        x = pd.DataFrame([feat])[FEATURES]
        pred = float(model.predict(x)[0])
        rows.append({
            "dt": dt.strftime("%Y-%m-%d"),
            "forecast_gmv": round(pred, 2),
            "baseline_lag7": round(feat["lag7"], 2),
            "baseline_ma7": round(feat["ma7"], 2),
        })
        hist.append(pred)  # 供后续日期的 ma7 使用（第 8 天起才会用到，这里仅保持序列完整）
    fc = pd.DataFrame(rows)
    fc["weekday"] = pd.to_datetime(fc["dt"]).dt.dayofweek.map(
        dict(enumerate(["周一", "周二", "周三", "周四", "周五", "周六", "周日"])))
    return fc


def plot(df, test, fc, best):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    # 中文字体：Windows 用 SimHei，缺失时退回默认（仅影响图例文字）
    for font in ["Microsoft YaHei", "SimHei"]:
        try:
            matplotlib.rcParams["font.sans-serif"] = [font]
            matplotlib.rcParams["axes.unicode_minus"] = False
            break
        except Exception:
            continue

    fig, ax = plt.subplots(figsize=(12, 5.2), dpi=150)
    tail = df.tail(120)
    ax.plot(tail["dt"], tail["gmv"] / 10000, color="#4c72b0", lw=1.3, label="真实 GMV")

    ax.plot(test["dt"], test["gmv"] / 10000, color="#c44e52", lw=1.5,
            marker="o", ms=3, label="测试期真实值（最后 28 天）")
    ax.plot(test["dt"], test["gmv"].values / 10000, alpha=0)  # 占位，保持图例顺序

    fdt = pd.to_datetime(fc["dt"])
    ax.plot(fdt, fc["forecast_gmv"] / 10000, color="#55a868", lw=2,
            marker="s", ms=5, label=f"未来 7 天预测（{best}）")
    ax.axvline(df["dt"].max(), color="gray", ls="--", lw=1)
    ax.text(df["dt"].max(), ax.get_ylim()[1], "  预测起点", va="top", fontsize=9, color="gray")

    ax.set_title("每日 GMV 走势与未来 7 天预测", fontsize=13)
    ax.set_xlabel("日期")
    ax.set_ylabel("GMV（万元）")
    ax.grid(alpha=0.3, ls=":")
    ax.legend(loc="upper left", fontsize=9)
    fig.tight_layout()

    os.makedirs(os.path.dirname(OUT_PNG), exist_ok=True)
    fig.savefig(OUT_PNG)
    print(f"\n图表已保存：{OUT_PNG}")


def main():
    df = load_series()
    describe(df)
    d = build_features(df)
    results, test, lr, rf, best = evaluate(d)
    fc = forecast_next7(df, best, lr, rf)

    print("\n" + "=" * 62)
    print("三、未来 7 天预测结果")
    print("=" * 62)
    print(fc.to_string(index=False))
    print(f"\n7 天合计预测 GMV：{fc['forecast_gmv'].sum():,.2f} 元"
          f"（日均 {fc['forecast_gmv'].mean():,.2f} 元）")

    fc.to_csv(OUT_CSV, index=False, encoding="utf-8-sig")
    payload = {
        "model_selected": best,
        "metrics": results,
        "series_stats": {
            "days": int(len(df)),
            "mean": round(float(df["gmv"].mean()), 2),
            "std": round(float(df["gmv"].std()), 2),
            "cv": round(float(df["gmv"].std() / df["gmv"].mean()), 4),
            "min": round(float(df["gmv"].min()), 2),
            "max": round(float(df["gmv"].max()), 2),
        },
        "forecast_7d": fc.to_dict(orient="records"),
    }
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(f"预测结果已写入：{OUT_CSV}")
    print(f"指标汇总已写入：{OUT_JSON}")

    plot(df, test, fc, best)


if __name__ == "__main__":
    main()
