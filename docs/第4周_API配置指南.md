# 第 4 周 · API 配置指南

> 覆盖本项目用到的四类接口：大模型 API、内部取数 API、Superset 数据源、存储层原生接口。
> 原则只有一条：**密钥只存在 `.env` 里，代码与仓库里只出现"变量名"**。

---

## 一、大模型 API（NL2SQL 与洞察生成）

### 1.1 支持的服务商

五家全部走 **OpenAI 兼容协议**（`/chat/completions`），不引入各家私有 SDK。
好处是换一家只改一行配置，代价是个别私有能力（如通义的联网插件）用不了。
解析逻辑集中在 `python/llm_provider.py` 的 `PROVIDERS` 表里，`nl2sql.py`、
`nl2sql_chain.py`、`llm_ping.py` 共用同一张表，不会各写一份而漂移。

| 优先级 | 变量前缀 | 控制台 | 默认模型 | 说明 |
|---|---|---|---|---|
| 1 | `DEEPSEEK_` | https://platform.deepseek.com/api_keys | `deepseek-chat` | 中文与 SQL 表现好，新账号有赠送额度 |
| 2 | `DASHSCOPE_` | https://bailian.console.aliyun.com/ | `qwen-plus` | 阿里百炼，新用户有免费 token |
| 3 | `SILICONFLOW_` | https://cloud.siliconflow.cn/account/ak | `Qwen/Qwen2.5-7B-Instruct` | 有长期免费模型，零成本验证链路首选 |
| 4 | `MOONSHOT_` | https://platform.moonshot.cn/console/api-keys | `moonshot-v1-8k` | Kimi，长上下文 |
| 5 | `ZHIPU_` | https://open.bigmodel.cn/usercenter/apikeys | `glm-4-flash` | `glm-4-flash` 免费；Key 是 `xxx.xxx` 两段，别只复制前一段 |

### 1.2 配置步骤

```bash
cp .env.example .env
# 编辑 .env，取消注释并填入任意一家的 Key，例如：
#   DEEPSEEK_API_KEY=sk-xxxxxxxxxxxxxxxx
#   DEEPSEEK_MODEL=deepseek-chat
```

### 1.3 连通性验证

```bash
# 测当前优先级最高的那家
docker exec ydsh-app python /app/python/llm_ping.py

# 遍历所有已配置的服务商
docker exec ydsh-app python /app/python/llm_ping.py --all

# 换模型 / 换提示词
docker exec ydsh-app python /app/python/llm_ping.py --provider deepseek --model deepseek-chat
docker exec ydsh-app python /app/python/llm_ping.py --list-models
```

`llm_ping.py` 只做一件事：发一条最小请求，把**耗时、模型名、返回内容**打出来。
它不写业务 SQL，避免"连通性测试"和"功能测试"混在一起，出问题时能一眼分清是网络、
密钥、模型名，还是 Prompt 的问题。

### 1.4 未配置 Key 时的降级

| 脚本 | 无 Key 时的行为 |
|---|---|
| `nl2sql.py` | 走**规则模式**：用关键词匹配预置模板，能回答常见问题 |
| `nl2sql_chain.py` | 走 LangChain `with_fallbacks` 三级降级（模型 → 规则 → 兜底话术） |
| `app/app.py` | 状态栏显示 `MODE: 规则`，并在回答下方注明"未接入大模型" |

降级不是"假装成功"：界面上明确标注当前是规则模式，生成结果不会被伪装成模型输出。

---

## 二、内部取数 API（ECharts 大屏用）

标准库 `http.server` 实现，无第三方依赖，端口 8000。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/dashboard.json` | 大屏全量数据（9 类图表 + KPI + 元信息） |
| GET | `/api/kpi` | 只取 KPI 卡片数值 |
| GET | `/api/health` | 健康检查，返回 `{"status":"ok"}` |
| GET | `/` | 简易索引页，列出全部端点 |

特性：

- **CORS 全放开**（`Access-Control-Allow-Origin: *`），因为大屏既可能用 `file://` 直接打开，
  也可能从别的端口访问；
- **按 mtime 缓存**：数据文件没变就不重复读盘，一个进程内多请求共享同一份字节；
- 数据来源是 `dashboard/echarts/data/dashboard.json`，由
  `python/export_dashboard_data.py` 从 Hive/ClickHouse 导出后落盘，**API 只读不查库**。

```bash
curl -s http://localhost:8000/api/kpi
curl -s http://localhost:8000/api/dashboard.json | head -c 300
```

大屏的加载策略是**双通道**：优先 `fetch` 走 API，失败则回落到页面内联的
`window.DASHBOARD_DATA`（由 `dashboard.js` 注入）——这样把 `index.html` 拷到任何
没有后端的机器上双击打开也能看，答辩现场不怕断网。

