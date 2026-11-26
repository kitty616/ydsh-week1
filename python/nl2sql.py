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
6. 列名必须原样使用表结构里的英文名（如 rank_no、gmv、gmv_share）。
   `//` 后面是中文说明，**只是解释，不是列名**，绝对不要把中文写进列的位置。
   中文只能出现在 AS 之后做别名，例如 `gmv` AS `成交额`——顺序不能反。
   标识符用反引号包裹，字符串常量用单引号；禁止使用双引号
   （Hive 把双引号内容当字符串字面量，写在别名位置会直接语法错误）。列名不要加库名。
7. 结果默认按业务含义排序（金额降序 / 日期升序），必要时加 LIMIT。
8. 用户问「销售额 / 成交额 / GMV」时默认指 gmv 字段（实付金额合计）。
9. 数仓是 2024 年的历史快照。「上周 / 上月 / 今天 / 最近 N 天」这类相对时间，
   必须以数据最新日期为基准换算，禁止使用 current_date() / unix_timestamp()，
   否则条件永远落在空区间，聚合结果是 NULL 而不是报错。
10. 只输出用户问的指标列，不要额外附加日期范围等辅助列；一旦用了聚合函数，
   SELECT 里所有非聚合列（包括子查询带出来的列）都必须写进 GROUP BY，
   Hive 不做隐式分组推断，漏写直接 SemanticException。
11. 只能用表结构里真实存在的列。按年份/月份筛选前先确认这张表有没有对应日期列：
   例如 ads_monthly_trend 只有 month（形如 '2024-06'），筛 2024 年要写
   `WHERE month LIKE '2024-%'`，不要凭空造 year / yr / 年份 这类不存在的列。
   这类错误静态校验拦不住，只会在执行期报 10004。
12. 表结构的每一行是「列名 类型 // 中文说明」。写 SQL 时**从左边的英文名取列**，
   不要翻译、不要照抄中文说明。举例（ads_category_topn）：
     问「销量最高的前 5 个品类」
     对：SELECT category, gmv, gmv_share FROM ydsh_ads.ads_category_topn
         WHERE rank_no <= 5 ORDER BY rank_no
     错：SELECT `一级品类`, `该品类全年GMV` ... WHERE `排名` <= 5
   模型经常把注释「排名」当成列名，Hive 会报 Invalid column reference '排名'。

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
    msgs.append({
        "role": "system",
        "content": (
            "可用表结构如下。每行格式为「列名 类型 // 中文说明」：\n"
            "左边的英文名才是列名，// 后面的中文只是解释，不能当列名写进 SQL。\n\n"
            + schema_txt
        ),
    })
    for ex in FEWSHOT:
        msgs.append({"role": "user", "content": ex["q"]})
        msgs.append({"role": "assistant", "content": ex["a"]})
    msgs.append({"role": "user", "content": question})
    return msgs


# ----------------------------------------------------------------------
# 3. 大模型调用
# ----------------------------------------------------------------------
def call_llm(messages, env):
    """调用大模型，服务商由 llm_provider 统一解析（DeepSeek / 通义 / 硅基流动 / Kimi / 智谱）。

    返回 (内容, 错误信息)：
      - 未配置 Key            -> (None, None)
      - 配置了 Key 但调用失败 -> (None, "异常摘要")
      - 调用成功              -> (内容, None)

    区分「没配 Key」和「配了但失败」很重要：前者是预期内的降级，
    后者是故障，必须让上层把原因显示出来，不能悄悄当成规则模式。
    """
    from llm_provider import resolve

    p = resolve(env)
    if p is None:
        return None, None

    try:
        from openai import OpenAI
        client = OpenAI(api_key=p.key, base_url=p.base_url, timeout=120)
        resp = client.chat.completions.create(
            model=p.model,
            messages=messages,
            temperature=0,
            # 4096 而不是 800：新一代模型里有一类是「始终思考」的（如 GLM-5.x），
            # 正文之前先输出一段 reasoning_content，且这段也计入 max_tokens。
            # 实测 GLM-5.3 在长 Prompt 上想过 7000 多字，预算给小了正文就是空字符串，
            # 表现成 content 为空、finish_reason=length，很容易被误判成「模型不听话」。
            max_tokens=4096,
            extra_body=p.extra_body,
        )
        ch = resp.choices[0]
        content = ch.message.content
        if not content:
            reasoning = getattr(ch.message, "reasoning_content", "") or ""
            if ch.finish_reason == "length":
                return None, (f"正文为空：max_tokens 被思考内容耗尽"
                              f"（已思考 {len(reasoning)} 字）")
            return None, f"正文为空（finish_reason={ch.finish_reason}）"
        return content, None
    except Exception as e:  # 网络抖动、额度用尽、模型下线都可能，不能让它打断整条链路
        return None, f"{type(e).__name__}: {str(e)[:120]}"


