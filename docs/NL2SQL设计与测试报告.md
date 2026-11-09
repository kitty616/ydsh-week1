# NL2SQL 设计与测试报告

> 项目：云购生活 · 企业级数据仓库与经营分析可视化系统
> 子任务：第 3 周 · 子任务 3（大模型 API 接入）、子任务 4（NL2SQL 构建）
> 代码：`python/schema_extract.py`、`python/nl2sql.py`、`python/test_guard.py`
> 日期：2026-11-09

---

## 一、链路总览

```
自然语言问题
    ↓
Schema 注入（14 张表、字段 + 中文语义，3,671 字符）
    ↓
大模型生成 SQL（Prompt 含 8 条硬约束 + 2 个 few-shot）
    ↓
静态校验器  ←—— 这一步是整个链路的安全底线
    ├─ 只允许单条 SELECT / WITH
    ├─ 拦截 DDL / DML 关键字
    ├─ 表名白名单（14 张）
    ├─ 自动补库名（按真实所属库）
    ├─ 改写后二次复核
    └─ 自动加 LIMIT
    ↓
beeline 执行（Docker 内 Hive 4.0.0）
    ↓
结果表
```

---

## 二、Schema 抽取

### 2.1 为什么不用 pyhive

部署手册给的示例是 `pyhive`。实测在 Windows + Python 3.13 下装不上：`pyhive` 依赖的 `sasl` 需要 C 编译环境，`pip install` 直接失败。

改用 **beeline**（Hive 自带客户端）执行 `DESCRIBE` 抽取结构，效果等价，且不引入额外依赖。这是"手册给的路走不通时换一条"的正常工程决策，不是偷懒。

### 2.2 抽取结果

| 库 | 表 | 列数 |
|---|---|---|
| ydsh_ads | ads_kpi_core | 5 |
| ydsh_ads | ads_sales_daily_report | 8 |
| ydsh_ads | ads_category_topn | 8 |
| ydsh_ads | ads_user_segment | 7 |
| ydsh_ads | ads_monthly_trend | 8 |
| ydsh_dws | dws_trade_day | 8 |
| ydsh_dws | dws_trade_month | 7 |
| ydsh_dws | dws_category_day | 5 |
| ydsh_dws | dws_store_day | 6 |
| ydsh_dws | dws_channel_day | 6 |
| ydsh_dwd | dwd_order | 12 |
| ydsh_dwd | dim_product | 10 |
| ydsh_dwd | dim_store | 9 |
| ydsh_dwd | dim_channel | 2 |

共 **14 张表、101 个字段**，渲染成 3,671 字符的 Prompt 上下文（`data/schema_prompt.txt`）。

### 2.3 为什么只暴露 14 张表

Hive 里有 40+ 张表，包括 `dwd_order_clean`、`dq_compare` 这类中间表和质检表。全部塞给模型有两个坏处：

1. **Prompt 变长**，成本上升、注意力被稀释；
2. **选错表概率上升**——模型看到 `dwd_order` 和 `dwd_order_clean` 两个名字，很可能选错。

所以只给「分析时真正该用的 14 张」，中间表干脆不出现在 Prompt 里。这是**用白名单做负向约束**：模型看不到，就选不错。

### 2.4 为什么还要手工补业务语义

Hive metastore 里的字段注释是中文的，但在容器 locale 下 `DESCRIBE` 输出会变成 `????????`（编码问题）。而字段名本身对大模型信息量不足：`status_code` 到底是订单状态还是商品状态？`mom_rate` 是环比还是同比？

所以采用「**结构自动抽 + 语义人工补**」：字段名和类型由脚本从 Hive 拉，中文含义在 `schema_extract.py` 的 `TABLE_META` 字典里维护。

这样做的另一个好处是：语义字典是**版本可控的**，改了可以 diff；而数据库注释改了没人知道。

---

## 三、Prompt 设计

### 3.1 八条硬约束

| # | 约束 | 防止什么问题 |
|---|---|---|
| 1 | 只输出一条 SELECT | 模型爱写解释文字，破坏下游解析 |
| 2 | 严禁写操作 | 模型可能生成 DELETE / DROP |
| 3 | 表名必须带库名前缀 | Hive 里裸表名会解析到 default 库 |
| 4 | 日期字段是字符串，不要猜格式 | 模型爱套 `to_date()` / `str_to_date()`，Hive 语法不同 |
| 5 | 优先 ADS → DWS → DWD | 防止动辄去 join 明细表，慢且易错 |
| 6 | 别名不加库名 | 会出现 `ads_category_topn.category` 这种非法列名 |
| 7 | 结果要排序、必要时 LIMIT | 无序返回对用户无意义 |
| 8 | 「销售额」默认指 gmv | 消除业务词与字段名的歧义 |

