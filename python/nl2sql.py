#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
nl2sql.py —— 自然语言查询数仓（NL2SQL）

链路：自然语言 → 大模型生成 Hive SQL → 静态校验 → beeline 执行 → 结果表

三个关键设计：
  1) Schema 注入：把 14 张表的字段与中文语义塞进 Prompt，模型不用猜字段名。
  2) SQL 静态校验：模型会编表名、会写 DELETE，必须在执行前拦掉。
     校验规则：只允许单条 SELECT、禁止 DDL/DML 关键字、表名必须在白名单。
  3) 无 Key 降级：没有配置大模型 Key 时走规则模式，链路照样能演示，
     但输出里会明确标注「规则模式」——不能让演示结果被误当成模型的真实能力。

用法：
  python nl2sql.py "广东省 2024 年 6 月的销售额是多少"
  python nl2sql.py --batch            # 跑内置测试集
"""
import argparse
import json
import os
import re
import subprocess
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_TXT = os.path.join(BASE, "data", "schema_prompt.txt")
CONTAINER = "ydsh-hive-server"

DANGEROUS = re.compile(
    r"\b(insert|update|delete|drop|alter|create|truncate|load|grant|revoke|merge|overwrite)\b",
    re.I,
)


# ----------------------------------------------------------------------
# 1. 读取 .env（不装第三方库，自己解析，顺便演示「密钥不进代码」）
# ----------------------------------------------------------------------
def load_env(path=None):
    path = path or os.path.join(BASE, ".env")
    if not os.path.exists(path):
        return {}
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


# ----------------------------------------------------------------------
# 2. Prompt
# ----------------------------------------------------------------------
SYSTEM_PROMPT = """你是云购生活数仓的 Hive SQL 专家。

规则（必须全部遵守，违反即视为错误回答）：
1. 只输出一条 SELECT 查询，不要输出任何解释文字。
2. 严禁 INSERT / UPDATE / DELETE / DROP / ALTER / CREATE / TRUNCATE 等写操作。
3. 表名必须带库名前缀，例如 ydsh_dws.dws_trade_day，不要写裸表名。
4. 日期字段是字符串（yyyy-MM-dd 或 yyyy-MM），比较时用字符串即可，不要套 date 函数猜格式。
5. 优先使用 ADS 层的成品指标表；ADS 没有的再往下用 DWS，最后才用 DWD 明细表。
6. 中文别名用英文引号或直接省略；列名不要加库名。
7. 结果默认按业务含义排序（金额降序 / 日期升序），必要时加 LIMIT。
8. 用户问「销售额 / 成交额 / GMV」时默认指 gmv 字段（实付金额合计）。

