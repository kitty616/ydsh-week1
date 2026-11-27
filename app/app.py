# -*- coding: utf-8 -*-
"""
app.py —— Streamlit 对话式经营问答界面

闭环：提问 → 大模型生成 Hive SQL → 静态校验 → 执行 → 表格 / ECharts 图表

设计取舍：
  1) 不重写一套 NL2SQL，直接复用第 3 周的 python/nl2sql.py 内核
     （同一条 Prompt、同一套校验规则），只把「执行」换成容器内可用的
     pyhive 通道。这样两处的口径永远一致，不会出现「脚本能跑、界面跑不通」。
  2) 图表用 ECharts 而不是 st.bar_chart：作业要求把 ECharts 渲染逻辑
     嵌入 Streamlit。ECharts 用 components.html 注入，图表库走本地文件，
     断网也能渲染。
  3) 模型失败不静默：降级到规则模式时，界面上会明确写出「规则模式」和原因，
     避免把兜底结果当成模型能力展示（第 3 周踩过的坑）。
"""

from __future__ import annotations

import json
import os
import sys

import pandas as pd
import streamlit as st

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.dirname(os.path.abspath(__file__))
# 两个目录都要显式加进去：
#   /app/python —— NL2SQL 内核（第 3 周的代码，直接复用）
#   /app/app    —— hive_client
# 只靠 Streamlit 自动把「脚本所在目录」塞进 sys.path 是不够稳的：
# 用 AppTest 或直接 import 这个模块时都拿不到，会报 ModuleNotFoundError。
sys.path.insert(0, os.path.join(BASE, "python"))
sys.path.insert(0, APP_DIR)

import hive_client  # noqa: E402
import nl2sql  # noqa: E402

# 关键一行：把 nl2sql 内部的执行器换成容器内可用的通道。
# ask() 里是 run_sql(...) 的全局名字查找，替换模块属性即可生效。
nl2sql.run_sql = hive_client.run_sql_for_nl2sql

SCHEMA = json.load(open(os.path.join(BASE, "data", "hive_schema.json"), encoding="utf-8"))
ECHARTS_JS = os.path.join(BASE, "dashboard", "echarts", "vendor", "echarts.min.js")

EXAMPLES = [
    "2024 年 6 月的总 GMV 是多少？",
    "销量最高的前 5 个品类",
    "2024 年每个月的 GMV 趋势",
    "广东省的销售额是多少",
    "用户价值分层结构是什么样的",
    "各支付方式的成交额占比",
]

st.set_page_config(page_title="云购生活 · 智能经营问答", page_icon="📊", layout="wide")


# ----------------------------------------------------------------------
# 样式
# ----------------------------------------------------------------------
st.markdown("""
<style>
  .block-container { padding-top: 2.2rem; max-width: 1180px; }
  .q-title { font-size: 1.6rem; font-weight: 700; letter-spacing: .5px; }
  .q-sub { color: #6b7a90; font-size: .86rem; margin-top: .2rem; }
  .badge {
    display: inline-block; padding: 1px 9px; border-radius: 10px;
    font-size: .74rem; letter-spacing: .3px; margin-right: 8px;
  }
  .badge-llm { background: #e0f2fe; color: #0369a1; }
  .badge-rule { background: #fef3c7; color: #92400e; }
  .badge-fail { background: #fee2e2; color: #991b1b; }
  .meta-line { color: #8494a8; font-size: .78rem; margin-top: .1rem; }
  div[data-testid="stChatMessage"] { background: transparent; }
</style>
""", unsafe_allow_html=True)