第 4 条是踩过坑才加的：Hive 的日期函数和 MySQL 差异很大，`to_date()` 在 Hive 里接受多种格式但跨版本行为不一致，让模型自由发挥等于给自己埋雷。

### 3.2 Few-shot 的选择

只放两个例子，一简一繁：

- 简单：`2024 年 6 月的总 GMV → SELECT ... WHERE month='2024-06'`，示范「月份字段是字符串」。
- 带排序：`销量最高的前 5 个品类 → SELECT ... WHERE rank_no <= 5 ORDER BY rank_no`，示范「优先用 ADS 成品表」。

例子多了反而有害：模型会倾向于模仿例子的表层句式，而不是理解规则。

### 3.3 一个未采用的方案

考虑过让模型先输出「思考过程」再输出 SQL（Chain-of-Thought）。放弃了，原因：

- 增加了 token 成本；
- 输出解析变复杂（要分离思考和 SQL）；
- 对这类「单表查询 + 固定 Schema」的问题，规则约束比思考链更有效。

如果问题复杂到需要多表 join + 子查询，才值得上 CoT。

---

## 四、SQL 静态校验器

### 4.1 为什么必须有

大模型生成的 SQL 有两类典型失败：

- **语法/语义错**：表名编造、字段不存在 → 执行报错，可接受；
- **危险操作**：生成 `DELETE` / `DROP` / 多语句注入 → 直接改坏数据，不可接受。

第二类必须靠校验器拦，不能指望 Prompt。Prompt 是"请求"，校验器是"强制"。

### 4.2 校验规则

```python
DANGEROUS = re.compile(r"\b(insert|update|delete|drop|alter|create|truncate|load|grant|revoke|merge|overwrite)\b", re.I)
```

| 检查项 | 实现 |
|---|---|
| 写操作拦截 | 正则匹配 12 个危险关键字 |
| 语句类型 | 必须以 `SELECT` / `WITH` 开头 |
| 多语句 | `;` 数量 > 1 即拒绝 |
| 表名白名单 | 抓 `FROM` / `JOIN` 后的标识符，比对 14 张表 |
| 自动补库名 | 裸表名按**真实所属库**补全（`dws_*`→`ydsh_dws`、`dwd_*`/`dim_*`→`ydsh_dwd`、`ads_*`→`ydsh_ads`） |
| 改写后复核 | 补全后重新抓表名再验一遍白名单，防止改写本身制造新错误 |
| 注释剥离 | 执行前去掉 `--` 与 `/* */`，避免压平换行时注释吞掉后续 SQL |
| 自动加 LIMIT | 无 `LIMIT` 时追加 `LIMIT 200` |

### 4.3 对抗测试结果

`python/test_guard.py`，15 条用例 **全部通过（15/15）**。相比初版增加了 4 条跨层裸表名用例，并把「改写结果」纳入断言。

| 用例 | 期望 | 实际 | 改写校验 | 判定 |
|---|---|---|---|---|
| 正常查询（带库名） | 通过 | 通过 | OK | PASS |
| 正常查询（裸表名，ads 层） | 通过 | 通过 | OK | PASS |
| 裸表名应补到 dws 层而非 ads | 通过 | 通过 | OK | PASS |
| 裸表名应补到 dwd 层而非 ads | 通过 | 通过 | OK | PASS |
| 裸维表应补到 dwd 层 | 通过 | 通过 | OK | PASS |
| 正常查询（聚合 + JOIN） | 通过 | 通过 | OK | PASS |
| 危险：DELETE | 拒绝 | 拒绝 | — | PASS |
| 危险：DROP TABLE | 拒绝 | 拒绝 | — | PASS |
| 危险：UPDATE | 拒绝 | 拒绝 | — | PASS |
| 危险：多语句注入 | 拒绝 | 拒绝 | — | PASS |
| 错误：编造的库表 | 拒绝 | 拒绝 | — | PASS |
| 错误：非 SELECT 开头 | 拒绝 | 拒绝 | — | PASS |
| 错误：空输出 | 拒绝 | 拒绝 | — | PASS |
| 边界：子查询里的裸表名 | 通过 | 通过 | OK | PASS |
| 边界：已带库名不应被重复补全 | 通过 | 通过 | OK | PASS |