# ----------------------------------------------------------------------
# 4. SQL 静态校验
# ----------------------------------------------------------------------
def extract_sql(text):
    if not text:
        return ""
    m = re.search(r"```(?:sql)?\s*(.*?)```", text, re.S | re.I)
    sql = m.group(1) if m else text
    return sql.strip().rstrip(";")


def build_table_index(schema):
    """构建「表名 → 带库全名」的映射。

    同时收录裸表名，是为了接住模型漏写库名的情况。但裸表名必须映射到
    **它真实的库**，不能统一补某个默认库——dws / dwd / ads 三层都有同名
    习惯的表，补错库会生成一个不存在的表名，而校验却照样放行。
    """
    index = {}
    for full in schema:
        index[full] = full
        _, _, tbl = full.partition(".")
        if tbl and tbl not in index:
            index[tbl] = full
    return index


def strip_comments(sql):
    """去掉块注释与行注释。

    必须在压平换行之前做：`-- 注释` 依赖换行终止，一旦把 \\n 换成空格，
    注释就会吞掉它后面的整段 SQL（WHERE / LIMIT 一起失效），
    查询不报错但返回全表——这类静默错误比报错更难发现。
    """
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
    sql = re.sub(r"--[^\n]*", "", sql)
    return sql


# ----------------------------------------------------------------------
# 中文列名纠偏
#
# 起因（2026-11-26 实测）：用户问「销量最高的前 5 个品类」，模型输出了
#     SELECT `一级品类`, `该品类全年GMV` FROM `ydsh_ads`.`ads_category_topn`
#     WHERE `排名` <= 5
# 这三个中文标识符全部来自 schema 注释（rank_no 的注释是「排名，1 为最高」），
# 不是真实列名。Hive 编译期报 10004 Invalid column reference，自修复一次
# 仍改不对——因为报错只说「'排名' 不存在」，没有告诉模型正确列名是什么。
#
# 两道处理：
#   1) 能确定映射的（注释归一化后能对上），直接把中文换成英文列名；
#   2) 确定不了的，报问题时附上该表真实列名清单，让自修复有的放矢。
# ----------------------------------------------------------------------
def _norm_cn(text):
    """把注释归一化成「模型可能写出来的中文列名」。

    「该品类全年 GMV（元）」 -> 该品类全年GMV   （去括号、去空格）
    「排名，1 为最高」        -> 排名            （逗号后是解释，不是名字）
    """
    t = re.sub(r"[（(][^）)]*[）)]", "", text or "")
    t = re.split(r"[，,;；。]", t)[0]
    return re.sub(r"\s+", "", t).strip()


def build_cn_alias_map(schema):
    """中文说明 -> 英文列名。只保留**全局唯一**的映射，避免歧义改错。

    schema 形如 {全名: {"columns": [{"name":..., "comment":...}]}}。
    同一中文说明对应多个列时（比如 gmv 与 gmv_share 的注释都含「GMV」），
    直接丢弃——宁可报错让人看，也不能猜。
    """
    cand = {}
    for info in schema.values():
        for col in info.get("columns") or []:
            name = col.get("name")
            cmt = col.get("comment") or ""
            if not name:
                continue
            for key in {_norm_cn(cmt), _norm_cn(cmt.split("，")[0])}:
                if len(key) < 2 or not re.search(r"[\u4e00-\u9fa5]", key):
                    continue
                cand.setdefault(key, set()).add(name)
    return {k: next(iter(v)) for k, v in cand.items() if len(v) == 1}