# ----------------------------------------------------------------------
# ECharts 渲染
# ----------------------------------------------------------------------
def echarts_html(df: pd.DataFrame, kind: str, title: str = "") -> str:
    """把二维结果表渲染成 ECharts 图表（内联图表库，离线可用）。"""
    if df.empty or df.shape[1] < 2:
        return ""

    x_col = df.columns[0]
    y_col = df.columns[1]
    x = [str(v) for v in df[x_col].tolist()]
    y_raw = df[y_col].tolist()
    y = []
    for v in y_raw:
        try:
            y.append(float(v))
        except (TypeError, ValueError):
            y.append(0.0)

    js_lib = ""
    if os.path.exists(ECHARTS_JS):
        js_lib = open(ECHARTS_JS, encoding="utf-8").read()

    base = {
        "grid": {"left": 60, "right": 30, "top": 40, "bottom": 60},
        "tooltip": {"trigger": "axis"},
        "title": {"text": title, "left": "center", "textStyle": {"fontSize": 13, "color": "#334155"}},
    }

    if kind == "line":
        option = {**base, "xAxis": {"type": "category", "data": x, "axisLabel": {"rotate": len(x) > 8 and 35 or 0}},
                  "yAxis": {"type": "value"},
                  "series": [{"type": "line", "data": y, "smooth": True, "symbolSize": 5,
                              "areaStyle": {"opacity": .18}, "name": str(y_col)}]}
    elif kind == "pie":
        option = {**base, "tooltip": {"trigger": "item"},
                  "legend": {"bottom": 0, "textStyle": {"fontSize": 11}},
                  "series": [{"type": "pie", "radius": ["38%", "64%"], "center": ["50%", "52%"],
                              "data": [{"name": a, "value": b} for a, b in zip(x, y)]}]}
    else:  # bar
        option = {**base, "xAxis": {"type": "category", "data": x,
                                    "axisLabel": {"rotate": len(x) > 8 and 35 or 0}},
                  "yAxis": {"type": "value"},
                  "series": [{"type": "bar", "data": y, "name": str(y_col),
                              "itemStyle": {"borderRadius": [4, 4, 0, 0]}}]}

    return f"""
    <div id="chart" style="width:100%;height:330px;"></div>
    <script>{js_lib}</script>
    <script>
      var chart = echarts.init(document.getElementById('chart'));
      chart.setOption({json.dumps(option, ensure_ascii=False)});
      window.addEventListener('resize', function () {{ chart.resize(); }});
    </script>
    """


def guess_kind(df: pd.DataFrame) -> str:
    """按结果的形状猜一个默认图型，用户仍可手动改。"""
    if df.shape[1] < 2:
        return "table"
    n = len(df)
    first = str(df.columns[0]).lower()
    if any(k in first for k in ("month", "dt", "date", "week", "day", "月", "日", "时间")):
        return "line"
    if n <= 8 and df.shape[1] == 2:
        return "pie"
    return "bar"


# ----------------------------------------------------------------------
# 自修复：把数据库的报错原样喂回模型，让它改一次
#
# 为什么要这一步：静态校验只能拦住「写了 DDL / 表名不在白名单 / 不是 SELECT」
# 这类结构性错误，拦不住「引用了一个不存在的列」——那种错只有 Hive 编译期
# 才报 10004。实测出现过模型给 ads_monthly_trend 凭空写 `WHERE year='2024'`
# （该表只有 month），一次自修复就能改对。
# 只重试一次：两次还错说明是模型能力或数据理解问题，继续重试只会烧 token。
# ----------------------------------------------------------------------
def ask_with_repair(question: str, schema: dict, env: dict, max_retry: int = 1) -> dict:
    r = nl2sql.ask(question, schema, env, verbose=False)
    r["repairs"] = 0

    for _ in range(max_retry):
        if r.get("ok"):
            break
        schema_txt = open(nl2sql.SCHEMA_TXT, encoding="utf-8").read()
        msgs = nl2sql.build_messages(question, schema_txt)
        msgs.append({"role": "assistant", "content": "```sql\n" + (r.get("sql") or "") + "\n```"})
        msgs.append({
            "role": "user",
            "content": "这条 SQL 没能执行成功，数据库返回的错误是：\n"
                       + "；".join(r.get("problems") or ["未知错误"])
                       + "\n请只输出修正后的单条 SELECT，不要解释。",
        })
        raw, llm_err = nl2sql.call_llm(msgs, env)
        if raw is None:
            r["problems"] = (r.get("problems") or []) + [f"自修复未执行：{llm_err or '模型不可用'}"]
            break

        sql = nl2sql.extract_sql(raw)
        ok, sql, problems = nl2sql.validate(sql, schema, question)
        if not ok:
            r = {**r, "sql": sql, "ok": False, "problems": problems,
                 "repairs": r["repairs"] + 1}
            continue
        rows, errs = nl2sql.run_sql(sql)
        r = {
            **r,
            "sql": sql,
            "ok": not errs,
            "problems": errs,
            "rows": rows[:20] if not errs else [],
            "repairs": r["repairs"] + 1,
        }

    return r


# ----------------------------------------------------------------------
# 结果解析
# ----------------------------------------------------------------------
def rows_to_df(rows: list[str]) -> pd.DataFrame:
    if not rows:
        return pd.DataFrame()
    header = rows[0].split("\t")
    body = [r.split("\t") for r in rows[1:]]
    df = pd.DataFrame(body, columns=header)
    # 能转数值的列转掉，否则排序和图表都不对
    for c in df.columns:
        try:
            df[c] = pd.to_numeric(df[c])
        except (ValueError, TypeError):
            pass
    return df