---

## 三、Superset 数据源

三个数据源都由 `superset/provision.py` 幂等创建，不需要手工在界面上点。

| 名称 | 连接串 | 用途 |
|---|---|---|
| Hive 数仓 (ydsh_ads) | `hive://hive@hive-server:10000/ydsh_ads` | ADS 结果表源头（重计算） |
| MySQL 服务层 (ydsh_ads) | `mysql+pymysql://root:****@mysql:3306/ydsh_ads?charset=utf8mb4` | 已物化的小结果表（秒级） |
| ClickHouse 加速层 (ydsh_ads) | `clickhousedb+connect://default:****@clickhouse:8123/ydsh_ads` | 明细/聚合大表（毫秒级） |

三个坑，配之前先知道：

1. **驱动要自己装**。`apache/superset:4.1.1` 官方镜像连 MySQL 驱动都没有，
   `pip list` 里查不到 `pymysql`/`mysqlclient`，更别说 Hive 的 thrift 协议栈。
   项目里用 `superset/Dockerfile` 基于官方镜像补 `pymysql` / `pyhive` /
   `thrift-sasl` / `pure-sasl` / `clickhouse-connect`。
2. **MySQL 要冒充 MySQLdb**。Superset 的 `MySQLEngineSpec` 有两处写死 `import MySQLdb`，
   URI 写 `mysql+pymysql://` 也绕不过，图表会统一报 `No module named 'MySQLdb'`。
   在 `superset_config.py` 里 `pymysql.install_as_MySQLdb()` 即可。
3. **Hive 要关 catalog 探测**。4.1 建 Hive 数据源会先跑 `SHOW CATALOGS`，
   `apache/hive:4.0.0` 不认这个语法，返回 422。设
   `HiveEngineSpec.supports_catalog = False` 走无 catalog 分支。

---

## 四、存储层原生接口

### 4.1 ClickHouse HTTP

```bash
# 读：GET 即可
curl -s "http://127.0.0.1:8123/?user=default&password=$CLICKHOUSE_PASSWORD" \
     --data-binary "SELECT count() FROM ydsh_ads.sales_daily"

# 写：必须 POST —— GET 会被强制按只读执行，报 Cannot execute query in readonly mode
curl -s "http://127.0.0.1:8123/?user=default&password=$CLICKHOUSE_PASSWORD" \
     --data-binary "INSERT INTO ydsh_ads.sales_daily FORMAT CSV" < data/serving/sales_daily.csv
```

`python/load_clickhouse.py` 里就是靠 `use_post = modify or body is not None` 这一行区分读写，
`TRUNCATE` 即使没有 body 也走 POST。

### 4.2 Hive（pyhive / beeline / JDBC）

```python
# pyhive：程序内访问，比 beeline 快一个数量级（0.3~0.8s vs 数秒）
from pyhive import hive
conn = hive.connect(host="hive-server", port=10000, username="hive", database="ydsh_ads")
cur = conn.cursor(); cur.execute("SELECT * FROM ads_kpi_core"); print(cur.fetchall())
```

```bash
# beeline：命令行排障用，能看 Tez 执行细节
docker exec ydsh-hive-server beeline -u "jdbc:hive2://localhost:10000/ydsh_ads" \
  --outputformat=tsv2 -e "SELECT * FROM ads_kpi_core"
```

JDBC（DBeaver / DataGrip）：
`jdbc:hive2://127.0.0.1:10000/ydsh_ads`，用户 `hive`，无密码，驱动
`org.apache.hive.jdbc.HiveDriver`。

### 4.3 MySQL

容器内 `3306`，宿主机映射到 **3307**（3306 被本机 MySQL80 占用）：

```bash
mysql -h 127.0.0.1 -P 3307 -uroot -p     # 宿主机客户端
docker exec -it ydsh-mysql mysql -uroot -p   # 容器内
```

---

## 五、密钥管理checklist

部署或交接前逐条过：

- [ ] `.env` 在 `.gitignore` 里，且 `git ls-files` 里查不到 `.env`
- [ ] `git log -p --all -S "sk-"` 无明文命中
- [ ] `SUPERSET_SECRET_KEY` 是随机生成的 42 字节 base64，不是示例值
- [ ] 数据库口令 ≥ 12 位，且与 `.env.example` 里的占位符不同
- [ ] 容器日志里搜不到 Key（`docker compose logs | grep -i "sk-"`）
- [ ] `.env.example` 里只有占位符 `sk-your-key-here`
- [ ] 生产环境把 `SESSION_COOKIE_SECURE` 置 `True` 并前置 TLS