def match_cn_column(token, alias_map):
    """中文标识符 -> 列名。先精确匹配，再允许「模型漏写尾缀」的前缀匹配。

    「一级品类」是「一级品类名称」的前缀，模型常省掉「名称」；
    但前缀命中必须唯一，命中多个就返回 None（不猜）。
    """
    key = _norm_cn(token)
    if key in alias_map:
        return alias_map[key]
    if len(key) < 2:
        return None
    hits = {v for k, v in alias_map.items() if k.startswith(key)}
    return next(iter(hits)) if len(hits) == 1 else None


def table_columns_hint(schema, tables, limit=12):
    """给报错信息用的「真实列名」清单，让自修复知道该改成什么。"""
    parts = []
    for t in tables:
        info = schema.get(t) or {}
        cols = [c.get("name") for c in (info.get("columns") or []) if c.get("name")]
        if cols:
            shown = cols[:limit]
            more = "" if len(cols) <= limit else f" …（共 {len(cols)} 列）"
            parts.append(f"{t}({', '.join(shown)}{more})")
    return "；".join(parts)


def fix_cn_columns(sql, schema, problems):
    """把中文标识符换成真实列名；换不掉的记进 problems 并附正确列名。"""
    alias_map = build_cn_alias_map(schema)
    tables = [t for t in re.findall(r"\b(?:from|join)\s+([A-Za-z_][\w.]*)", sql, re.I)
              if t in schema]

    # AS 后面的中文是别名，合法，不能动
    aliases = set()
    for a in re.findall(r"(?i)\bas\s+`?([^`\s,]+)`?", sql):
        aliases.add(a)

    unknown = []

    def _repl(m):
        token = m.group(1)
        if not re.search(r"[\u4e00-\u9fa5]", token):
            return m.group(0)
        if token in aliases:
            return m.group(0)
        real = match_cn_column(token, alias_map)
        if real:
            return "`%s`" % real
        unknown.append(token)
        return m.group(0)

    sql = re.sub(r"`([^`]+)`", _repl, sql)

    # 没加反引号的中文标识符（`SELECT 排名 FROM ...`），同样要抓
    # 先把单引号字符串替换成占位符，避免把 WHERE category='一级品类' 误判成列名
    holder = {}
    def _mask(m):
        k = f"__S{len(holder)}__"
        holder[k] = m.group(0)
        return k
    masked = re.sub(r"'[^']*'", _mask, sql)
    for m in re.finditer(r"[\u4e00-\u9fa5][\u4e00-\u9fa5A-Za-z0-9]*", masked):
        token = m.group(0)
        if token in aliases or token in unknown:
            continue
        real = match_cn_column(token, alias_map)
        if real:
            # 只替换独立出现的 token，且不要在字符串占位符里动
            sql = re.sub(rf"(?<![`\w]){re.escape(token)}(?![`\w])", "`%s`" % real, sql)
        else:
            unknown.append(token)

    if unknown:
        hint = table_columns_hint(schema, tables)
        problems.append(
            "引用了表结构中不存在的列：" + "、".join(dict.fromkeys(unknown))
            + ("；真实列名 → " + hint if hint else "")
        )
    return sql