# ----------------------------------------------------------------------
# 侧边栏
# ----------------------------------------------------------------------
with st.sidebar:
    st.markdown("### 运行状态")
    ok, msg = (True, "未探测") if False else (None, None)
    try:
        ok, msg = hive_client.health()
    except Exception as e:
        ok, msg = False, str(e)[:100]
    st.markdown(f"**Hive 数据源**：{'🟢' if ok else '🔴'} {msg}")
    st.caption(f"接入方式：{hive_client.MODE}　目标：{hive_client.HIVE_HOST}:{hive_client.HIVE_PORT}")

    key_on = bool(os.environ.get("ZHIPU_API_KEY") or os.environ.get("DEEPSEEK_API_KEY")
                  or os.environ.get("DASHSCOPE_API_KEY"))
    st.markdown(f"**大模型**：{'🟢 已配置' if key_on else '🟡 未配置（走规则模式）'}")

    st.divider()
    st.markdown("### 示例问题")
    for q in EXAMPLES:
        if st.button(q, use_container_width=True, key="ex_" + q):
            st.session_state.pending = q

    st.divider()
    if st.button("清空对话", use_container_width=True):
        st.session_state.history = []
        st.rerun()
    st.caption("模型只负责把问题翻译成 SQL；SQL 会先过静态校验（单条 SELECT、"
               "表名白名单、强制 LIMIT）再执行，防止误删误改。")


# ----------------------------------------------------------------------
# 主体
# ----------------------------------------------------------------------
st.markdown('<div class="q-title">云购生活 · 智能经营问答</div>', unsafe_allow_html=True)
st.markdown('<div class="q-sub">用自然语言问数据：自动生成 Hive SQL → 校验 → 执行 → 出图。'
            '底层连接 ydsh 四层数仓（ODS / DWD / DWS / ADS）。</div>', unsafe_allow_html=True)
st.write("")

if "history" not in st.session_state:
    st.session_state.history = []


def render_turn(turn: dict):
    with st.chat_message("user"):
        st.markdown(turn["question"])

    with st.chat_message("assistant"):
        mode = turn["mode"]
        cls = "badge-llm" if mode.startswith("大模型") else (
            "badge-fail" if "失败" in mode else "badge-rule")
        st.markdown(
            f'<span class="badge {cls}">{mode}</span>'
            f'<span class="meta-line">执行 {turn.get("elapsed", 0)}s　'
            f'返回 {turn.get("n_rows", 0)} 行'
            + (f'　·　已自修复 {turn["repairs"]} 次' if turn.get("repairs") else '')
            + '</span>',
            unsafe_allow_html=True,
        )

        if turn.get("error"):
            st.error(turn["error"])
            if turn.get("sql"):
                with st.expander("仍然查看生成的 SQL"):
                    st.code(turn["sql"], language="sql")
            return

        with st.expander("查看生成的 SQL", expanded=False):
            st.code(turn["sql"], language="sql")
            if turn.get("problems"):
                st.warning("静态校验提示：" + "；".join(turn["problems"]))

        df = turn["df"]
        tab1, tab2 = st.tabs(["结果表", "图表"])
        with tab1:
            st.dataframe(df, use_container_width=True, height=260)
        with tab2:
            kind = st.radio("图表类型", ["line", "bar", "pie", "table"],
                            index=["line", "bar", "pie", "table"].index(turn.get("kind", "bar")),
                            horizontal=True, key=f"kind_{turn['id']}")
            if kind == "table" or df.shape[1] < 2:
                st.info("当前结果不适合出图（列数不足 1 列或选择了表格视图）。")
            else:
                st.components.v1.html(echarts_html(df, kind, ""), height=350)


for turn in st.session_state.history:
    render_turn(turn)

question = st.chat_input("例如：广东省上月销售额是多少？各品类 GMV 占比如何？")

if "pending" in st.session_state and st.session_state.pending:
    question = st.session_state.pending
    st.session_state.pending = None

if question:
    with st.spinner("生成 SQL 并执行中 ..."):
        env = dict(os.environ)
        result = ask_with_repair(question, SCHEMA, env)

        df = rows_to_df(result.get("rows") or [])
        error = None
        if not result.get("ok"):
            error = "执行未完成：" + "；".join(result.get("problems") or ["未知原因"])

        turn = {
            "id": len(st.session_state.history),
            "question": question,
            "sql": result.get("sql", ""),
            "mode": result.get("mode", "未知"),
            "problems": result.get("problems", []),
            "df": df,
            "n_rows": len(df),
            "elapsed": 0.0,
            "error": error,
            "kind": guess_kind(df) if not df.empty else "table",
            "repairs": result.get("repairs", 0),
        }
        st.session_state.history.append(turn)
    st.rerun()
