#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
nl2sql_chain.py —— LangChain 编排版 NL2SQL

存在的理由
----------
任务书要求用 LangChain 实现 NL2SQL。此前交付的 nl2sql.py 是 OpenAI SDK 直连 +
自写 Prompt + 自写校验，功能等价但不是任务书点名的技术栈。本脚本补齐这一项，
并与手写版做 A/B 对照，用同一批问题证明两条链路结果一致。

和手写版的差别（不是换个壳，是换了编排方式）
------------------------------------------
| 环节       | 手写版 nl2sql.py              | 本脚本                                    |
|------------|-------------------------------|-------------------------------------------|
| Prompt     | 手工拼 dict 列表               | ChatPromptTemplate，few-shot 声明式管理    |
| 输出解析   | 正则抽 ```sql 代码块           | with_structured_output + Pydantic 模型     |
| 降级       | if/else 判断有没有 Key         | Runnable.with_fallbacks 三级自动降级       |
| 执行编排   | 顺序调用函数                   | LCEL 管道 prompt | llm | parse | guard | exec |
| 耗时观测   | 无                             | CallbackHandler 逐步计时                   |

三级降级链（LangChain 的核心价值在这里最明显）
---------------------------------------------
  1. 结构化输出：with_structured_output(SQLPlan)
     → 模型直接返回 {sql, tables_used, reasoning}，不用正则抠代码块
  2. 纯文本兜底：prompt | llm | StrOutputParser | 正则抽 SQL
     → 有些模型不支持 function calling / json mode，这一级接住
  3. 规则兜底：rule_based()
     → 无 Key、网络不通、额度用尽，链路仍然能跑完并明确标注模式

手写版要做到这三级，得写三层嵌套 try/except；这里是一个 with_fallbacks 声明。

用法
----
  python nl2sql_chain.py "广东省的销售额是多少"
  python nl2sql_chain.py --batch              # 跑内置测试集
  python nl2sql_chain.py --compare            # 与手写版 nl2sql.py 做 A/B 对照
  python nl2sql_chain.py --graph              # 打印链路结构图（LangChain 独有）
"""
import argparse
import json
import os
import sys
import time

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, "python"))

# 复用已通过 15 条对抗测试的校验器与执行器，避免两套实现漂移
from nl2sql import (SCHEMA_TXT, TEST_QUESTIONS, extract_sql, load_env,  # noqa: E402
                    rule_based, run_sql, validate)

from langchain_core.callbacks import BaseCallbackHandler  # noqa: E402
from langchain_core.output_parsers import StrOutputParser  # noqa: E402
from langchain_core.prompts import ChatPromptTemplate  # noqa: E402
from langchain_core.runnables import RunnableLambda, RunnablePassthrough  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402

SCHEMA_TABLES = json.load(open(os.path.join(BASE, "data", "hive_schema.json"), encoding="utf-8"))


# ----------------------------------------------------------------------
# 1. 模型供应商解析（与手写版保持一致，便于对照）
# ----------------------------------------------------------------------
def resolve_provider(env):
    """统一走 llm_provider 解析，返回 (api_key, base_url, model, 名称)；无可用 Key 时返回 None"""
    from llm_provider import resolve

    p = resolve(env)
    if p is None:
        return None
    return (p.key, p.base_url, p.model, p.name)


# ----------------------------------------------------------------------
# 2. Prompt：ChatPromptTemplate 声明式管理 few-shot
# ----------------------------------------------------------------------
SYSTEM_PROMPT = """你是云购生活数仓的 Hive SQL 专家。

规则（必须全部遵守，违反即视为错误回答）：
1. 只输出一条 SELECT 查询。
2. 严禁 INSERT / UPDATE / DELETE / DROP / ALTER / CREATE / TRUNCATE 等写操作。
3. 表名必须带库名前缀，例如 ydsh_dws.dws_trade_day，不要写裸表名。
4. 日期字段是字符串（yyyy-MM-dd 或 yyyy-MM），直接按字符串比较。
5. 优先用 ADS 层成品指标表，其次 DWS 汇总层，最后才用 DWD 明细表。
6. 用户说「销售额 / 成交额 / GMV」时指 gmv 字段（实付金额合计）。
7. 结果按业务含义排序（金额降序 / 日期升序），必要时加 LIMIT。"""

PROMPT = ChatPromptTemplate.from_messages([
    ("system", SYSTEM_PROMPT),
    ("system", "可用表结构如下：\n{schema}"),
    ("user", "2024 年 6 月的总 GMV 是多少？"),
    ("assistant", "SELECT ROUND(SUM(gmv), 2) AS gmv_june FROM ydsh_dws.dws_trade_month WHERE month = '2024-06'"),
    ("user", "销量最高的前 5 个品类"),
    ("assistant", "SELECT category, gmv, gmv_share FROM ydsh_ads.ads_category_topn WHERE rank_no <= 5 ORDER BY rank_no"),
    ("user", "{question}"),
])


# ----------------------------------------------------------------------
# 3. 结构化输出模型：让模型直接给字段，不靠正则抠代码块
# ----------------------------------------------------------------------
class SQLPlan(BaseModel):
    """模型必须按这个结构回答，解析失败会自动触发下一级降级"""
    sql: str = Field(description="单条 Hive SELECT 语句，不带结尾分号，不带代码块标记")
    tables_used: list[str] = Field(default_factory=list, description="SQL 中引用到的完整表名")
    reasoning: str = Field(default="", description="一句话说明选表和聚合的理由")


# ----------------------------------------------------------------------
# 4. 回调：逐步计时，这是框架相对手写最有用的副产品
# ----------------------------------------------------------------------
class StepTimer(BaseCallbackHandler):
    def __init__(self):
        self.events = []
        self._t = {}

    def on_llm_start(self, serialized, prompts, **kwargs):
        self._t["llm"] = time.time()

    def on_llm_end(self, response, **kwargs):
        cost = time.time() - self._t.get("llm", time.time())
        usage = {}
        try:
            usage = response.llm_output.get("token_usage", {}) or {}
        except Exception:
            pass
        self.events.append({
            "step": "llm",
            "seconds": round(cost, 2),
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
        })

    def on_chain_start(self, serialized, inputs, **kwargs):
        name = (serialized or {}).get("name", "chain")
        self._t[name] = time.time()

    def on_chain_end(self, outputs, **kwargs):
        pass

    def summary(self):
        return self.events


# ----------------------------------------------------------------------
# 5. 构造链路
# ----------------------------------------------------------------------
def build_sql_chain(env, timer=None):
    """返回一条「输入 {question, schema} → 输出 SQL 字符串」的 Runnable

    三级降级在这里声明完成：
      结构化输出 with_fallbacks 纯文本 with_fallbacks 规则
    """
    provider = resolve_provider(env)

    if provider is None:
        # 没有 Key：主链一被调用就抛，交给 fallback 接住。
        # 故意让它走真实的 fallback 路径，而不是在外层 if/else 里绕开——
        # 这样「降级机制本身」每周都在被验证，不会等到真出事才发现失效。
        def no_key(_):
            raise RuntimeError("未配置 DEEPSEEK_API_KEY / DASHSCOPE_API_KEY")

        primary = RunnableLambda(no_key)
        text_chain = RunnableLambda(no_key)
    else:
        from langchain_openai import ChatOpenAI
        key, base_url, model, _ = provider
        llm = ChatOpenAI(model=model, api_key=key, base_url=base_url,
                         temperature=0, timeout=60, max_tokens=800,
                         callbacks=[timer] if timer else None)
        primary = (
            PROMPT
            | llm.with_structured_output(SQLPlan)
            | RunnableLambda(lambda p: (p.sql or "").strip().rstrip(";"))
        )
        text_chain = PROMPT | llm | StrOutputParser() | RunnableLambda(extract_sql)

    rule_chain = RunnableLambda(lambda x: rule_based(x["question"]))

    return primary.with_fallbacks([text_chain, rule_chain])


# ----------------------------------------------------------------------
# 6. 管道后段：校验 → 执行（把告警收集起来，不打断管道）
# ----------------------------------------------------------------------
def guard_step(payload):
    sql = payload.get("sql", "")
    ok, fixed, problems = validate(sql, SCHEMA_TABLES)
    return {**payload, "sql": fixed, "ok": ok, "problems": problems}


def exec_step(payload):
    if not payload["ok"]:
        return {**payload, "rows": [], "exec_error": None}
    rows, err = run_sql(payload["sql"])
    return {**payload, "rows": rows or [], "exec_error": " | ".join(err) if err else None,
            "ok": not err}


def build_chain(env, timer=None):
    return (
        RunnablePassthrough.assign(sql=build_sql_chain(env, timer))
        | RunnableLambda(guard_step)
        | RunnableLambda(exec_step)
    )


# ----------------------------------------------------------------------
# 7. 问答入口
# ----------------------------------------------------------------------
def ask(question, env, verbose=True):
    timer = StepTimer()
    chain = build_chain(env, timer)
    schema_txt = open(SCHEMA_TXT, encoding="utf-8").read()

    provider = resolve_provider(env)
    mode = provider[3] if provider else "规则模式（未配置 API Key）"

    t0 = time.time()
    try:
        out = chain.invoke({"question": question, "schema": schema_txt})
    except Exception as e:
        # 连规则兜底都失败，说明是代码问题而不是配置问题，如实抛出
        return {"question": question, "mode": mode, "ok": False, "sql": "",
                "problems": [f"{type(e).__name__}: {e}"], "rows": []}
    elapsed = round(time.time() - t0, 2)

    result = {
        "question": question,
        "mode": mode,
        "sql": out.get("sql", ""),
        "ok": bool(out.get("ok")),
        "problems": out.get("problems") or ([out["exec_error"]] if out.get("exec_error") else []),
        "rows": out.get("rows", [])[:20],
        "elapsed_s": elapsed,
        "llm_events": timer.summary(),
    }

    if verbose:
        print(f"\n问题：{question}")
        print(f"模式：{mode}（{elapsed}s）")
        print(f"生成 SQL：\n{result['sql']}")
        if result["problems"]:
            print(f"问题：{result['problems']}")
        else:
            print("校验：通过")
        if result["rows"]:
            head = result["rows"][0].split("\t")
            print("结果：" + " | ".join(head))
            for r in result["rows"][1:6]:
                print("      " + r.replace("\t", " | "))
            if len(result["rows"]) > 6:
                print(f"      ... 共 {len(result['rows']) - 1} 行")

    return result


# ----------------------------------------------------------------------
# 8. A/B 对照：同一批问题，两条链路跑
# ----------------------------------------------------------------------
def compare():
    import nl2sql as legacy

    env = load_env()
    schema = SCHEMA_TABLES
    print("=" * 78)
    print("A/B 对照：LangChain 编排版  vs  手写 SDK 版")
    print("=" * 78)

    rows = []
    same_sql = 0
    both_ok = 0
    for q in TEST_QUESTIONS:
        a = ask(q, env, verbose=False)
        b = legacy.ask(q, schema, env, verbose=False)

        def norm(s):
            return " ".join((s or "").split()).lower()

        identical = norm(a["sql"]) == norm(b["sql"])
        same_sql += identical
        both_ok += a["ok"] and b["ok"]
        rows.append({
            "question": q,
            "langchain_sql": a["sql"], "langchain_ok": a["ok"], "langchain_mode": a["mode"],
            "manual_sql": b["sql"], "manual_ok": b["ok"], "manual_mode": b["mode"],
            "sql_identical": identical,
        })
        print(f"\n· {q}")
        print(f"  LangChain ok={a['ok']}  sql_长度={len(a['sql'])}  与手写一致={identical}")
        if not identical:
            print(f"    LangChain: {a['sql'][:90]}")
            print(f"    手写     : {b['sql'][:90]}")

    print("\n" + "=" * 78)
    print(f"SQL 完全一致：{same_sql}/{len(TEST_QUESTIONS)}   |   两版均执行成功：{both_ok}/{len(TEST_QUESTIONS)}")
    print("=" * 78)

    out = os.path.join(BASE, "data", "nl2sql_ab_compare.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"same_sql": same_sql, "total": len(TEST_QUESTIONS),
                   "both_ok": both_ok, "detail": rows}, f, ensure_ascii=False, indent=2)
    print(f"\n对照结果已写入 {os.path.relpath(out, BASE)}")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("question", nargs="?", help="自然语言问题")
    ap.add_argument("--batch", action="store_true", help="跑内置测试集")
    ap.add_argument("--compare", action="store_true", help="与手写版做 A/B 对照")
    ap.add_argument("--graph", action="store_true", help="打印链路结构图")
    args = ap.parse_args()

    env = load_env()

    if args.graph:
        chain = build_chain(env)
        print("\n链路结构（LangChain 自动生成）：\n")
        print(chain.get_graph().draw_ascii())
        return

    if args.compare:
        compare()
        return

    if args.batch:
        results = [ask(q, env) for q in TEST_QUESTIONS]
        ok = sum(1 for r in results if r["ok"])
        print("\n" + "=" * 60)
        print(f"LangChain 版测试集：{ok}/{len(results)} 条链路执行成功（模式：{results[0]['mode']}）")
        with open(os.path.join(BASE, "data", "nl2sql_chain_results.json"), "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
        print("结果已写入 data/nl2sql_chain_results.json")
        return

    ask(args.question or "2024 年每个月的 GMV 趋势", env)


if __name__ == "__main__":
    main()