def validate(sql, schema):
    """返回 (ok, sql, problems)

    schema 传完整结构（全名 → 字段信息），内部自行构建表名索引；
    不要传裸的 set，那样无法判断裸表名属于哪个库。
    """
    problems = []
    s = sql.strip()
    index = build_table_index(schema)

    if not s:
        return False, s, ["模型没有返回 SQL"]

    # 注释先剥掉。两个原因：
    #   1) 注释里的中文会被列名检查当成列名，误报；
    #   2) 注释里出现 "delete / drop" 这类词会触发 DANGEROUS 拦截，
    #      比如 `-- 不要 delete 数据` 直接把一条正常查询拦死。
    s = strip_comments(s).strip()

    # 引号归一化：Hive 里双引号是字符串字面量，不能当标识符用。
    # 实测模型会把中文别名写成 AS "华东GMV"，语义没毛病但执行必报 ParseException。
    # 按 Hive 语义分两步改，不做模糊猜测：
    #   AS "x"   -> AS `x`   （别名是标识符位置，要反引号）
    #   其余 "x" -> 'x'      （剩下的是字符串字面量，双引号在 Hive 里本就等同单引号）
    s = re.sub(r'(?i)\bas\s+"([^"]*)"', r"AS `\1`", s)
    s = re.sub(r'"([^"]*)"', r"'\1'", s)

    if DANGEROUS.search(s):
        problems.append("包含写操作关键字，已拦截")

    body = s.lstrip().upper()
    if not body.startswith("SELECT") and not body.startswith("WITH"):
        problems.append("不是 SELECT / WITH 开头")

    if s.count(";") > 1:
        problems.append("包含多条语句")

    # 表名白名单：抓 FROM / JOIN 后面的标识符
    used = re.findall(r"\b(?:from|join)\s+([A-Za-z_][\w.]*)", s, re.I)
    unknown = [t for t in used if t not in index]
    if unknown:
        problems.append("引用了白名单外的表：" + ", ".join(unknown))

    # 裸表名补全为真实库名；已带库名的不动
    for t in dict.fromkeys(used):
        if "." in t:
            continue
        full = index.get(t)
        if not full:
            continue  # 已记入 unknown，不再瞎补
        # 负向后顾避免把 ydsh_dws.dws_trade_day 里的裸名部分再补一次
        s = re.sub(rf"(?<![\w.]){re.escape(t)}\b", full, s)

    # 复核：改写本身可能制造新错误，改完必须再验一遍
    used_after = re.findall(r"\b(?:from|join)\s+([A-Za-z_][\w.]*)", s, re.I)
    broken = [t for t in used_after if t not in schema]
    if broken:
        problems.append("库名补全后仍不在白名单：" + ", ".join(broken))

    # 列名核对：中文注释不是列名——模型最常见的幻觉，静态校验必须拦
    s = fix_cn_columns(s, schema, problems)

    if not re.search(r"\blimit\b", s, re.I):
        s = s.rstrip() + "\nLIMIT 200"

    return len(problems) == 0, s, problems


# ----------------------------------------------------------------------
# 5. 执行
# ----------------------------------------------------------------------
def run_sql(sql, limit_rows=50):
    flat = strip_comments(sql).replace("\n", " ")
    cmd = ["docker", "exec", CONTAINER, "beeline",
           "-u", "jdbc:hive2://localhost:10000",
           "--silent=true", "--outputformat=tsv2", "-e", flat]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    except FileNotFoundError:
        # 在 app 容器里跑 CLI 时没有 docker 二进制。页面走的是
        # hive_client.run_sql_for_nl2sql（pyhive），不会到这里；
        # 但 CLI 直接调用要给一句能看懂的话，而不是 traceback。
        return None, ["当前环境没有 docker CLI：容器内请走 pyhive 通道"
                      "（app.py 已把 run_sql 替换为 hive_client.run_sql_for_nl2sql）"]
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
    schema_txt = open(SCHEMA_TXT, encoding="utf-8").read()

    mode = "大模型"
    raw, llm_err = call_llm(build_messages(question, schema_txt), env)
    if raw is None:
        if llm_err:
            mode = f"规则模式（模型调用失败，已降级：{llm_err}）"
        else:
            mode = "规则模式（未配置 API Key）"
        raw = rule_based(question)

    sql = extract_sql(raw)
    ok, sql, problems = validate(sql, schema)

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
                "problems": problems, "rows": [], "llm_error": llm_err}

    rows, err = run_sql(sql)
    if err:
        if verbose:
            print("执行失败：" + " | ".join(err))
        return {"question": question, "mode": mode, "sql": sql, "ok": False,
                "problems": err, "rows": [], "llm_error": llm_err}

    if verbose and rows:
        head = rows[0].split("\t")
        body = [r.split("\t") for r in rows[1:]]
        print("结果：" + " | ".join(head))
        for r in body[:10]:
            print("      " + " | ".join(r))
        if len(body) > 10:
            print(f"      ... 共 {len(body)} 行")

    return {"question": question, "mode": mode, "sql": sql, "ok": True,
            "problems": [], "rows": rows[:20], "llm_error": llm_err}


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
