# API 配置指南

| 项 | 内容 |
|---|---|
| 文档编号 | YDSH-API-001 |
| 版本 | v2.0（第 5 周整合版，v1.0 为第 4 周版） |
| 更新日期 | 2026-11-22 |
| 维护人 | 曲欣锋 |
| 适用对象 | 需要配置大模型、调用取数接口、直连数据库的开发/运维 |
| 关联文档 | 《部署手册》《架构设计文档》 |

本系统的"API"分四类，配置方式完全不同，先看清你要配哪一个：

| 类别 | 用途 | 是否必需 | 配置位置 |
|---|---|---|---|
| ① 大模型 API | NL2SQL 生成 SQL、AI 洞察 | 可选（不配则规则兜底） | `.env` |
| ② 内部取数 API | 大屏拉取 JSON | 可选（不配则用内联快照） | 随容器启动 |
| ③ BI 数据源 | Superset 连数仓 | 必需 | `provision.py` |
| ④ 存储层原生接口 | 程序内查询 Hive / ClickHouse / MySQL | 必需 | 环境变量 |

---

## 一、大模型 API

### 1.1 支持的服务商

`python/llm_provider.py` 里维护了一张 `PROVIDERS` 表，**按顺序取第一个有 Key 的**：

| 优先级 | 服务商 | 环境变量 | 默认模型 | 控制台 |
|---|---|---|---|---|
| 1 | DeepSeek | `DEEPSEEK_API_KEY` | `deepseek-chat` | https://platform.deepseek.com/api_keys |
| 2 | 阿里百炼 | `DASHSCOPE_API_KEY` | `qwen-plus` | https://bailian.console.aliyun.com/ |
| 3 | 硅基流动 | `SILICONFLOW_API_KEY` | `Qwen/Qwen2.5-7B-Instruct` | https://cloud.siliconflow.cn/account/ak |
| 4 | Moonshot | `MOONSHOT_API_KEY` | `moonshot-v1-8k` | https://platform.moonshot.cn/console/api-keys |
| 5 | 智谱 | `ZHIPU_API_KEY` | `glm-4-flash` | https://bigmodel.cn/usercenter/proj-mgmt/apikeys |

**只配一家就够。** 三家都配也不会更快，只会让"到底用的哪家"变得不清楚。

### 1.2 配置步骤

```bash
# 1) 复制模板
cp .env.example .env

# 2) 填入任意一家的 Key（不要加引号，不要留空格）
DEEPSEEK_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxx

# 3) 验证：优先用哪家、模型是什么
docker exec ydsh-app python /app/python/llm_ping.py

# 4) 遍历所有已配置的服务商，看哪家能通
docker exec ydsh-app python /app/python/llm_ping.py --all
```

成功时输出：

```
优先使用：deepseek  deepseek-chat  https://api.deepseek.com/v1
✓ 连通，耗时 1.8s
```

### 1.3 覆盖默认模型

```bash
DEEPSEEK_MODEL=deepseek-reasoner      # 换模型
DEEPSEEK_THINKING=1                   # 部分服务商支持思考模式开关
```

### 1.4 不配 Key 会怎样

问答会**自动降级为规则匹配**：内置十余条常见问题的正则映射，能答"总 GMV""Top N 品类"
这类固定问法，答不了自由提问。界面上会明确显示「模式：规则兜底」，
**不会把规则结果伪装成大模型结果**。

### 1.5 密钥安全（这条是硬要求）

| 要求 | 做法 |
|---|---|
| 不入库 | `.env` 在 `.gitignore` 里；`.dockerignore` 也排除，镜像里不含 |
| 不进代码 | 所有 Key 通过环境变量读取，代码里没有默认值 |
| 不进日志 | 报错信息只输出状态码与错误类型，不打印 Key |
| 提交前自查 | `git log -p --all -S "sk-"` 与 `git grep -nE "sk-[A-Za-z0-9]{16}"` |

