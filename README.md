# 云购生活 · 企业级数据仓库与经营分析可视化系统

> 第 1 周交付物 · 项目启动 / 环境搭建 / Git 基础 / 数据导入与数据清洗（一）
> 课程：企业项目实战实训 ｜ 数据科学与大数据技术（本科）

---

## 一、团队信息

| 项目 | 内容 |
|---|---|
| 团队名称 | 【待填写】 |
| 团队口号 | 【待填写】 |
| 团队成员 | 【姓名1】、【姓名2】、【姓名3】、【姓名4】 |

### 角色分工

| 姓名 | 角色 | 本周负责内容 |
|---|---|---|
| 【待填写】 | 项目经理（兼数仓工程师） | 进度统筹、需求分析、架构设计、Git 分支管理 |
| 【待填写】 | 数据工程师 | Docker 环境、ODS 建表导入、清洗脚本 |
| 【待填写】 | 数据分析师 / AI 工程师 | 数据质量预评估、探索性分析 |
| 【待填写】 | 可视化 / 部署工程师 | 环境文档、仪表板预留、部署脚本 |

> 说明：3 人团队可一人多岗，允许「可视化 / 部署工程师」由项目经理兼任。

---

## 二、项目目标（第 1 周范围）

1. 完成 Docker + Hive + MySQL 本地环境搭建，服务可连通
2. 完成 Git 仓库初始化与团队协作规范落地
3. 将 6 张 CSV 模拟数据导入 Hive ODS 贴源层，行数校验通过
4. 从完整性、唯一性、有效性、一致性、准确性五个维度完成数据质量预评估
5. 完成数据清洗（一）：缺失值诊断与处理、重复值检测与去重

---

## 三、技术栈

| 类别 | 技术 / 工具 | 用途 |
|---|---|---|
| 数据仓库 | Apache Hive 4.0.0 | 四层数仓建模与 ETL 计算 |
| 关系型数据库 | MySQL 8.0 | Metastore 元数据 / 维度表 / ADS 结果回写 |
| 编程语言 | Python（pandas / scikit-learn） | 数据探索与预测建模 |
| 可视化 | Apache Superset、ECharts | 仪表板与数据大屏 |
| 部署 | Docker + Docker Compose | 全本地化一键部署 |
| 版本控制 | Git + GitHub / GitLab | 团队协作与代码托管 |

---

## 四、模拟数据集

| 文件名 | ODS 表名 | 预期行数 | 说明 |
|---|---|---|---|
| ods_user.csv | ods_user | 1,000 | 用户信息表 |
| ods_product.csv | ods_product | 600 | 商品信息表 |
| ods_store.csv | ods_store | 60 | 门店信息表 |
| ods_order.csv | ods_order | 15,600 | 订单主表（含约 600 条重复） |
| ods_order_item.csv | ods_order_item | 37,549 | 订单明细表 |
| ods_user_behavior.csv | ods_user_behavior | 60,000 | 用户行为日志表 |

**五类脏数据**：缺失值、重复值、异常值、格式不一致、业务逻辑错误。

---

## 五、目录结构

```
ydsh_week1/
├── README.md                      # 本文件：团队信息、目标、执行手册
├── .gitignore                     # 忽略数据/日志/密钥
├── docker-compose.yml             # Hive + MySQL 一键编排
├── data/                          # 6 张 CSV 放这里（不入库）
│   └── README.md
├── sql/
│   ├── ods/
│   │   ├── 00_init_database.sql   # 建库
│   │   ├── 01_create_ods_tables.sql  # 6 张表建表
│   │   ├── 02_load_data.sql       # 导入数据
│   │   └── 03_check_rowcount.sql   # 行数校验
│   └── clean/
│       ├── 10_quality_assessment.sql  # 五维度质量预评估
│       ├── 11_clean_missing_value.sql # 缺失值处理
│       ├── 12_clean_duplicate.sql     # 重复值去重
│       └── 13_verify_cleaning.sql     # 清洗结果验证
├── scripts/
│   ├── import_ods.sh              # 一键导入 ODS
│   └── run_sql.sh                 # 一键执行任意 SQL 文件
└── docs/
    ├── 环境搭建笔记.md              # 交付物 2
    └── 数据质量预评估表.md          # 交付物 5
```

---

## 六、执行顺序（照着做即可）