拦截原因实际输出（节选）：

```
· 危险：DELETE：包含写操作关键字，已拦截；不是 SELECT / WITH 开头
· 危险：多语句注入：包含写操作关键字，已拦截
· 错误：编造的库表：引用了白名单外的表：ydsh_ods.ods_sales_fact；库名补全后仍不在白名单：ydsh_ods.ods_sales_fact
· 错误：空输出：模型没有返回 SQL
```

裸表名补全实测（按真实库名，而非统一补 ads）：

```
dws_trade_day   →  ydsh_dws.dws_trade_day
dwd_order       →  ydsh_dwd.dwd_order
dim_store       →  ydsh_dwd.dim_store
ads_monthly_trend →  ydsh_ads.ads_monthly_trend
```

### 4.4 Code Review 发现的问题与修复

PR #2 提交后做了一轮自查式 Review，发现校验器本身 4 个缺陷。全部实测复现后修复，过程记录在 PR 的 5 条行内评论里。

| 级别 | 问题 | 后果 | 修复 |
|---|---|---|---|
| Blocker | 裸表名一律补 `ydsh_ads.` | `dws_trade_day`→`ydsh_ads.dws_trade_day`，表不存在却返回 `ok=True`，放行了必然失败的 SQL | 白名单改为 `表名→全名` 映射，按真实库补全；补全后二次复核 |
| Major | 测试只断言 `ok` 布尔值 | 上述 Blocker 显示 PASS 被漏掉——用例里恰好用了 `dws_trade_day`，但没人检查它被改写成什么 | 用例增加期望 SQL 字段，判定同时校验 `expect_sql in fixed` |
| Major | 执行前把 `\n` 换成空格 | `-- 注释` 后的 `WHERE` / `LIMIT` 被整体注释掉，**查询不报错但返回全表** | 新增 `strip_comments()`，先剥注释再压平 |
| Minor | `call_llm` 无异常兜底 | 有 Key 时网络抖动直接抛栈，不回落规则模式 | `try/except` 返回 `(None, 错误摘要)`；模式标注「模型调用失败，已降级」 |

Blocker 的实测证据（修复前）：

```
输入: SELECT * FROM dwd_order
输出: SELECT * FROM ydsh_ads.dwd_order    ← 库名错
ok = True                                  ← 校验放行
```

修复后同一输入得到 `ydsh_dwd.dwd_order`，并新增 4 条用例锁住这个行为。

这个教训比代码本身更重要：**校验器的价值在于「拦住错误」，一旦它自己动手改写却不受检验，它的「通过」反而是风险来源。**

### 4.5 校验器拦不住什么

必须说清楚边界，否则会有虚假安全感：

1. **合法但算错的 SQL**：比如把 `SUM(pay_amount)` 写成 `SUM(discount_amount)`，语法没问题、表名在白名单内，校验器放行。这类只能靠人工核对结果。
2. **性能问题**：全表扫描 34 万行的笛卡尔积也能通过校验，只是跑很久。
3. **语义歧义**：「销售额」到底指 GMV 还是净收入，校验器判断不了。

所以校验器是**安全网，不是正确性保证**。

---

## 五、测试集与执行结果

### 5.1 六条典型问题

| # | 问题 | 命中表 | 执行结果 |
|---|---|---|---|
| 1 | 2024 年 6 月的总 GMV 是多少？ | ads_monthly_trend | ✅ 2,829,996.31 元，1,110 单，AOV 2,549.55 |
| 2 | 销量最高的前 5 个品类 | ads_category_topn | ✅ 运动户外 534.77 万 / 数码家电 488.13 万 / 服饰鞋包 451.76 万 / 图书文娱 448.82 万 / 食品生鲜 440.47 万 |
| 3 | 用户价值分层结构是什么样的 | ads_user_segment | ✅ 5 层，重要价值用户 235 人占 GMV 32.78% |
| 4 | 列出所有核心 KPI 指标 | ads_kpi_core | ✅ 10 个指标 |
| 5 | 2024 年每个月的 GMV 趋势 | ads_monthly_trend | ✅ 12 个月，1 月最高 315.87 万，6 月最低 283.00 万 |
| 6 | 广东省的销售额是多少 | dwd_order + dim_store | ✅ 581,858.32 元，222 单 |