> **一条真实教训**：本周 `tools/shot.js` 的用法注释里写了
> `--login admin:真实口令` 作为示例，被扫描抓出。**注释和示例也是仓库内容。**
> 改掉文件只是止血——只要进过 `git log`，正确做法就是**轮换口令**，
> 而不是 `git commit --amend` 抹痕迹。

---

## 二、内部取数 API

由 `app/api_server.py` 提供，**只用 Python 标准库**，无第三方依赖，随 `api` 容器启动。

| 端点 | 方法 | 返回 | 用途 |
|---|---|---|---|
| `/api/health` | GET | `{"ok": true, "ts": 1700000000}` | 健康检查 |
| `/api/dashboard.json` | GET | 完整大屏数据集 | 大屏主数据源 |
| `/api/kpi` | GET | 10 个核心 KPI | KPI 卡片 |
| `/` | GET | HTML 索引页 | 手工调试 |

### 2.1 调用示例

```bash
curl -s http://localhost:8000/api/health
# {"ok": true, "ts": 1732233600}

curl -s http://localhost:8000/api/kpi | python -m json.tool | head -20
```

`/api/dashboard.json` 的响应结构：

```json
{
  "generated_at": "2026-11-22T10:30:00",
  "source": "hive",
  "kpi": { "gmv": 36116687.06, "order_cnt": 14398, "aov": 2508.45, "...": "..." },
  "monthly": [{"month": "2024-01", "gmv": 2829996.31, "order_cnt": 1123, "mom_rate": null}],
  "daily":   [{"dt": "2024-01-01", "gmv": 98234.12, "order_cnt": 39}],
  "category": [{"category": "运动户外", "gmv": 5347686.69, "share": 0.1481}],
  "region":  [{"province": "陕西省", "gmv": 2851136.58, "ratio": 0.079}],
  "channel": [{"name": "小程序", "gmv": 12345678.90, "ratio": 0.34}],
  "pay_type": [{"name": "微信支付", "gmv": 15000000.00, "ratio": 0.42}],
  "store_rank": [{"rank": 1, "store_name": "西安旗舰店", "gmv": 1234567.89}],
  "store_scatter": [{"name": "西安旗舰店", "gmv": 1234567.89, "order_cnt": 412}],
  "heatmap": [[0, 0, 1.23, 45]]
}
```

### 2.2 CORS 与缓存

- 响应头 `Access-Control-Allow-Origin: *`，允许本地 `file://` 或任意端口的前端直接调；
- `dashboard.json` 在进程内做了缓存，文件未变更时不重复读盘；
- 文件不存在时返回 503 + 提示，而不是空对象——**空对象会让前端画出一张空图，比报错更难排查**。

---

## 三、Superset 数据源

`superset/provision.py` 用容器内 ORM 幂等创建，连接串如下（口令从环境变量读，不写死）：

| 数据源名称 | URI | 用途 |
|---|---|---|
| Hive 数仓 (ydsh_ads) | `hive://hive@hive-server:10000/ydsh_ads` | 主数据源，10 张 ADS 表 |
| MySQL 服务层 (ydsh_ads) | `mysql+pymysql://root:***@mysql:3306/ydsh_ads?charset=utf8mb4` | 低延迟宽表 |
| ClickHouse 加速层 (ydsh_ads) | `clickhousedb+connect://default:***@clickhouse:8123/ydsh_ads` | 高并发聚合 |

### 3.1 三个坑（都实际踩过）

| 现象 | 原因 | 解决 |
|---|---|---|
| `Database could not be created` (422) | Superset 4.1 建 Hive 源时探测 `SHOW CATALOGS`，`apache/hive:4.0.0` 不认 | `HiveEngineSpec.supports_catalog = False` |
| `No module named 'MySQLdb'` | Superset 硬编码 `import MySQLdb` | `pymysql.install_as_MySQLdb()` |
| `The CSRF token is missing` (400) | 纯 Bearer 调写接口 | 弃用 REST，改容器内 ORM 脚本 |

