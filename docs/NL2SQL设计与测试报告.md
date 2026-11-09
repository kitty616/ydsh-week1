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
    ├─ 自动补库名前缀
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
| 表名白名单 | 抓 `FROM` / `JOIN` 后的标识符，比对 14 张表白名单 |
| 自动补库名 | 裸表名自动补 `ydsh_ads.` 前缀 |
| 自动加 LIMIT | 无 `LIMIT` 时追加 `LIMIT 200` |

### 4.3 对抗测试结果

`python/test_guard.py`，11 条用例 **全部通过（11/11）**：

| 用例 | 期望 | 实际 | 判定 |
|---|---|---|---|
| 正常查询（带库名） | 通过 | 通过 | PASS |
| 正常查询（裸表名，自动补全） | 通过 | 通过 | PASS |
| 正常查询（聚合 + JOIN） | 通过 | 通过 | PASS |
| 危险：DELETE | 拒绝 | 拒绝 | PASS |
| 危险：DROP TABLE | 拒绝 | 拒绝 | PASS |
| 危险：UPDATE | 拒绝 | 拒绝 | PASS |
| 危险：多语句注入 | 拒绝 | 拒绝 | PASS |
| 错误：编造的库表 | 拒绝 | 拒绝 | PASS |
| 错误：非 SELECT 开头 | 拒绝 | 拒绝 | PASS |
| 错误：空输出 | 拒绝 | 拒绝 | PASS |
| 边界：子查询里的裸表名 | 通过 | 通过 | PASS |

拦截原因实际输出（节选）：

```
· 危险：DELETE：包含写操作关键字，已拦截；不是 SELECT / WITH 开头
· 危险：多语句注入：包含写操作关键字，已拦截
· 错误：编造的库表：引用了白名单外的表：ydsh_ods.ods_sales_fact
· 错误：空输出：模型没有返回 SQL
```

裸表名补全实测：`SELECT month, gmv FROM ads_monthly_trend` → `SELECT month, gmv FROM ydsh_ads.ads_monthly_trend LIMIT 200`。

### 4.4 校验器拦不住什么

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

原因：当前环境没有配置大模型 API Key（`DEEPSEEK_API_KEY` / `DASHSCOPE_API_KEY` 均未设置）。`nl2sql.py` 检测到无 Key 后自动降级为内置规则匹配，覆盖上述 6 类问法。

这意味着：

- ✅ **链路是通的**：Schema → 生成 → 校验 → 执行 → 结果，每一环都真实跑过。
- ✅ **校验器是真实的**：11 条对抗测试全部真实执行。
- ❌ **模型能力未被验证**：规则模式只能证明"如果有一条正确的 SQL，这个链路能跑通"，不能证明"模型能生成正确的 SQL"。

这个区别必须写清楚。把规则模式的结果当成模型效果汇报，是自欺。

### 5.3 如何切换到真实模型

```bash
cp .env.example .env
# 编辑 .env，填入 DEEPSEEK_API_KEY=sk-xxxx
python python/nl2sql.py --batch
```

代码已就绪，`call_llm()` 走 OpenAI 兼容接口，切换 Key 后无需改任何逻辑。届时输出中的「模式」会从「规则模式」变为「大模型」。

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
| 模型能力未验证 | 无 Key，规则降级 | 配 Key 后重跑 6 条测试并记录 SQL 原文 |
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