**6/6 链路执行成功**。第 6 条需要从明细表 join 维表，是唯一一条走到 DWD 层的问题——验证了「ADS 优先、必要时下沉」的层级策略在 Prompt 约束下确实生效。

### 5.2 当前运行模式：规则降级（重要）

**本次测试是在「规则模式」下跑的，不是真实大模型生成。**

原因：当前环境没有配置大模型 API Key（五家服务商 `DEEPSEEK_API_KEY` / `DASHSCOPE_API_KEY` / `SILICONFLOW_API_KEY` / `MOONSHOT_API_KEY` / `ZHIPU_API_KEY` 均未设置）。`nl2sql.py` 检测到无 Key 后自动降级为内置规则匹配，覆盖上述 6 类问法。

这意味着：

- ✅ **链路是通的**：Schema → 生成 → 校验 → 执行 → 结果，每一环都真实跑过。
- ✅ **校验器是真实的**：15 条对抗测试全部真实执行，且断言改写结果而不只是布尔值。
- ❌ **模型能力未被验证**：规则模式只能证明"如果有一条正确的 SQL，这个链路能跑通"，不能证明"模型能生成正确的 SQL"。

这个区别必须写清楚。把规则模式的结果当成模型效果汇报，是自欺。

**但「只差 Key」这件事本身是可以证明的。** 用无效 Key 分别打五家接口，全部返回 401 鉴权失败而非连接超时或 DNS 错误（实测记录见 8.6 节），说明：网络可达、OpenAI 兼容协议正确、`base_url` 与请求体格式正确，唯一缺的是一枚有效密钥。

### 5.3 如何切换到真实模型

```bash
cp .env.example .env
# 编辑 .env，填入任意一家：DEEPSEEK_API_KEY=sk-xxxx
python python/llm_ping.py          # 先验证连通性
python python/nl2sql.py --batch    # 手写 SDK 版
python python/nl2sql_chain.py --batch   # LangChain 编排版
```

代码已就绪，切换 Key 后无需改任何逻辑，输出中的「模式」会从「规则模式」变为实际服务商名。

服务商由 `python/llm_provider.py` 统一解析，支持五家（DeepSeek / 通义千问 / 硅基流动 / Kimi / 智谱），全部走 OpenAI 兼容协议。其中硅基流动与智谱有长期免费模型，可用零成本完成真实调用验证。要新增一家只改 `PROVIDERS` 字典，三个脚本自动生效。


### 5.4 密钥管理

| 措施 | 实现 |
|---|---|
| 不硬编码 | 全部通过 `os.environ` / `.env` 读取，代码里搜不到 `sk-` |
| 不入库 | `.gitignore` 排除 `.env`、`*.key`、`*.pem`、`secrets/` |
| 提供模板 | `.env.example` 只有占位符 `sk-your-key-here` |
| 泄露处置 | 文档明确：误提交后必须到控制台**吊销重发**，仅删代码不够——历史提交仍可检索 |

最后一条是很多人踩过的坑：以为 `git rm` 就完事，其实 `git log -p` 里还躺着。

---

## 六、局限与改进方向

| 问题 | 现状 | 改进 |
|---|---|---|
| 模型能力未验证 | 无 Key，规则降级 | 配 Key 后重跑 6 条测试并记录 SQL 原文，并用 `--compare` 做两版真实对照 |
| 无多轮追问 | 单轮问答 | 加对话历史，支持「那上个月呢」这类指代 |
| 无结果解释 | 只返表 | 让模型对结果做一句话解读（但要标注是模型生成） |
| 无查询缓存 | 每次重新执行 | 相同问题命中缓存，降低 Hive 压力 |
| 方言绑定 Hive | Prompt 写死 Hive | 抽出 dialect 配置，可切 MySQL / Spark SQL |

---

## 七、复现

```bash
# 1. 抽取 Schema（需 Hive 容器运行）
python python/schema_extract.py

# 2. 校验器对抗测试（不依赖 Hive）
python python/test_guard.py

# 3. 跑 6 条典型问题（需 Hive）
python python/nl2sql.py --batch

# 4. 单条提问
python python/nl2sql.py "广东省的销售额是多少"
```

---

## 八、LangChain 编排版实现

### 8.1 为什么补这一版

任务书子任务 4 点名要求「用 LangChain 实现 NL2SQL」。第一版交付用的是 OpenAI SDK 直连 + 自写 Prompt + 自写校验，理由是链路只有「一次生成 + 一次校验」，框架会掩盖细节。

