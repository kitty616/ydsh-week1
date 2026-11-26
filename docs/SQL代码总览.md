# SQL 代码总览（云购生活数据仓库）

> 关联周期：第 1–5 周　|　整理时间：2026-11-26　|　版本：v1.0
> 覆盖范围：`sql/` 目录下全部 21 个脚本（3,107 行），以及散落在 Python 里的内嵌 SQL
> 合并版全文：`sql/ALL_SQL.sql`（3,242 行，按执行顺序拼接，仅供阅读）

---

## 一、一句话结论

**21 个文件、3,107 行、5 个层次（ODS / CLEAN / DWD / DWS / ADS）、47 张落库表。**
（脚本里共出现 53 个唯一表名，其中 6 张 `stg_*` 是「暂存表 → 换名」手法留下的中间表，跑完即 RENAME 或 DROP，库里查不到。）
全部脚本都是「建表 + INSERT OVERWRITE」的幂等写法，可以反复重跑，不会产生重复数据。

| 层次 | 目录 | 文件数 | 行数 | 职责 |
|---|---|---|---|---|
| ODS 贴源层 | `sql/ods/` | 4 | 242 | 6 张 CSV 原样入库，字段全 string，不做任何加工 |
| CLEAN 清洗层 | `sql/clean/` | 8 | 1,580 | 质量评估 → 五类清洗 → 验收对比 |
| DWD 明细层 | `sql/dwd/` | 5 | 696 | 星型模型：4 张维度 + 1 张事实（分区 + 分桶） |
| DWS 汇总层 | `sql/dws/` | 2 | 321 | 六维粒度（日/周/月/品类/门店/渠道）+ 用户粒度 |
| ADS 应用层 | `sql/ads/` | 2 | 268 | 长表指标 + 面向业务的三张场景表 |
| **合计** | | **21** | **3,107** | |

---

## 二、执行顺序（7 步，与部署手册一致）

顺序不能乱：**贴源 → 清洗 → 建模 → 汇总 → 应用**，每一步的输入都是上一步的输出。

```bash
# 第 1 步：建库建表 + 导入 6 张 CSV（ODS 层，15,600 / 37,549 等）
for f in sql/ods/0*.sql; do bash scripts/run_sql.sh "$f"; done

# 第 2 步：数据质量预评估（五维度打分，写入 dq_report）
bash scripts/run_sql.sh sql/clean/10_quality_assessment.sql

# 第 3 步：清洗（缺失 / 重复 / 枚举 / 异常格式 / 拆分合并）
for f in sql/clean/1[1-3]_*.sql sql/clean/2[0-3]_*.sql; do bash scripts/run_sql.sh "$f"; done

# 第 4 步：维度表 + 事实表建模与装载
for f in sql/dwd/3[0-3]_*.sql; do bash scripts/run_sql.sh "$f"; done

# 第 5 步：EDA 与第一批 ADS 指标
bash scripts/run_sql.sh sql/dwd/40_eda.sql

# 第 6 步：DWS 多维汇总（第 3 周口径）+ 用户粒度
for f in sql/dws/5[01]_*.sql; do bash scripts/run_sql.sh "$f"; done

# 第 7 步：ADS 指标长表 + 业务场景表
bash scripts/run_sql.sh sql/ads/60_build_ads_kpi.sql
bash scripts/run_sql.sh sql/ads/61_build_ads_app.sql
```

> `scripts/run_sql.sh` 内部做的事：把 SQL 文件 `docker cp` 进 `ydsh-hive-server` 容器 → `beeline -f` 执行 → 回收输出。
> 在 Git Bash 下必须先 `export MSYS2_ARG_CONV_EXCL='*'`，否则 `/tmp/x.sql` 会被改写成 `C:/...`。

---

## 三、逐文件说明

### 3.1 ODS 贴源层（4 个文件 / 242 行）