### 步骤 0：准备数据文件
把老师提供的 6 个 CSV 放进 `data/` 目录，**文件名必须完全一致**（全小写）：
`ods_user.csv`、`ods_product.csv`、`ods_store.csv`、`ods_order.csv`、`ods_order_item.csv`、`ods_user_behavior.csv`

### 步骤 1：启动环境
```bash
docker compose up -d
docker ps                      # 应看到 ydsh-mysql / ydsh-hive-metastore / ydsh-hive-server 三个 Up
```
首次启动 Hive Metastore 会自动初始化 MySQL 中的元数据库，约需 40~90 秒，请耐心等待。

### 步骤 2：等待并验证服务
```bash
docker logs -f ydsh-hive-metastore     # 看到 "Started Hive Metastore" 即可 Ctrl+C
docker exec -it ydsh-hive-server beeline -u jdbc:hive2://localhost:10000
```
进入 beeline 后执行 `show databases;`，能看到 `default` 即成功。

### 步骤 3：建库建表 + 导入
```bash
bash scripts/run_sql.sh sql/ods/00_init_database.sql
bash scripts/run_sql.sh sql/ods/01_create_ods_tables.sql
bash scripts/run_sql.sh sql/ods/02_load_data.sql
bash scripts/run_sql.sh sql/ods/03_check_rowcount.sql
```
或直接 `bash scripts/import_ods.sh` 一次跑完。

**校验标准**：6 张表行数与 README 第四节预期行数一致（脏数据允许极少量偏差）。

### 步骤 4：数据质量预评估
```bash
bash scripts/run_sql.sh sql/clean/10_quality_assessment.sql
```
执行完毕后查询汇总表：
```sql
SELECT * FROM ydsh_dwd.dq_report ORDER BY table_name, dimension;
```
把结果填进 `docs/数据质量预评估表.md`。

### 步骤 5：数据清洗
```bash
bash scripts/run_sql.sh sql/clean/11_clean_missing_value.sql
bash scripts/run_sql.sh sql/clean/12_clean_duplicate.sql
bash scripts/run_sql.sh sql/clean/13_verify_cleaning.sql
```

**校验标准**：
- `dwd_user.age` 无空值、无 <1、无 >120
- `dwd_order.order_id` 无重复
- 去重前后行数差 ≈ 预评估阶段发现的重复订单数（约 600）

---

## 七、命名规范

| 层级 | 数据库 | 说明 |
|---|---|---|
| ODS | `ydsh_ods` | 贴源层，与 CSV 一一对应，不做加工 |
| DWD | `ydsh_dwd` | 明细层，本周产出 `dwd_user` / `dwd_product` / `dwd_order` |

| 对象 | 规范 | 示例 |
|---|---|---|
| 表名 | 小写下划线，`层_业务_粒度` | `dwd_order` |
| 字段名 | 小写下划线 | `pay_amount` |
| 脚本 | `序号_动作.sql` | `11_clean_missing_value.sql` |

---

## 八、Git 提交规范

采用 Conventional Commits：

| 前缀 | 用途 | 示例 |
|---|---|---|
| `feat:` | 新增功能/脚本 | `feat: 新增 ODS 六表建表脚本` |
| `fix:` | 修复问题 | `fix: 修正 ods_order 分隔符` |
| `docs:` | 文档变更 | `docs: 补充环境搭建笔记` |
| `refactor:` | 重构 | `refactor: 抽出去重逻辑为公共脚本` |
| `chore:` | 杂项 | `chore: 更新 .gitignore` |

分支策略：`main`（可交付） ← `dev`（集成分支） ← `feature/xxx`（个人开发）

---

## 九、第 1 周交付物核对

| 序号 | 交付物 | 对应文件 | 状态 |
|---|---|---|---|
| 1 | README.md | `README.md` | □ |
| 2 | 环境搭建笔记 | `docs/环境搭建笔记.md` | □ |
| 3 | Git 仓库（含提交历史） | `.gitignore` + 提交记录 | □ |
| 4 | ODS 建表与导入脚本 | `sql/ods/` | □ |
| 5 | 数据质量预评估表 | `docs/数据质量预评估表.md` | □ |
| 6 | 缺失值 / 重复值处理脚本 | `sql/clean/` | □ |

---

## 十、常见问题

见 `docs/环境搭建笔记.md` 的「问题记录」章节，团队遇到新问题请随手补充——这份笔记本身就是交付物之一。