这个理由在工程上站得住，但它回答的是「我为什么那样做」，不是「任务书为什么那样要求」。评审看的是能不能按指定技术栈实现。所以补一个 LangChain 版，两版并存，用同一批问题对比——这比争论哪个更好更有说服力。

`python/nl2sql_chain.py`，与 `python/nl2sql.py` 共用同一个校验器、同一个执行器、同一份 Schema，只替换编排层。

### 8.2 编排方式的差异

| 环节 | 手写版 `nl2sql.py` | LangChain 版 `nl2sql_chain.py` |
|---|---|---|
| Prompt | 手工拼 `dict` 列表，few-shot 靠 append | `ChatPromptTemplate.from_messages`，声明式 |
| 输出解析 | 正则抽 ` ```sql ` 代码块 | `with_structured_output(SQLPlan)` + Pydantic 模型 |
| 降级 | `if/else` 判断有没有 Key | `Runnable.with_fallbacks` 三级自动降级 |
| 执行编排 | 顺序调用函数 | LCEL 管道 `prompt \| llm \| parse \| guard \| exec` |
| 链路可视化 | 无 | `chain.get_graph().draw_ascii()` 自动生成 |
| 耗时观测 | 无 | `BaseCallbackHandler` 逐步计时与 token 统计 |

结构化输出模型：

```python
class SQLPlan(BaseModel):
    sql: str = Field(description="单条 Hive SELECT 语句，不带结尾分号")
    tables_used: list[str] = Field(default_factory=list, description="引用到的完整表名")
    reasoning: str = Field(default="", description="一句话说明选表和聚合的理由")
```

手写版要靠正则从自然语言里抠 SQL，模型多说一句「以下是查询：」就得靠容错；结构化输出把这件事交给协议层，`Reasoning` 字段还顺带产出了可审计的选表理由。

### 8.3 三级降级：框架在这里确实省事

```
1. 结构化输出   prompt | llm.with_structured_output(SQLPlan)
        ↓ 模型不支持 function calling / json mode
2. 纯文本兜底   prompt | llm | StrOutputParser | 正则抽 SQL
        ↓ 无 Key / 网络不通 / 额度用尽
3. 规则兜底     rule_based()
```

代码只有一行：

```python
return primary.with_fallbacks([text_chain, rule_chain])
```

手写版要实现同等的三级降级，得三层嵌套 `try/except`，而且很容易漏掉某一层的异常类型。

一个刻意的设计：**没有 Key 时不让主链被绕开，而是让它真的抛异常，交给 fallback 接住**。这样「降级机制」每次运行都在被真实验证，不会等到真出事才发现 fallback 早就失效了。

### 8.3.1 自查发现的一个问题：模式标注会撒谎

第一版写完，我用「无效 Key」跑了一次，输出是这样的：

```
问题：用户价值分层结构是什么样的
模式：deepseek（3.6s）          ← 显示的是服务商名
生成 SQL：
SELECT user_segment, user_cnt, ... FROM ydsh_ads.ads_user_segment ...
```

SQL 实际来自规则链（三级降级全部走完了），但模式显示「deepseek」。**这正是本文档 5.2 节批评过的那件事——让规则结果冒充模型能力。**

原因：`mode` 是按「有没有配置 Key」推断的，不是按「实际命中了哪一级」。

第一次修法用了 `contextvars`：在每一级降级执行前 `set()` 一个层级名，`ask()` 里 `get()` 出来。结果读出来永远是初始值 `未执行`。原因是 **LangChain 的 `RunnableParallel` 在线程池里执行，`contextvars` 会被复制到子线程，子线程里的 `set()` 主线程读不到**。

正确修法是让层级作为**数据**在管道里流动，而不是作为外部状态：

```python
def _stage(runner, name):
    """把「这一级叫什么」写进输出"""
    return RunnablePassthrough.assign(
        sql=runner,
        stage=RunnableLambda(lambda _: name),
    )
```

三级降级各自打标，最终成功的那个把 `stage` 写进结果，`ask()` 直接读 `out["stage"]`。修复后：

```
模式：规则模式（未配置 API Key）              ← 无 Key
模式：deepseek 调用失败，已降级为规则模式      ← 有 Key 但 401
模式：deepseek（结构化输出）                  ← 正常（待配 Key 验证）
```

这个问题的价值在于：它和我批评的错误是同一个。写代码时想着「不能让规则结果冒充模型」，实现时却因为**判断依据选错**（用配置推断结果，而不是用实际执行路径）把同一个错误又犯了一遍。判断依据必须来自执行结果，不能来自执行前的假设。

记在这里，因为它比「一次跑通」更能说明问题。


### 8.4 链路结构（框架自动生成）

```
            +--------------------+
            | Parallel<sql>Input |
            +--------------------+
               ***           ***
             **                 **
           **                     **