| 文件 | 行数 | 读 → 写 | 做什么 | 关键点 |
|---|---|---|---|---|
| `00_init_database.sql` | 17 | — → 2 个库 | 建 `ydsh_ods`、`ydsh_dwd` | 只建库不建表，库路径显式指定 `/user/hive/warehouse/` |
| `01_create_ods_tables.sql` | 161 | — → 6 张表 | 6 张贴源表 DDL | **字段全部 string**（贴源层不做过早类型转换）；`skip.header.line.count=1` 跳表头；`TBLPROPERTIES` 记录来源 CSV |
| `02_load_data.sql` | 36 | 6 个 CSV → 6 张表 | `LOAD DATA LOCAL INPATH` 导入 | 用 `OVERWRITE` 保证可重跑；路径 `/data/xxx.csv` 靠 compose 的卷映射 |
| `03_check_rowcount.sql` | 28 | 6 张表 → 控制台 | 导入后行数核对 | 期望值写死在 SQL 里（1000/600/60/15600/37549/60000），差一行就报警 |

**6 张 ODS 表的预期行数**（来自 `03_check_rowcount.sql`，实测全部一致）：

| 表 | 预期行数 | 说明 |
|---|---|---|
| `ods_user` | 1,000 | 用户信息 |
| `ods_product` | 600 | 商品 |
| `ods_store` | 60 | 门店 |
| `ods_order` | 15,600 | 订单主表（含约 600 条重复） |
| `ods_order_item` | 37,549 | 订单明细 |
| `ods_user_behavior` | 60,000 | 行为日志 |
| **合计** | **114,809** | 与 6 个 CSV 的 `wc -l` 完全吻合 |

### 3.2 CLEAN 清洗层（8 个文件 / 1,580 行）

| 文件 | 行数 | 读 → 写 | 做什么 | 关键点 |
|---|---|---|---|---|
| `10_quality_assessment.sql` | 311 | 6 张 ODS → `dq_report` | 五维度质量打分 | 完整性 / 唯一性 / 有效性 / 一致性 / 准确性，每个维度一条打分 SQL，结果落表，不用手工汇总 |
| `11_clean_missing_value.sql` | 151 | ODS → `dwd_user` / `dwd_product` | 缺失值处理 | age 用中位数填；email 缺失**不臆造**，加 `email_flag` 标记；launch_date 用同品类最早日期补 |
| `12_clean_duplicate.sql` | 103 | `ods_order` → `dwd_order` | 去重 | 区分两类：整行重复直接留一条；主键重复但内容不同按业务规则排序取最新版本。**Hive 不支持 DELETE，用 CTAS 生成新表** |
| `13_verify_cleaning.sql` | 89 | 各层 → 控制台 | 清洗结果验收 | 答辩现场只跑这一份即可，每段末尾有关键判定标准 |
| `20_enum_standardize.sql` | 345 | ODS → 6 张 `dwd_*_clean` | 枚举标准化 | 收敛 7 个字段的脏值：gender 8 种、member_level 12 种、order_status 12 种、pay_type 7 种、channel 6 种、behavior_type 10 种、category 16 种（含尾随空格变体） |
| `21_abnormal_format.sql` | 172 | `dwd_*_clean` 原地 | 异常值 + 格式 | 金额 ≤0 或超 IQR 上界删除；quantity ≤0 删行；`cost > price` 按成本×1.2 修正；手机号/日期统一格式并加 `*_flag` 标记 |
| `22_split_merge_map.sql` | 202 | `dwd_*_clean` 原地 | 拆分合并 + 码表 | 合并 `order_date + order_time → order_timestamp`、`province + city → region`；建 5 张码表，**DWD 只存编码，展示层 JOIN 取中文名** |
| `23_quality_compare.sql` | 207 | ODS + clean → `dq_compare` | 清洗前后对比 | 修复率 = (清洗前问题数 − 清洗后问题数) / 清洗前问题数，五类分别算，结果供《数据质量清洗报告》取数 |

**这一层为什么全用 CTAS 而不是 UPDATE**：Hive 默认不支持行级 UPDATE / DELETE，事务表要额外配置且性能差。教材里的 `update ... set age = 均值` 在本环境直接报错，所以统一改成「读旧表 → 建新表」。

### 3.3 DWD 明细层（5 个文件 / 696 行）