### 3.2 重建资产

```bash
docker exec ydsh-superset python /app/pythonpath/provision.py
```

脚本是**幂等**的：同名数据源/数据集/图表会更新而不是重复创建，可以随时重跑。

---

## 四、存储层原生接口

### 4.1 Hive（pyhive，程序内首选）

```python
from pyhive import hive
conn = hive.connect(host="hive-server", port=10000, username="hive", database="ydsh_ads")
cur = conn.cursor()
cur.execute("SELECT ROUND(SUM(gmv),2) FROM dws_trade_month WHERE month='2024-06'")
print(cur.fetchall())   # [(2829996.31,)]
```

**为什么不用 beeline**：beeline 每次启动 JVM 客户端要数秒，pyhive 直连 thrift 约
0.3~0.8 秒，快一个数量级。应用与脚本统一走 pyhive。

### 4.2 ClickHouse（HTTP）

```bash
# 读：GET 即可
curl -s "http://localhost:8123/?user=default&password=$CK_PASS" \
     --data-binary "SELECT count() FROM ydsh_ads.sales_daily"

# 写：必须 POST —— GET 会被强制按只读执行
curl -s "http://localhost:8123/?user=default&password=$CK_PASS" \
     --data-binary "TRUNCATE TABLE ydsh_ads.sales_daily"
```

**易错点**：即使 body 为空，`TRUNCATE` / `ALTER` / `INSERT` 也必须用 POST。
用 GET 会报 `Cannot execute query in readonly mode`——错误信息看起来像权限问题，
其实是 HTTP 方法的语义限制。

### 4.3 MySQL

```bash
# 命令行
docker exec ydsh-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM ydsh_ads.sales_daily;"

# 程序内
import pymysql
conn = pymysql.connect(host="mysql", user="root", password=os.environ["MYSQL_ROOT_PASSWORD"],
                       database="ydsh_ads", charset="utf8mb4")
```

**注意**：`mysql` CLI 会往 stdout 打 `Using a password on the command line interface can be insecure.`
警告。脚本里解析输出必须先过滤这行，否则会把警告当成查询结果（`load_mysql.py` 里有 `clean_lines()`）。

---

## 五、错误码与排查

| 现象 | 含义 | 排查 |
|---|---|---|
| `10004` | Hive 语义错误：列不存在 | 模型常见错误：给只有 `month` 的表写 `WHERE year='2024'`。已加提示词约束 + 报错回灌自修复 |
| `10001` | Hive 语法错误 | 看生成的 SQL 原文 |
| `401` | 大模型 Key 无效/过期 | `llm_ping.py --all` 逐家试 |
| `429` | 大模型限流 | 降低并发；问答是单请求，一般不会触发 |
| `503` | 取数 API 找不到 `dashboard.json` | 先跑 `export_dashboard_data.py` |
| `(1045, "Access denied ...")` | 数据库口令错或没注入 | 检查容器内 `printenv`，不要只看 `docker ps` |

---

## 六、成本与限流参考

| 项 | 量级 |
|---|---|
| 单次 NL2SQL 问答 | 约 1,500 input tokens + 200 output tokens |
| 单次 AI 洞察 | 约 3,000 input + 800 output |
| 免费额度 | 智谱 `glm-4-flash`、硅基流动 `Qwen2.5-7B` 基本可零成本完成全部演示 |
| 建议 | 演示环境用免费模型，效果对比再用付费模型跑一次 |

---

## 七、变更记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 第 4 周 | 四类 API 的配置与调用说明 |
| v2.0 | 第 5 周 | 补全 5 家服务商优先级表、`dashboard.json` 响应结构、错误码表、成本参考；把"密钥进过 git log 要轮换"写成明确要求 |