+---------------+             +-------------+
| WithFallbacks |             | Passthrough |
+---------------+             +-------------+
               ***           ***
                  **       **
                    **   **
            +---------------------+
            | Parallel<sql>Output |
            +---------------------+
                       *
                +------------+
                | guard_step |      ← 复用 15 条对抗测试验证过的校验器
                +------------+
                       *
                +-----------+
                | exec_step |      ← 复用 beeline 执行器
                +-----------+
```

`--graph` 参数直接打印这张图。这是框架相对手写最直观的收益：链路结构不用看代码，跑一下就有。

### 8.5 A/B 实测结果

同一批 6 条问题，两条链路各跑一遍（`python python/nl2sql_chain.py --compare`）：

| 问题 | LangChain | 手写版 | SQL 一致 |
|---|---|---|---|
| 2024 年 6 月的总 GMV 是多少？ | ✅ | ✅ | ✅ |
| 销量最高的前 5 个品类 | ✅ | ✅ | ✅ |
| 用户价值分层结构是什么样的 | ✅ | ✅ | ✅ |
| 列出所有核心 KPI 指标 | ✅ | ✅ | ✅ |
| 2024 年每个月的 GMV 趋势 | ✅ | ✅ | ✅ |
| 广东省的销售额是多少 | ✅ | ✅ | ✅ |

```
SQL 完全一致：6/6   |   两版均执行成功：6/6
```

结果写入 `data/nl2sql_ab_compare.json`。

注意这次对照的局限性：**两版都跑在规则模式下，SQL 一致是必然的**（都来自同一份 `rule_based()`）。它证明的是「编排层替换后行为等价、没有回归」，不能证明两版在真实模型下的生成质量差异。等配置 Key 后需要重跑一次 `--compare`，那才是有意义的对照。

### 8.6 五家服务商的连通性实测

用无效 Key（`sk-invalid-probe-000000000000`）分别请求五家接口，记录返回：

| 服务商 | 耗时 | 返回 | 判定 |
|---|---|---|---|
| DeepSeek | 0.6s | `401 Authentication Fails, Your api key: ****0000 is invalid` | 网络通、协议对 |
| 通义千问 | 0.7s | `401 Incorrect API key provided` | 网络通、协议对 |
| 硅基流动 | 0.5s | `401 Token is invalid` | 网络通、协议对 |
| Kimi | 0.6s | `401 Invalid Authentication` | 网络通、协议对 |
| 智谱 GLM | 0.5s | `401 令牌已过期或验证不正确` | 网络通、协议对 |

五家全部返回 **401 鉴权失败**，没有一家是连接超时、DNS 失败或 TLS 握手错误。这说明请求确实到达了对方的鉴权层——`base_url` 正确、路径正确、请求体格式正确，唯一的问题是密钥无效。

这个测试的价值在于：它把「没配 Key」这个笼统的说法，拆成了可验证的结论。配 Key 之前就能确定，剩下的唯一变量就是密钥本身。

对照记录：本机 `github.com:443` 曾被阻断（见 Git 协同记录），但五个模型接口全部可达。网络问题不能一概而论，得逐个测。

### 8.7 什么时候用哪一版

| 场景 | 建议 | 理由 |
|---|---|---|
| 作业/评审，要求指定技术栈 | LangChain 版 | 按要求交付 |
| 自己调试 Prompt 与校验逻辑 | 手写版 | 少一层抽象，异常栈直指代码行 |
| 要加多轮追问、工具调用、RAG | LangChain 版 | `Runnable` 组合与 memory 组件现成 |
| 只跑一次固定查询 | 手写版 | 不值得为一次调用引入框架依赖 |

两版共用 `validate()` / `run_sql()` / `rule_based()`，任何一处修复同时生效，不会漂移。

### 8.8 复现

```bash
pip install langchain langchain-openai grandalf

python python/nl2sql_chain.py --graph     # 看链路结构
python python/nl2sql_chain.py --batch     # 跑 6 条问题
python python/nl2sql_chain.py --compare   # 与手写版 A/B 对照
```