| 文件 | 行数 | 读 → 写 | 做什么 | 关键点 |
|---|---|---|---|---|
| `30_create_dim_tables.sql` | 131 | clean → `dim_user` / `dim_product` / `dim_store` / `dim_date` | 4 张维度表 | 只放描述性属性，度量一律进事实表；主键统一 `<实体>_id`；全表 ORC + SNAPPY；`dim_date` 预生成连续日期，避免事实表跑字符串函数 |
| `31_create_fact_order.sql` | 71 | — → `dwd_order` / `dwd_order_bucket` | 事实表 DDL | 按 `order_date` **动态分区**（查询都带时间范围，可分区裁剪）；另建一张按 `user_id` 哈希 8 桶的分桶表做对照实验 |
| `32_load_dwd.sql` | 98 | clean → 维度 + 事实 | 装载 | **先维度后事实**——事实表外键必须在维度表里查得到，否则 JOIN 出报表时金额会落不到维度上 |
| `33_load_dws.sql` | 135 | DWD → `dws_daily_sales` / `dws_store_sales` / `dws_category_sales` | 第 2 周的 DWS | 3 张「全期一条汇总」，只够做总览，没有时间粒度 |
| `40_eda.sql` | 261 | DWD + DWS → 5 张 ADS | 探索性分析 | 顺序是「先总量、后结构、再个体」；用到窗口函数做累计、排名、复购、RFM；产出 `ads_kpi_overview` / `ads_region_sales` / `ads_channel_sales` / `ads_store_rank` / `ads_user_value` |

> **注意**：`33_load_dws.sql` 与 `sql/dws/50_build_dws_multi.sql` 是**两代 DWS**。第 2 周那版只有 3 张无时间粒度的汇总表；第 3 周改成保留时间粒度的 6 张表。现在跑报表用的是 50 号，33 号保留作为演进痕迹。

### 3.4 DWS 汇总层（2 个文件 / 321 行）

| 文件 | 行数 | 读 → 写 | 做什么 | 关键点 |
|---|---|---|---|---|
| `50_build_dws_multi.sql` | 258 | DWD → 6 张 DWS | 六维粒度汇总 | 日 / 周 / 月 / 品类 / 门店 / 渠道。**第 5 周修过一个静默丢数的坑**：品类汇总原用 inner join 关联明细，139 笔「明细被整单剔除」的订单被整笔吃掉，349,609.44 元（0.97%）消失两周；改成 `UNION ALL` 归入「未知品类」后行数 2,927 → 3,043，金额精确回到全站口径 |
| `51_build_dws_user.sql` | 63 | `dwd_order` → `dws_user_stat` | 用户粒度宽表 | 复购率、价值分层、活跃天数都基于用户粒度，单建一张避免 ADS 层重复扫事实表 |

**50 号脚本里两个不能删的注释**（alter 前先读）：

```sql
-- 1) 明细为空的订单不能丢，归入「未知品类」单独成行
-- 2) 存储层不取整：先按分组 ROUND 再相加，3,043 个分组会累积出 0.13 元的舍入漂移，
--    sum(分组) == 总量 这个可加性必须保住，取整交给展示层
```

### 3.5 ADS 应用层（2 个文件 / 268 行）

| 文件 | 行数 | 读 → 写 | 做什么 | 关键点 |
|---|---|---|---|---|
| `60_build_ads_kpi.sql` | 131 | DWS → `ads_kpi_core` / `ads_monthly_trend` | 核心 KPI | **做成「长表」而不是宽表**：每行是「指标名 / 值 / 单位 / 口径说明」。宽表每加指标要改结构，长表只增行；口径说明跟着指标一起交付，避免「数出多门」 |
| `61_build_ads_app.sql` | 137 | DWS + ADS → `ads_sales_daily_report` / `ads_category_topn` / `ads_user_segment` | 业务场景表 | 日报回答「今天怎么样」、TopN 回答「卖得最好的是什么」、用户分层回答「客户结构健康吗」，三者都不需要业务方自己 join |

---

## 四、表清单（脚本里出现的 53 个表名 / 落库 47 张）

> 行标 `stg_*` 的 6 张是暂存表：`ALTER TABLE stg_x RENAME TO dwd_x_clean` 之后名字就没了，所以最终库中不出现。
> 下列「落库表数」是 2026-11-26 在容器里 `SHOW TABLES` 实测：ODS 6 + DWD 21 + DWS 10 + ADS 10 = **47**。