只输出 SQL，用 ```sql 代码块包裹。"""

FEWSHOT = [
    {
        "q": "2024 年 6 月的总 GMV 是多少？",
        "a": "```sql\nSELECT ROUND(SUM(gmv), 2) AS gmv_june\nFROM ydsh_dws.dws_trade_month\nWHERE month = '2024-06'\n```",
    },
    {
        "q": "销量最高的前 5 个品类",
        "a": "```sql\nSELECT category, gmv, gmv_share\nFROM ydsh_ads.ads_category_topn\nWHERE rank_no <= 5\nORDER BY rank_no\n```",
    },
]


def build_messages(question, schema_txt):
    msgs = [{"role": "system", "content": SYSTEM_PROMPT}]
    msgs.append({"role": "system", "content": "可用表结构如下：\n" + schema_txt})
    for ex in FEWSHOT:
        msgs.append({"role": "user", "content": ex["q"]})
        msgs.append({"role": "assistant", "content": ex["a"]})
    msgs.append({"role": "user", "content": question})
    return msgs


# ----------------------------------------------------------------------
# 3. 大模型调用
# ----------------------------------------------------------------------
def call_llm(messages, env):
    """优先 DeepSeek，其次通义千问；都没有则返回 None（走规则模式）"""
    key = env.get("DEEPSEEK_API_KEY") or os.environ.get("DEEPSEEK_API_KEY")
    if key:
        base_url, model = "https://api.deepseek.com", env.get("DEEPSEEK_MODEL", "deepseek-chat")
    else:
        key = env.get("DASHSCOPE_API_KEY") or os.environ.get("DASHSCOPE_API_KEY")
        if not key:
            return None
        base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        model = env.get("DASHSCOPE_MODEL", "qwen-plus")

    from openai import OpenAI
    client = OpenAI(api_key=key, base_url=base_url, timeout=60)
    resp = client.chat.completions.create(
        model=model,
        messages=messages,
        temperature=0,
        max_tokens=800,
    )
    return resp.choices[0].message.content


# ----------------------------------------------------------------------
# 4. SQL 静态校验
# ----------------------------------------------------------------------
def extract_sql(text):
    if not text:
        return ""
    m = re.search(r"```(?:sql)?\s*(.*?)```", text, re.S | re.I)
    sql = m.group(1) if m else text
    return sql.strip().rstrip(";")


def validate(sql, schema_tables):
    """返回 (ok, sql, problems)"""
    problems = []
    s = sql.strip()

    if not s:
        return False, s, ["模型没有返回 SQL"]

    if DANGEROUS.search(s):
        problems.append("包含写操作关键字，已拦截")

    body = s.lstrip().upper()
    if not body.startswith("SELECT") and not body.startswith("WITH"):
        problems.append("不是 SELECT / WITH 开头")

    if s.count(";") > 1:
        problems.append("包含多条语句")

    # 表名白名单：抓 FROM / JOIN 后面的标识符
    used = re.findall(r"\b(?:from|join)\s+([A-Za-z_][\w.]*)", s, re.I)
    unknown = [t for t in used if t not in schema_tables]
    if unknown:
        problems.append("引用了白名单外的表：" + ", ".join(unknown))

    # 裸表名自动补库名（模型经常漏）
    for t in used:
        if "." not in t:
            full = f"ydsh_ads.{t}"
            s = re.sub(rf"\b{re.escape(t)}\b", full, s)

    if "limit" not in s.lower():
        s = s.rstrip() + "\nLIMIT 200"

    return len(problems) == 0, s, problems


# ----------------------------------------------------------------------
# 5. 执行
# ----------------------------------------------------------------------
def run_sql(sql, limit_rows=50):
    cmd = ["docker", "exec", CONTAINER, "beeline",
           "-u", "jdbc:hive2://localhost:10000",
           "--silent=true", "--outputformat=tsv2", "-e", sql.replace("\n", " ")]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = [ln for ln in r.stdout.splitlines()
           if ln.strip() and not ln.startswith("SLF4J") and "beeline" not in ln.lower()]
    err = [ln for ln in r.stderr.splitlines() if "SLF4J" not in ln and ln.strip()]
    if err and not out:
        return None, err[-3:]
    return out, []


# ----------------------------------------------------------------------
# 6. 规则兜底（无 Key 时的降级链路）
# ----------------------------------------------------------------------
RULES = [
    (r"(GMV|gmv|销售额|成交额).*(2024[-年]?\s*(\d{1,2})\s*月)", "month"),
    (r"(品类|类目).*(前|top|TOP)\s*(\d+)", "topn"),
    (r"(用户|客户).*(分层|价值|结构)", "segment"),
    (r"(KPI|指标).*(一览|列表|全部|哪些)", "kpi"),
    (r"(月度|每月|月份).*(趋势|走势|变化)", "trend"),
]


def rule_based(question):
    """没有大模型时的确定性兜底：只覆盖内置测试集里的问法"""
    q = question
    if ("品类" in q or "类目" in q) and re.search(r"(前|top)", q, re.I):
        m = re.search(r"(\d+)", q)
        n = m.group(1) if m else "5"
        return (f"SELECT rank_no, category, gmv, gmv_share FROM ydsh_ads.ads_category_topn "
                f"WHERE rank_no <= {n} ORDER BY rank_no")
    if re.search(r"(用户|客户).*(分层|价值|结构)", q):
        return "SELECT user_segment, user_cnt, user_share, gmv, gmv_share FROM ydsh_ads.ads_user_segment ORDER BY gmv DESC"
    if re.search(r"(KPI|指标)", q, re.I):
        return "SELECT metric_code, metric_name, metric_value, unit FROM ydsh_ads.ads_kpi_core ORDER BY metric_code"
    if re.search(r"(每月|每个月|月度|月份).*(趋势|走势|变化)", q):
        return "SELECT month, gmv, order_cnt, mom_rate FROM ydsh_ads.ads_monthly_trend ORDER BY month"
    m = re.search(r"(20\d{2})\s*[-年/]?\s*(\d{1,2})\s*月", q)
    if m:
        yy, mm = m.group(1), m.group(2).zfill(2)
        return f"SELECT month, gmv, order_cnt, aov FROM ydsh_ads.ads_monthly_trend WHERE month = '{yy}-{mm}'"
    prov = re.search(r"(北京|上海|天津|重庆|广东|浙江|江苏|山东|河南|四川|湖北|湖南|陕西|辽宁|福建|安徽)", q)
    if prov:
        p = prov.group(1)
        return ("SELECT s.province, ROUND(SUM(o.pay_amount), 2) AS gmv, COUNT(DISTINCT o.order_id) AS order_cnt "
                "FROM ydsh_dwd.dwd_order o "
                "JOIN ydsh_dwd.dim_store s ON o.store_id = s.store_id "
                f"WHERE s.province LIKE '{p}%' "
                "GROUP BY s.province")
    if re.search(r"(省份|地区|区域)", q):
        return ("SELECT s.province, ROUND(SUM(o.pay_amount), 2) AS gmv "
                "FROM ydsh_dwd.dwd_order o "
                "JOIN ydsh_dwd.dim_store s ON o.store_id = s.store_id "
                "GROUP BY s.province ORDER BY gmv DESC LIMIT 10")
    return "SELECT metric_code, metric_name, metric_value FROM ydsh_ads.ads_kpi_core ORDER BY metric_code"


# ----------------------------------------------------------------------
# main
# ----------------------------------------------------------------------
def ask(question, schema, env, verbose=True):
    tables = set(schema.keys()) | {k.split(".")[1] for k in schema}
    schema_txt = open(SCHEMA_TXT, encoding="utf-8").read()

    mode = "大模型"
    raw = call_llm(build_messages(question, schema_txt), env)
    if raw is None:
        mode = "规则模式（未配置 API Key）"
        raw = rule_based(question)

    sql = extract_sql(raw)
    ok, sql, problems = validate(sql, tables)

    if verbose:
        print(f"\n问题：{question}")
        print(f"模式：{mode}")
        print(f"生成 SQL：\n{sql}")
        if problems:
            print(f"校验问题：{problems}")
        else:
            print("校验：通过（单条 SELECT / 表名白名单 / 已加 LIMIT）")

    if not ok:
        return {"question": question, "mode": mode, "sql": sql, "ok": False,
                "problems": problems, "rows": []}

    rows, err = run_sql(sql)
    if err:
        if verbose:
            print("执行失败：" + " | ".join(err))
        return {"question": question, "mode": mode, "sql": sql, "ok": False,
                "problems": err, "rows": []}

    if verbose and rows:
        head = rows[0].split("\t")
        body = [r.split("\t") for r in rows[1:]]
        print("结果：" + " | ".join(head))
        for r in body[:10]:
            print("      " + " | ".join(r))
        if len(body) > 10:
            print(f"      ... 共 {len(body)} 行")

    return {"question": question, "mode": mode, "sql": sql, "ok": True,
            "problems": [], "rows": rows[:20]}


TEST_QUESTIONS = [
    "2024 年 6 月的总 GMV 是多少？",
    "销量最高的前 5 个品类",
    "用户价值分层结构是什么样的",
    "列出所有核心 KPI 指标",
    "2024 年每个月的 GMV 趋势",
    "广东省的销售额是多少",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("question", nargs="?", help="自然语言问题")
    ap.add_argument("--batch", action="store_true", help="跑内置测试集")
    args = ap.parse_args()

    schema = json.load(open(os.path.join(BASE, "data", "hive_schema.json"), encoding="utf-8"))
    env = load_env()

    if args.batch:
        results = []
        for q in TEST_QUESTIONS:
            r = ask(q, schema, env)
            results.append(r)
        ok = sum(1 for r in results if r["ok"])
        print("\n" + "=" * 60)
        print(f"测试集：{ok}/{len(results)} 条链路执行成功（模式：{results[0]['mode']}）")
        with open(os.path.join(BASE, "data", "nl2sql_test_results.json"), "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
        print("结果已写入 data/nl2sql_test_results.json")
        return

    q = args.question or "2024 年每个月的 GMV 趋势"
    ask(q, schema, env)


if __name__ == "__main__":
    main()