| 库 | 表 | 产出脚本 |
|---|---|---|
| `ydsh_ods` | `ods_user` `ods_product` `ods_store` `ods_order` `ods_order_item` `ods_user_behavior` | 01 |
| `ydsh_dwd` | `dq_report` | 10 |
| | `dwd_user` `dwd_product` | 11 |
| | `dwd_order`（第 2 周版） | 12 |
| | `dwd_user_clean` `dwd_product_clean` `dwd_store_clean` `dwd_order_clean` `dwd_order_item_clean` `dwd_user_behavior_clean` | 20 |
| | `stg_user` `stg_product` `stg_store` `stg_order` `stg_order_item` `stg_behavior` `stg_amount_threshold` | 21 / 22（暂存，RENAME 为正式表后消失） |
| | `dim_member_level` `dim_pay_type` `dim_order_status` `dim_channel` `dim_behavior_type` | 22 |
| | `dq_compare` | 23 |
| | `dim_user` `dim_product` `dim_store` `dim_date` | 30 |
| | `dwd_order` `dwd_order_bucket` | 31 |
| `ydsh_dws` | `dws_daily_sales` `dws_store_sales` `dws_category_sales` | 33 |
| | `dws_trade_day` `dws_trade_week` `dws_trade_month` `dws_category_day` `dws_store_day` `dws_channel_day` | 50 |
| | `dws_user_stat` | 51 |
| `ydsh_ads` | `ads_kpi_overview` `ads_region_sales` `ads_channel_sales` `ads_store_rank` `ads_user_value` | 40 |
| | `ads_kpi_core` `ads_monthly_trend` | 60 |
| | `ads_sales_daily_report` `ads_category_topn` `ads_user_segment` | 61 |

> `stg_*` 是「暂存表 → 换名」手法留下的中间表，脚本里已 `ALTER TABLE ... RENAME TO dwd_*_clean`，最终库里看不到——这也是为什么脚本写 53 个表名、库里只有 47 张。

---

## 五、散落在 Python 里的 SQL（不在 `sql/` 目录，但同样要能找到）

| 位置 | 内容 | 说明 |
|---|---|---|
| `python/load_mysql.py` | 6 张表的 MySQL DDL | `sales_daily` / `monthly` / `category` / `region` / `pay_type` / `store_rank`，服务层用 |
| `python/load_clickhouse.py` | 4 张 ClickHouse 表 | `sales_daily` / `trade_monthly` / `category_day` / `channel_day`；**写操作必须 POST**，GET 会被强制只读 |
| `python/export_dashboard_data.py` | 7 条 ADS 查询 | 导出大屏 JSON 快照：KPI、月趋势、日报、品类 TopN、区域、渠道、门店排行 |
| `python/bench_query.py` | 4 组实验查询 | E1 分区裁剪、E2 小表 Join（MAPJOIN 是否必要）、E3 三引擎同口径（Hive / ClickHouse / MySQL）、E4 并发压测 |
| `python/nl2sql.py` | 提示词里的 few-shot SQL + 兜底固定 SQL | 5 条模板查询，另含 SQL 白名单校验逻辑 |
| `python/verify_e2e.py` | 各层核对查询 | 端到端 67 条断言里的取数语句（只读） |
| `superset/provision.py` | 数据源与图表注册 | 通过 Superset API，不是原生 SQL |

> 这部分的完整语句建议直接看源文件，行号已在表格里给出定位依据（文件名 + 用途）。

---

## 六、速查

```bash
# 看合并版全文（3,242 行，按执行顺序）
less sql/ALL_SQL.sql

# 只列文件清单与行数
find sql -name "*.sql" | sort | xargs wc -l

# 找所有写表动作
grep -rhoiE "INSERT OVERWRITE TABLE [a-z_.]+" sql/ | sort -u

# 找所有建表动作
grep -rhoiE "CREATE TABLE (IF NOT EXISTS )?[a-z_.]+" sql/ | sort -u

# 现场验证某张表有没有数据
docker exec ydsh-hive-server beeline -u jdbc:hive2://localhost:10000 --silent=true \
  -e "SELECT COUNT(*) FROM ydsh_dws.dws_category_day;"
```

---

## 变更记录

| 版本 | 日期 | 内容 |
|---|---|---|
| v1.0 | 2026-11-26 | 首版。21 个文件清点完毕，逐文件说明 + 47 张落库表清单 + Python 内嵌 SQL 定位；同步生成 `sql/ALL_SQL.sql` 合并版 |
