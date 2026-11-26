-- ============================================================================
-- 云购生活 · 全量 SQL 代码合并版（ALL_SQL.sql）
-- 用途：把 sql/ 下 21 个脚本按执行顺序拼成一份，便于查阅、打印、交作业
-- 生成时间：2026-11-26 14:51
-- 注意：本文件仅供阅读，实际执行请逐个跑原文件（顺序见 docs/SQL代码总览.md）
-- ============================================================================

-- 目录
--   01. sql/ods/00_init_database.sql                 17 行
--   02. sql/ods/01_create_ods_tables.sql            161 行
--   03. sql/ods/02_load_data.sql                     36 行
--   04. sql/ods/03_check_rowcount.sql                28 行
--   05. sql/clean/10_quality_assessment.sql         311 行
--   06. sql/clean/11_clean_missing_value.sql        151 行
--   07. sql/clean/12_clean_duplicate.sql            103 行
--   08. sql/clean/13_verify_cleaning.sql             89 行
--   09. sql/clean/20_enum_standardize.sql           345 行
--   10. sql/clean/21_abnormal_format.sql            172 行
--   11. sql/clean/22_split_merge_map.sql            202 行
--   12. sql/clean/23_quality_compare.sql            207 行
--   13. sql/dwd/30_create_dim_tables.sql            131 行
--   14. sql/dwd/31_create_fact_order.sql             71 行
--   15. sql/dwd/32_load_dwd.sql                      98 行
--   16. sql/dwd/33_load_dws.sql                     135 行
--   17. sql/dwd/40_eda.sql                          261 行
--   18. sql/dws/50_build_dws_multi.sql              258 行
--   19. sql/dws/51_build_dws_user.sql                63 行
--   20. sql/ads/60_build_ads_kpi.sql                131 行
--   21. sql/ads/61_build_ads_app.sql                137 行


-- ############################################################################
-- ## [01/21] sql/ods/00_init_database.sql   （17 行）
-- ############################################################################

-- =============================================================
-- 00_init_database.sql
-- 作用：创建项目所需的数据库
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 00_init_database.sql
-- =============================================================

-- ODS 贴源层：与 6 张 CSV 一一对应，不做任何加工
CREATE DATABASE IF NOT EXISTS ydsh_ods
  COMMENT '云购生活-ODS贴源层'
  LOCATION '/user/hive/warehouse/ydsh_ods.db';

-- DWD 明细层：清洗后的明细数据（本周产出 dwd_user / dwd_product / dwd_order）
CREATE DATABASE IF NOT EXISTS ydsh_dwd
  COMMENT '云购生活-DWD明细层'
  LOCATION '/user/hive/warehouse/ydsh_dwd.db';

SHOW DATABASES;

-- ############################################################################
-- ## [02/21] sql/ods/01_create_ods_tables.sql   （161 行）
-- ############################################################################

-- =============================================================
-- 01_create_ods_tables.sql
-- 作用：在 ydsh_ods 库中创建 6 张贴源表
-- 要点：
--   1) 字段全部先按 string 落贴源层（贴源层原则：不做过早类型转换）
--   2) 分隔符 ','，并跳过 CSV 表头
--   3) 每张表加 TBLPROPERTIES 记录来源文件，便于溯源
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 01_create_ods_tables.sql
-- =============================================================

USE ydsh_ods;

-- -------------------------------------------------------------
-- (1) ods_user —— 用户信息表（预期 1,000 行）
-- 脏数据：gender 中英文混用/空、age 为空/200/-3、
--         register_date 三种日期格式、member_level 中英文混用、phone 格式不一、email 部分缺失
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_user;
CREATE TABLE ods_user (
  user_id        STRING COMMENT '用户编号（主键）',
  user_name      STRING COMMENT '用户姓名',
  gender         STRING COMMENT '性别（含异常值：男/女/M/F/未知/空）',
  age            STRING COMMENT '年龄（含缺失、异常：空/200/-3）',
  city           STRING COMMENT '城市',
  province       STRING COMMENT '省份',
  register_date  STRING COMMENT '注册日期（格式不一致）',
  member_level   STRING COMMENT '会员等级（中英文混用）',
  phone          STRING COMMENT '手机号（格式不一致）',
  email          STRING COMMENT '邮箱（部分缺失）'
)
COMMENT 'ODS-用户信息表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_user.csv'
);

-- -------------------------------------------------------------
-- (2) ods_product —— 商品信息表（预期 600 行）
-- 脏数据：category/brand 大小写与空格异常、price 含负数与 999999 异常高价、launch_date 部分缺失
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_product;
CREATE TABLE ods_product (
  product_id    STRING COMMENT '商品编号（主键）',
  product_name  STRING COMMENT '商品名称',
  category      STRING COMMENT '一级类目（大小写/空格异常）',
  sub_category  STRING COMMENT '二级类目',
  brand         STRING COMMENT '品牌（大小写异常）',
  price         STRING COMMENT '售价（含负数、异常高价）',
  cost          STRING COMMENT '成本价',
  stock         STRING COMMENT '库存数量',
  status        STRING COMMENT '状态：在售/下架/缺货',
  launch_date   STRING COMMENT '上架日期（部分缺失）'
)
COMMENT 'ODS-商品信息表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_product.csv'
);

-- -------------------------------------------------------------
-- (3) ods_store —— 门店信息表（预期 60 行）
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_store;
CREATE TABLE ods_store (
  store_id    STRING COMMENT '门店编号（主键）',
  store_name  STRING COMMENT '门店名称',
  province    STRING COMMENT '省份',
  city        STRING COMMENT '城市',
  district    STRING COMMENT '区县',
  address     STRING COMMENT '详细地址',
  open_date   STRING COMMENT '开业日期',
  area        STRING COMMENT '营业面积（㎡）',
  manager     STRING COMMENT '店长姓名'
)
COMMENT 'ODS-门店信息表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_store.csv'
);

-- -------------------------------------------------------------
-- (4) ods_order —— 订单主表（预期 15,600 行，含约 600 条重复）
-- 脏数据：order_id 重复、order_date 格式不一、pay_amount 含负数与 5000000 异常值、
--         pay_type / order_status / channel 中英文与大小写混用
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_order;
CREATE TABLE ods_order (
  order_id         STRING COMMENT '订单编号（应唯一，含重复）',
  user_id          STRING COMMENT '用户编号',
  store_id         STRING COMMENT '门店编号',
  order_date       STRING COMMENT '下单日期（格式不一致）',
  order_time       STRING COMMENT '下单时间',
  pay_amount       STRING COMMENT '实付金额（含负数、异常）',
  discount_amount  STRING COMMENT '优惠金额',
  pay_type         STRING COMMENT '支付方式（中英文混用）',
  order_status     STRING COMMENT '订单状态（取值不规范）',
  channel          STRING COMMENT '下单渠道（大小写混用）'
)
COMMENT 'ODS-订单主表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_order.csv'
);

-- -------------------------------------------------------------
-- (5) ods_order_item —— 订单明细表（预期 37,549 行）
-- 脏数据：quantity 含 0 / 负数 / 99 超大值
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_order_item;
CREATE TABLE ods_order_item (
  item_id      STRING COMMENT '明细编号（主键）',
  order_id     STRING COMMENT '所属订单编号',
  product_id   STRING COMMENT '商品编号',
  quantity     STRING COMMENT '购买数量（含 0、负数、超大值）',
  unit_price   STRING COMMENT '商品单价',
  discount     STRING COMMENT '折扣率（0~1）'
)
COMMENT 'ODS-订单明细表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_order_item.csv'
);

-- -------------------------------------------------------------
-- (6) ods_user_behavior —— 用户行为日志表（预期 60,000 行）
-- 脏数据：behavior_type 中英文混用、behavior_time 格式不一
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_user_behavior;
CREATE TABLE ods_user_behavior (
  behavior_id    STRING COMMENT '行为编号（主键）',
  user_id        STRING COMMENT '用户编号',
  product_id     STRING COMMENT '商品编号',
  behavior_type  STRING COMMENT '行为类型（中英文混用：pv/cart/fav/buy/浏览）',
  behavior_time  STRING COMMENT '行为发生时间（格式不一致）',
  session_id     STRING COMMENT '会话编号'
)
COMMENT 'ODS-用户行为日志表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_user_behavior.csv'
);

SHOW TABLES;

-- ############################################################################
-- ## [03/21] sql/ods/02_load_data.sql   （36 行）
-- ############################################################################

-- =============================================================
-- 02_load_data.sql
-- 作用：将 6 张 CSV 从容器内 /data 目录加载进 ODS 表
-- 说明：
--   docker-compose.yml 已把宿主机 ./data 映射到容器 /data，
--   因此 LOCAL INPATH 使用 /data/xxx.csv（由 HiveServer2 所在容器读取）
--   使用 OVERWRITE 保证脚本可重复执行（不会重复追加）
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 02_load_data.sql
-- =============================================================

SET hive.exec.compress.output = false;

LOAD DATA LOCAL INPATH '/data/ods_user.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_user;

LOAD DATA LOCAL INPATH '/data/ods_product.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_product;

LOAD DATA LOCAL INPATH '/data/ods_store.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_store;

LOAD DATA LOCAL INPATH '/data/ods_order.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_order;

LOAD DATA LOCAL INPATH '/data/ods_order_item.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_order_item;

LOAD DATA LOCAL INPATH '/data/ods_user_behavior.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_user_behavior;

-- ---------------------------------------------------------------
-- 若报 "Invalid path '/data/xxx.csv': No files matching path file"
-- 说明宿主机 data/ 目录里缺文件，或文件名大小写不一致：
--   Windows 下 ods_user.CSV 与 ods_user.csv 在容器 Linux 中不是同一个文件，
--   请统一改成全小写 .csv
-- ---------------------------------------------------------------

-- ############################################################################
-- ## [04/21] sql/ods/03_check_rowcount.sql   （28 行）
-- ############################################################################

-- =============================================================
-- 03_check_rowcount.sql
-- 作用：导入后行数校验，与《数据字典》预期行数对比
-- 判定：允许因脏数据造成极小偏差，但核心事实表必须达到万级规模
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 03_check_rowcount.sql
-- =============================================================

USE ydsh_ods;

SELECT 'ods_user'         AS table_name, COUNT(*) AS actual_cnt, 1000  AS expect_cnt, COUNT(*) - 1000  AS diff FROM ods_user
UNION ALL
SELECT 'ods_product'      AS table_name, COUNT(*) AS actual_cnt, 600   AS expect_cnt, COUNT(*) - 600   AS diff FROM ods_product
UNION ALL
SELECT 'ods_store'        AS table_name, COUNT(*) AS actual_cnt, 60    AS expect_cnt, COUNT(*) - 60    AS diff FROM ods_store
UNION ALL
SELECT 'ods_order'        AS table_name, COUNT(*) AS actual_cnt, 15600 AS expect_cnt, COUNT(*) - 15600 AS diff FROM ods_order
UNION ALL
SELECT 'ods_order_item'   AS table_name, COUNT(*) AS actual_cnt, 37549 AS expect_cnt, COUNT(*) - 37549 AS diff FROM ods_order_item
UNION ALL
SELECT 'ods_user_behavior' AS table_name, COUNT(*) AS actual_cnt, 60000 AS expect_cnt, COUNT(*) - 60000 AS diff FROM ods_user_behavior;

-- ---------------------------------------------------------------
-- 若某张表行数为 0，常见原因：
--   1) CSV 未放进 data/ 目录
--   2) 文件名大小写不一致（Linux 区分大小写）
--   3) 表头未跳过（行数 = 预期 + 1）→ 检查 skip.header.line.count
--   4) CSV 使用了引号包裹且字段内含逗号 → 改用 OpenCSVSerde 建表
-- ---------------------------------------------------------------

-- ############################################################################
-- ## [05/21] sql/clean/10_quality_assessment.sql   （311 行）
-- ############################################################################

-- =============================================================
-- 10_quality_assessment.sql
-- 作用：对 6 张 ODS 表做五维度数据质量预评估，结果写入 ydsh_dwd.dq_report
-- 五维度：
--   完整性 Completeness —— 字段是否为空
--   唯一性 Uniqueness   —— 主键是否重复 / 整行是否重复
--   有效性 Validity     —— 枚举取值是否在合法集合内
--   一致性 Consistency  —— 格式是否统一（日期 / 手机号 / 大小写）
--   准确性 Accuracy     —— 数值是否在业务合理区间
-- 结果：执行完成后直接查 dq_report 即可，无需再手工汇总
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 10_quality_assessment.sql
-- =============================================================

-- -------------------------------------------------------------
-- 环境说明（重要）
-- Tez / MR 默认 mapreduce.job.counters.max = 120，
-- 而本脚本单条 INSERT 内含 8 个 UNION ALL 分支，计数器会超过上限，报：
--   Counters limit exceeded: Too many counters: 121 max=120
--
-- 该上限必须在 HiveServer2 启动时读取，运行期 SET 或在 beeline 启动参数里
-- 注入 --hiveconf 都无效。已通过 conf/hive-site.xml 挂载覆盖容器默认配置：
--   mapreduce.job.counters.max        = 4000
--   mapreduce.job.counters.groups.max = 4000
--   tez.counters.max                  = 4000
-- 若重装环境，请确认 docker-compose.yml 中 hive-server 的
-- ./conf/hive-site.xml 挂载存在，否则本脚本会报上述错误。
-- -------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS ydsh_dwd;

DROP TABLE IF EXISTS ydsh_dwd.dq_report;
CREATE TABLE ydsh_dwd.dq_report (
  table_name  STRING COMMENT '表名',
  dimension   STRING COMMENT '质量维度',
  metric      STRING COMMENT '检查项',
  total_cnt   BIGINT COMMENT '总行数',
  bad_cnt     BIGINT COMMENT '问题行数',
  bad_ratio   DOUBLE COMMENT '问题占比'
)
COMMENT '数据质量预评估汇总表'
STORED AS ORC;

-- =============================================================
-- 一、ods_user（用户信息表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
-- 完整性
SELECT 'ods_user','完整性','age 为空',
       COUNT(*),
       SUM(CASE WHEN age IS NULL OR TRIM(age)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN age IS NULL OR TRIM(age)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'ods_user','完整性','email 为空',
       COUNT(*),
       SUM(CASE WHEN email IS NULL OR TRIM(email)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN email IS NULL OR TRIM(email)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
-- 唯一性
UNION ALL
SELECT 'ods_user','唯一性','user_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT user_id),
       ROUND((COUNT(*) - COUNT(DISTINCT user_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
-- 有效性
UNION ALL
SELECT 'ods_user','有效性','gender 取值非法(含空)',
       COUNT(*),
       SUM(CASE WHEN gender IS NULL OR TRIM(gender)=''
                 OR LOWER(TRIM(gender)) NOT IN ('男','女','m','f','male','female','未知') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN gender IS NULL OR TRIM(gender)=''
                 OR LOWER(TRIM(gender)) NOT IN ('男','女','m','f','male','female','未知') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'ods_user','有效性','member_level 中英文混用/非法',
       COUNT(*),
       SUM(CASE WHEN member_level IS NULL OR TRIM(member_level)=''
                 OR LOWER(TRIM(member_level)) NOT IN ('普通','银卡','金卡','钻石','normal','silver','gold','diamond','普通会员','银卡会员','金卡会员','钻石会员') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN member_level IS NULL OR TRIM(member_level)=''
                 OR LOWER(TRIM(member_level)) NOT IN ('普通','银卡','金卡','钻石','normal','silver','gold','diamond','普通会员','银卡会员','金卡会员','钻石会员') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
-- 一致性
UNION ALL
SELECT 'ods_user','一致性','register_date 非 yyyy-MM-dd',
       COUNT(*),
       SUM(CASE WHEN register_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN register_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'ods_user','一致性','phone 去掉非数字后不是 11 位',
       COUNT(*),
       SUM(CASE WHEN REGEXP_REPLACE(phone,'[^0-9]','') NOT RLIKE '^[0-9]{11}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN REGEXP_REPLACE(phone,'[^0-9]','') NOT RLIKE '^[0-9]{11}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
-- 准确性
UNION ALL
SELECT 'ods_user','准确性','age 超出 1~120 区间',
       COUNT(*),
       SUM(CASE WHEN age IS NOT NULL AND TRIM(age)<>'' AND age RLIKE '^-?[0-9]+$'
                 AND (CAST(age AS INT) < 1 OR CAST(age AS INT) > 120) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN age IS NOT NULL AND TRIM(age)<>'' AND age RLIKE '^-?[0-9]+$'
                 AND (CAST(age AS INT) < 1 OR CAST(age AS INT) > 120) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user;

-- =============================================================
-- 二、ods_product（商品信息表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_product','完整性','launch_date 为空',
       COUNT(*),
       SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','唯一性','product_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT product_id),
       ROUND((COUNT(*) - COUNT(DISTINCT product_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','有效性','status 不在 在售/下架/缺货 之内',
       COUNT(*),
       SUM(CASE WHEN status IS NULL OR TRIM(status) NOT IN ('在售','下架','缺货') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN status IS NULL OR TRIM(status) NOT IN ('在售','下架','缺货') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','一致性','category 含首尾空格或大小写不统一',
       COUNT(*),
       SUM(CASE WHEN category IS NULL OR category <> TRIM(category)
                 OR TRIM(category) <> LOWER(TRIM(category)) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN category IS NULL OR category <> TRIM(category)
                 OR TRIM(category) <> LOWER(TRIM(category)) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','准确性','price 为负或 >= 100000',
       COUNT(*),
       SUM(CASE WHEN CAST(price AS DOUBLE) <= 0 OR CAST(price AS DOUBLE) >= 100000 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(price AS DOUBLE) <= 0 OR CAST(price AS DOUBLE) >= 100000 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','准确性','cost 大于 price',
       COUNT(*),
       SUM(CASE WHEN CAST(cost AS DOUBLE) > CAST(price AS DOUBLE) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(cost AS DOUBLE) > CAST(price AS DOUBLE) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product;

-- =============================================================
-- 三、ods_store（门店信息表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_store','完整性','manager 为空',
       COUNT(*),
       SUM(CASE WHEN manager IS NULL OR TRIM(manager)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN manager IS NULL OR TRIM(manager)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_store
UNION ALL
SELECT 'ods_store','唯一性','store_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT store_id),
       ROUND((COUNT(*) - COUNT(DISTINCT store_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_store
UNION ALL
SELECT 'ods_store','一致性','open_date 非 yyyy-MM-dd',
       COUNT(*),
       SUM(CASE WHEN open_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN open_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_store
UNION ALL
SELECT 'ods_store','准确性','area 非正数或 > 100000',
       COUNT(*),
       SUM(CASE WHEN CAST(area AS INT) <= 0 OR CAST(area AS INT) > 100000 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(area AS INT) <= 0 OR CAST(area AS INT) > 100000 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_store;

-- =============================================================
-- 四、ods_order（订单主表，重点）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_order','完整性','pay_amount 为空',
       COUNT(*),
       SUM(CASE WHEN pay_amount IS NULL OR TRIM(pay_amount)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN pay_amount IS NULL OR TRIM(pay_amount)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','唯一性','order_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT order_id),
       ROUND((COUNT(*) - COUNT(DISTINCT order_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','唯一性','整行完全重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT CONCAT_WS('|', order_id, user_id, store_id, order_date,
                                           order_time, pay_amount, discount_amount,
                                           pay_type, order_status, channel)),
       ROUND((COUNT(*) - COUNT(DISTINCT CONCAT_WS('|', order_id, user_id, store_id, order_date,
                                           order_time, pay_amount, discount_amount,
                                           pay_type, order_status, channel)))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','有效性','order_status 不在合法枚举内',
       COUNT(*),
       SUM(CASE WHEN LOWER(TRIM(order_status)) NOT IN ('已完成','已取消','待付款','已发货','待发货','退款中','completed','cancelled','canceled','pending','paid','shipped','refunding','1','0') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN LOWER(TRIM(order_status)) NOT IN ('已完成','已取消','待付款','已发货','待发货','退款中','completed','cancelled','canceled','pending','paid','shipped','refunding','1','0') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','有效性','pay_type 不在合法枚举内',
       COUNT(*),
       SUM(CASE WHEN LOWER(TRIM(pay_type)) NOT IN ('微信支付','支付宝','银行卡','现金','wechat','alipay','card','cash') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN LOWER(TRIM(pay_type)) NOT IN ('微信支付','支付宝','银行卡','现金','wechat','alipay','card','cash') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','一致性','order_date 非 yyyy-MM-dd',
       COUNT(*),
       SUM(CASE WHEN order_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN order_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','一致性','channel 大小写不统一',
       COUNT(*),
       SUM(CASE WHEN channel IS NULL OR TRIM(channel) <> LOWER(TRIM(channel)) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN channel IS NULL OR TRIM(channel) <> LOWER(TRIM(channel)) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','准确性','pay_amount 为负',
       COUNT(*),
       SUM(CASE WHEN CAST(pay_amount AS DOUBLE) < 0 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(pay_amount AS DOUBLE) < 0 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','准确性','pay_amount 异常高价(> 1000000)',
       COUNT(*),
       SUM(CASE WHEN CAST(pay_amount AS DOUBLE) > 1000000 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(pay_amount AS DOUBLE) > 1000000 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','准确性','discount_amount 大于 pay_amount',
       COUNT(*),
       SUM(CASE WHEN CAST(discount_amount AS DOUBLE) > CAST(pay_amount AS DOUBLE) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(discount_amount AS DOUBLE) > CAST(pay_amount AS DOUBLE) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order;

-- =============================================================
-- 五、ods_order_item（订单明细表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_order_item','完整性','unit_price 为空',
       COUNT(*),
       SUM(CASE WHEN unit_price IS NULL OR TRIM(unit_price)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN unit_price IS NULL OR TRIM(unit_price)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item
UNION ALL
SELECT 'ods_order_item','唯一性','item_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT item_id),
       ROUND((COUNT(*) - COUNT(DISTINCT item_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item
UNION ALL
SELECT 'ods_order_item','有效性','discount 不在 0~1 区间',
       COUNT(*),
       SUM(CASE WHEN CAST(discount AS DOUBLE) < 0 OR CAST(discount AS DOUBLE) > 1 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(discount AS DOUBLE) < 0 OR CAST(discount AS DOUBLE) > 1 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item
UNION ALL
SELECT 'ods_order_item','准确性','quantity <= 0',
       COUNT(*),
       SUM(CASE WHEN CAST(quantity AS INT) <= 0 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(quantity AS INT) <= 0 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item
UNION ALL
SELECT 'ods_order_item','准确性','quantity 超大(>= 50)',
       COUNT(*),
       SUM(CASE WHEN CAST(quantity AS INT) >= 50 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(quantity AS INT) >= 50 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item;

-- =============================================================
-- 六、ods_user_behavior（用户行为日志表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_user_behavior','完整性','session_id 为空',
       COUNT(*),
       SUM(CASE WHEN session_id IS NULL OR TRIM(session_id)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN session_id IS NULL OR TRIM(session_id)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user_behavior
UNION ALL
SELECT 'ods_user_behavior','唯一性','behavior_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT behavior_id),
       ROUND((COUNT(*) - COUNT(DISTINCT behavior_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user_behavior
UNION ALL
SELECT 'ods_user_behavior','有效性','behavior_type 中英文混用/非法',
       COUNT(*),
       SUM(CASE WHEN LOWER(TRIM(behavior_type)) NOT IN ('pv','cart','fav','buy','浏览','加购','收藏','购买') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN LOWER(TRIM(behavior_type)) NOT IN ('pv','cart','fav','buy','浏览','加购','收藏','购买') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user_behavior
UNION ALL
SELECT 'ods_user_behavior','一致性','behavior_time 非 yyyy-MM-dd HH:mm:ss',
       COUNT(*),
       SUM(CASE WHEN behavior_time NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN behavior_time NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user_behavior;

-- =============================================================
-- 查看评估结果
-- =============================================================
SELECT table_name, dimension, metric, total_cnt, bad_cnt, bad_ratio
FROM ydsh_dwd.dq_report
ORDER BY table_name, dimension, metric;

-- ############################################################################
-- ## [06/21] sql/clean/11_clean_missing_value.sql   （151 行）
-- ############################################################################

-- =============================================================
-- 11_clean_missing_value.sql
-- 作用：数据清洗（一）—— 缺失值诊断与处理
-- 覆盖：ods_user.age / ods_user.email / ods_product.launch_date
--
-- ⚠️ 重要：Hive 默认不支持行级 UPDATE / DELETE（事务表配置复杂且性能差），
--    教材手册里写的 `update ... set age = 均值` 在 Hive 中无法执行。
--    正确做法是「读一张表 → 生成新表」，即 INSERT OVERWRITE / CTAS。
--
-- 处理策略：
--   age         缺失或越界( <1 或 >120 ) → 用该字段中位数填充
--   email       缺失 → 保留空值，另加 email_flag 标记，不臆造数据
--   launch_date 缺失 → 用同品类最早上架日期补全；品类内也无则用 2023-01-01
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 11_clean_missing_value.sql
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_dwd;

-- =============================================================
-- 一、dwd_user —— 用户表缺失值处理
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_user;
CREATE TABLE ydsh_dwd.dwd_user
COMMENT 'DWD-用户信息表（已处理缺失值与枚举标准化）'
STORED AS ORC
AS
SELECT
  u.user_id,
  u.user_name,

  -- 性别标准化：男/M/male → 男，女/F/female → 女，其余 → 未知
  CASE
    WHEN LOWER(TRIM(u.gender)) IN ('男','m','male')   THEN '男'
    WHEN LOWER(TRIM(u.gender)) IN ('女','f','female') THEN '女'
    ELSE '未知'
  END AS gender,

  -- 年龄：缺失或越界 → 中位数填充（避免均值被 200 / -3 这类异常值带偏）
  CAST(
    CASE
      WHEN u.age IS NULL OR TRIM(u.age) = '' OR u.age NOT RLIKE '^-?[0-9]+$' THEN s.med_age
      WHEN CAST(u.age AS INT) < 1 OR CAST(u.age AS INT) > 120             THEN s.med_age
      ELSE CAST(u.age AS INT)
    END AS INT
  ) AS age,

  u.city,
  u.province,

  -- 日期标准化：2023/11/25、20231125 → 2023-11-25
  CASE
    WHEN u.register_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN u.register_date
    WHEN u.register_date RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN REGEXP_REPLACE(u.register_date, '/', '-')
    WHEN u.register_date RLIKE '^[0-9]{8}$'
      THEN CONCAT(SUBSTR(u.register_date,1,4), '-', SUBSTR(u.register_date,5,2), '-', SUBSTR(u.register_date,7,2))
    ELSE u.register_date
  END AS register_date,

  -- 会员等级标准化：gold / 金卡会员 → 金卡
  CASE
    WHEN LOWER(TRIM(u.member_level)) IN ('金卡','金卡会员','gold')    THEN '金卡'
    WHEN LOWER(TRIM(u.member_level)) IN ('银卡','银卡会员','silver')  THEN '银卡'
    WHEN LOWER(TRIM(u.member_level)) IN ('钻石','钻石会员','diamond') THEN '钻石'
    WHEN LOWER(TRIM(u.member_level)) IN ('普通','普通会员','normal')  THEN '普通'
    ELSE '未知'
  END AS member_level,

  -- 手机号：去掉 - 与空格，统一为 11 位
  REGEXP_REPLACE(u.phone, '[^0-9]', '') AS phone,

  u.email,
  -- 邮箱缺失不填充，用标记位区分，供后续分析按需过滤
  CASE WHEN u.email IS NULL OR TRIM(u.email) = '' THEN '缺失' ELSE '正常' END AS email_flag

FROM ydsh_ods.ods_user u
CROSS JOIN (
  -- 只统计合法区间 [1,120] 内的年龄，先剔除 200、-3 这类异常值再算中位数
  SELECT ROUND(PERCENTILE(CAST(age AS INT), 0.5)) AS med_age
  FROM ydsh_ods.ods_user
  WHERE age RLIKE '^[0-9]+$' AND CAST(age AS INT) BETWEEN 1 AND 120
) s;

-- =============================================================
-- 二、dwd_product —— 商品表缺失值处理
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_product;
CREATE TABLE ydsh_dwd.dwd_product
COMMENT 'DWD-商品信息表（已补全上架日期并统一类目/品牌大小写）'
STORED AS ORC
AS
SELECT
  p.product_id,
  p.product_name,
  LOWER(TRIM(p.category))     AS category,
  p.sub_category,
  LOWER(TRIM(p.brand))        AS brand,
  CAST(p.price AS DOUBLE)     AS price,
  CAST(p.cost AS DOUBLE)      AS cost,
  CAST(p.stock AS INT)        AS stock,
  TRIM(p.status)              AS status,

  -- 上架日期：按同品类最早上架日期补全，品类内无有效值则兜底 2023-01-01
  CASE
    WHEN p.launch_date IS NULL OR TRIM(p.launch_date) = ''
      THEN COALESCE(c.min_launch, '2023-01-01')
    ELSE p.launch_date
  END AS launch_date

FROM ydsh_ods.ods_product p
LEFT JOIN (
  SELECT LOWER(TRIM(category)) AS category, MIN(launch_date) AS min_launch
  FROM ydsh_ods.ods_product
  WHERE launch_date IS NOT NULL
    AND TRIM(launch_date) <> ''
    AND launch_date RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  GROUP BY LOWER(TRIM(category))
) c
  ON LOWER(TRIM(p.category)) = c.category;

-- =============================================================
-- 三、处理前后对比（写进质量报告）
-- =============================================================
SELECT 'dwd_user'    AS table_name, 'age 空值/越界'  AS item,
       SUM(CASE WHEN age < 1 OR age > 120 THEN 1 ELSE 0 END) AS remain_bad,
       COUNT(*) AS total
FROM ydsh_dwd.dwd_user
UNION ALL
SELECT 'dwd_user', 'email 缺失（保留并标记）',
       SUM(CASE WHEN email_flag = '缺失' THEN 1 ELSE 0 END), COUNT(*)
FROM ydsh_dwd.dwd_user
UNION ALL
SELECT 'dwd_user', 'gender 未知',
       SUM(CASE WHEN gender = '未知' THEN 1 ELSE 0 END), COUNT(*)
FROM ydsh_dwd.dwd_user
UNION ALL
SELECT 'dwd_product', 'launch_date 空值',
       SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END), COUNT(*)
FROM ydsh_dwd.dwd_product;

-- ---------------------------------------------------------------
-- 【策略说明 · 写进质量报告用】
-- 1) 年龄为什么用中位数而不是均值：
--    原始数据含 200、-3 等异常值，均值会被显著拉高；
--    中位数对异常值稳健，且年龄分布通常右偏，中位数更贴近「典型用户」。
-- 2) 邮箱为什么保留空值：
--    邮箱属于弱依赖字段，缺失不影响订单/行为分析；
--    臆造邮箱会污染后续用户画像，故保留空值 + 标记位，由下游按需过滤。
-- 3) 上架日期为什么按品类最早期补全：
--    商品上架日期与该品类整体上新节奏强相关，
--    用同品类最早日期是保守估计（不会产生「未来上架」的错误）。
-- ---------------------------------------------------------------

-- ############################################################################
-- ## [07/21] sql/clean/12_clean_duplicate.sql   （103 行）
-- ############################################################################

-- =============================================================
-- 12_clean_duplicate.sql
-- 作用：数据清洗（一）—— 重复值检测与去重
-- 对象：ydsh_ods.ods_order（订单主表，含约 600 条重复）
--
-- 两类重复必须分开处理：
--   ① 整行完全重复  —— 同一笔订单被重复采集，属于典型的采集端重复投递，直接保留一条
--   ② 主键重复但内容不同 —— 同一 order_id 存在不同字段值（如状态变更、金额修正），
--      这类不能简单去重，要按业务规则排序后保留「最新版本」
--
-- ⚠️ Hive 不支持 DELETE，去重同样通过「生成新表」实现
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 12_clean_duplicate.sql
-- =============================================================

-- =============================================================
-- 一、重复情况诊断（去重前的基线，结果写进质量报告）
-- =============================================================
SELECT
  COUNT(*)                                                        AS total_rows,
  COUNT(DISTINCT order_id)                                        AS distinct_order_id,
  COUNT(*) - COUNT(DISTINCT order_id)                             AS order_id_dup_excess,
  COUNT(DISTINCT CONCAT_WS('|', order_id, user_id, store_id, order_date,
                                   order_time, pay_amount, discount_amount,
                                   pay_type, order_status, channel)) AS distinct_full_row,
  COUNT(*) - COUNT(DISTINCT CONCAT_WS('|', order_id, user_id, store_id, order_date,
                                   order_time, pay_amount, discount_amount,
                                   pay_type, order_status, channel)) AS full_row_dup_excess
FROM ydsh_ods.ods_order;

-- 主键重复 且 内容不同 的订单数（② 类）
SELECT COUNT(*) AS pk_dup_with_diff_content
FROM (
  SELECT order_id
  FROM ydsh_ods.ods_order
  GROUP BY order_id
  HAVING COUNT(*) > 1
     AND COUNT(DISTINCT CONCAT_WS('|', user_id, store_id, order_date, order_time,
                                       pay_amount, discount_amount, pay_type,
                                       order_status, channel)) > 1
) t;

-- 明细：重复的 order_id（取前 20 条观察）
SELECT order_id, COUNT(*) AS cnt
FROM ydsh_ods.ods_order
GROUP BY order_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 20;

-- =============================================================
-- 二、去重：生成 dwd_order
-- 规则：按 order_id 分组，按 order_date + order_time 倒序取第一条（保留最新版本）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_order;
CREATE TABLE ydsh_dwd.dwd_order
COMMENT 'DWD-订单主表（已按 order_id 去重，保留最新版本）'
STORED AS ORC
AS
SELECT
  order_id,
  user_id,
  store_id,
  order_date,
  order_time,
  CASE WHEN pay_amount      RLIKE '^-?[0-9]+([.][0-9]+)?$' THEN CAST(pay_amount      AS DOUBLE) END AS pay_amount,
  CASE WHEN discount_amount RLIKE '^-?[0-9]+([.][0-9]+)?$' THEN CAST(discount_amount AS DOUBLE) END AS discount_amount,
  pay_type,
  order_status,
  channel
FROM (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY order_id
      ORDER BY order_date DESC, order_time DESC
    ) AS rn
  FROM ydsh_ods.ods_order
) t
WHERE rn = 1;

-- ---------------------------------------------------------------
-- 关于类型转换的说明：
--   pay_amount / discount_amount 原为 STRING（贴源层不做类型转换），
--   进入 DWD 层才转为 DOUBLE。
--   这里用 RLIKE 做了防御：格式非法的值转成 NULL 而不会让整个任务失败，
--   非法值会在后续「异常值处理」环节统一修正。
--   枚举值（pay_type / order_status / channel）的统一属于后续周任务，
--   本周只处理缺失值与重复值，保持字段原样以保留痕迹。
-- ---------------------------------------------------------------

-- =============================================================
-- 三、去重前后对比
-- =============================================================
SELECT 'ods_order（去重前）' AS stage, COUNT(*) AS row_cnt FROM ydsh_ods.ods_order
UNION ALL
SELECT 'dwd_order（去重后）' AS stage, COUNT(*) AS row_cnt FROM ydsh_dwd.dwd_order;

-- 去重后校验：order_id 必须唯一
SELECT
  COUNT(*)                        AS total_rows,
  COUNT(DISTINCT order_id)        AS distinct_order_id,
  COUNT(*) - COUNT(DISTINCT order_id) AS remain_dup
FROM ydsh_dwd.dwd_order;

-- ############################################################################
-- ## [08/21] sql/clean/13_verify_cleaning.sql   （89 行）
-- ############################################################################

-- =============================================================
-- 13_verify_cleaning.sql
-- 作用：清洗结果验收（答辩现场直接跑这一份即可）
-- 判定标准见每段末尾的注释
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 13_verify_cleaning.sql
-- =============================================================

-- -------------------------------------------------------------
-- 1. 各层表行数一览
-- -------------------------------------------------------------
SELECT 'ods_user'          AS tbl, COUNT(*) AS cnt FROM ydsh_ods.ods_user
UNION ALL SELECT 'dwd_user',          COUNT(*) FROM ydsh_dwd.dwd_user
UNION ALL SELECT 'ods_product',       COUNT(*) FROM ydsh_ods.ods_product
UNION ALL SELECT 'dwd_product',       COUNT(*) FROM ydsh_dwd.dwd_product
UNION ALL SELECT 'ods_order',         COUNT(*) FROM ydsh_ods.ods_order
UNION ALL SELECT 'dwd_order',         COUNT(*) FROM ydsh_dwd.dwd_order
UNION ALL SELECT 'ods_order_item',    COUNT(*) FROM ydsh_ods.ods_order_item
UNION ALL SELECT 'ods_store',         COUNT(*) FROM ydsh_ods.ods_store
UNION ALL SELECT 'ods_user_behavior', COUNT(*) FROM ydsh_ods.ods_user_behavior;

-- -------------------------------------------------------------
-- 2. 缺失值处理验收：dwd_user.age
--    合格标准：bad_cnt = 0
-- -------------------------------------------------------------
SELECT
  COUNT(*)                                                          AS total,
  SUM(CASE WHEN age IS NULL THEN 1 ELSE 0 END)                       AS null_cnt,
  SUM(CASE WHEN age < 1 OR age > 120 THEN 1 ELSE 0 END)              AS out_of_range_cnt,
  SUM(CASE WHEN age BETWEEN 1 AND 120 THEN 1 ELSE 0 END)             AS valid_cnt,
  ROUND(AVG(age), 2)                                                  AS avg_age,
  MIN(age)                                                            AS min_age,
  MAX(age)                                                            AS max_age
FROM ydsh_dwd.dwd_user;

-- 各年龄段分布（人工抽查是否合理）
SELECT
  CASE WHEN age < 18 THEN '18岁以下'
       WHEN age BETWEEN 18 AND 25 THEN '18-25'
       WHEN age BETWEEN 26 AND 35 THEN '26-35'
       WHEN age BETWEEN 36 AND 45 THEN '36-45'
       WHEN age BETWEEN 46 AND 55 THEN '46-55'
       ELSE '55岁以上' END AS age_group,
  COUNT(*) AS user_cnt
FROM ydsh_dwd.dwd_user
GROUP BY CASE WHEN age < 18 THEN '18岁以下'
              WHEN age BETWEEN 18 AND 25 THEN '18-25'
              WHEN age BETWEEN 26 AND 35 THEN '26-35'
              WHEN age BETWEEN 36 AND 45 THEN '36-45'
              WHEN age BETWEEN 46 AND 55 THEN '46-55'
              ELSE '55岁以上' END
ORDER BY age_group;

-- -------------------------------------------------------------
-- 3. 缺失值处理验收：dwd_user.email / dwd_product.launch_date
--    合格标准：launch_date 的 null_cnt = 0；email 允许保留缺失但必须全部有标记
-- -------------------------------------------------------------
SELECT
  COUNT(*)                                                      AS total,
  SUM(CASE WHEN email IS NULL OR TRIM(email) = '' THEN 1 ELSE 0 END) AS email_null_cnt,
  SUM(CASE WHEN email_flag = '缺失' THEN 1 ELSE 0 END)           AS flag_missing_cnt,
  SUM(CASE WHEN email_flag IS NULL THEN 1 ELSE 0 END)            AS flag_null_cnt
FROM ydsh_dwd.dwd_user;

SELECT
  COUNT(*)                                                              AS total,
  SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date) = '' THEN 1 ELSE 0 END) AS null_cnt
FROM ydsh_dwd.dwd_product;

-- -------------------------------------------------------------
-- 4. 重复值处理验收：dwd_order
--    合格标准：remain_dup = 0
-- -------------------------------------------------------------
SELECT
  COUNT(*)                            AS total_rows,
  COUNT(DISTINCT order_id)            AS distinct_order_id,
  COUNT(*) - COUNT(DISTINCT order_id) AS remain_dup
FROM ydsh_dwd.dwd_order;

-- -------------------------------------------------------------
-- 5. 枚举标准化验收：dwd_user.gender / member_level
--    合格标准：只应出现 男/女/未知 与 金卡/银卡/钻石/普通/未知
-- -------------------------------------------------------------
SELECT gender, COUNT(*) AS cnt FROM ydsh_dwd.dwd_user GROUP BY gender ORDER BY cnt DESC;
SELECT member_level, COUNT(*) AS cnt FROM ydsh_dwd.dwd_user GROUP BY member_level ORDER BY cnt DESC;

-- -------------------------------------------------------------
-- 6. 数据质量评估汇总（答辩展示用）
-- -------------------------------------------------------------
SELECT * FROM ydsh_dwd.dq_report ORDER BY bad_ratio DESC, table_name;

-- ############################################################################
-- ## [09/21] sql/clean/20_enum_standardize.sql   （345 行）
-- ############################################################################

-- =============================================================
-- 20_enum_standardize.sql
-- 作用：数据清洗（二）· 子任务 1 —— 枚举字段标准化
-- 输入：ydsh_ods.ods_*（贴源层，字符串全部为原始形态）
-- 输出：ydsh_dwd.dwd_*_clean（清洗中间表，供 21 / 22 号脚本继续加工）
--
-- 覆盖的脏值形态（均来自真实扫描，见文末「取值收敛验证」）：
--   gender        男 / 女 / M / F / male / female / 未知 / 空        8 种
--   member_level  金卡会员 / 金卡 / gold / 银卡 / silver / 钻石 / 普通 / 空  12 种
--   order_status  已完成 / 完成 / 已支付 / 已付款 / 1 / 2 / 3 / 4 / cancelled  12 种
--   pay_type      微信支付 / 微信 / wechat / 支付宝 / alipay / 银行卡 / 货到付款  7 种
--   channel       门店 / APP / app / 小程序 / PC官网 / pc            6 种
--   behavior_type pv / PV / 浏览 / cart / Cart / 加购 / fav / 收藏 / buy / 购买  10 种
--   category      8 个规范类目 + 7 个带尾随空格的变体（共 16 种）
--
-- 设计原则：
--   1) 枚举一律收敛到「中文标准值」，英文/编码/大小写/空白变体全部映射进去；
--   2) 映射用显式白名单（IN 列表），未命中走 ELSE 兜底 —— 白名单能保证
--      新增脏值不会静默穿透，兜底值在验证段落能被单独统计出来；
--   3) 本脚本同时承接第 1 周的基础清洗（年龄中位数、订单去重），
--      保证从 ODS 一键重算即可复现全流程。
--
-- 执行：bash scripts/run_sql.sh sql/clean/20_enum_standardize.sql
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_dwd;

-- =============================================================
-- 一、dwd_user_clean —— 用户表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_user_clean;
CREATE TABLE ydsh_dwd.dwd_user_clean
COMMENT 'DWD 清洗中间表-用户（枚举标准化 + 年龄中位数填充）'
STORED AS ORC
AS
SELECT
  TRIM(u.user_id)   AS user_id,
  TRIM(u.user_name) AS user_name,

  -- 性别：8 种取值 → 男 / 女 / 未知
  CASE
    WHEN LOWER(TRIM(u.gender)) IN ('男','m','male','1')    THEN '男'
    WHEN LOWER(TRIM(u.gender)) IN ('女','f','female','0')  THEN '女'
    WHEN LOWER(TRIM(u.gender)) IN ('未知','unknown','')    THEN '未知'
    ELSE '未知'
  END AS gender,

  -- 年龄：空 / 非数字 / 越界 [1,120] → 中位数填充
  CAST(
    CASE
      WHEN u.age IS NULL OR TRIM(u.age) = '' OR TRIM(u.age) NOT RLIKE '^-?[0-9]+$' THEN s.med_age
      WHEN CAST(TRIM(u.age) AS INT) < 1 OR CAST(TRIM(u.age) AS INT) > 120          THEN s.med_age
      ELSE CAST(TRIM(u.age) AS INT)
    END AS INT
  ) AS age,

  TRIM(u.city)     AS city,
  TRIM(u.province) AS province,

  -- 注册日期：三种形态 → yyyy-MM-dd
  CASE
    WHEN TRIM(u.register_date) RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN TRIM(u.register_date)
    WHEN TRIM(u.register_date) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN REGEXP_REPLACE(TRIM(u.register_date), '/', '-')
    WHEN TRIM(u.register_date) RLIKE '^[0-9]{8}$'
      THEN CONCAT(SUBSTR(TRIM(u.register_date),1,4), '-', SUBSTR(TRIM(u.register_date),5,2), '-', SUBSTR(TRIM(u.register_date),7,2))
    ELSE NULL
  END AS register_date,

  -- 会员等级：12 种取值 → 普通会员 / 银卡会员 / 金卡会员 / 钻石会员
  -- 空值不臆造等级，按最低等级「普通会员」兜底，并在 member_level_flag 标记
  CASE
    WHEN LOWER(TRIM(u.member_level)) IN ('普通','普通会员','normal','regular')      THEN '普通会员'
    WHEN LOWER(TRIM(u.member_level)) IN ('银卡','银卡会员','silver')                THEN '银卡会员'
    WHEN LOWER(TRIM(u.member_level)) IN ('金卡','金卡会员','gold')                  THEN '金卡会员'
    WHEN LOWER(TRIM(u.member_level)) IN ('钻石','钻石会员','diamond','platinum')    THEN '钻石会员'
    ELSE '普通会员'
  END AS member_level,

  CASE
    WHEN TRIM(u.member_level) = '' THEN '缺失兜底'
    WHEN LOWER(TRIM(u.member_level)) IN ('普通','普通会员','normal','regular',
                                         '银卡','银卡会员','silver',
                                         '金卡','金卡会员','gold',
                                         '钻石','钻石会员','diamond','platinum') THEN '正常'
    ELSE '未识别'
  END AS member_level_flag,

  -- 手机号：去除 - 与空格，统一 11 位纯数字
  REGEXP_REPLACE(TRIM(u.phone), '[^0-9]', '') AS phone,

  TRIM(u.email) AS email,
  CASE WHEN TRIM(u.email) = '' THEN '缺失' ELSE '正常' END AS email_flag

FROM ydsh_ods.ods_user u
CROSS JOIN (
  -- 中位数只在合法区间内统计，避免 150 / 0 这类异常值参与计算
  SELECT ROUND(PERCENTILE(CAST(TRIM(age) AS INT), 0.5)) AS med_age
  FROM ydsh_ods.ods_user
  WHERE TRIM(age) RLIKE '^[0-9]+$' AND CAST(TRIM(age) AS INT) BETWEEN 1 AND 120
) s;

-- =============================================================
-- 二、dwd_product_clean —— 商品表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_product_clean;
CREATE TABLE ydsh_dwd.dwd_product_clean
COMMENT 'DWD 清洗中间表-商品（类目/品牌去空格、上架日期补全）'
STORED AS ORC
AS
SELECT
  TRIM(p.product_id)   AS product_id,
  TRIM(p.product_name) AS product_name,

  -- 类目：8 个规范值 + 7 个带尾随空格的变体 → 8 个规范值
  TRIM(p.category)     AS category,
  TRIM(p.sub_category) AS sub_category,

  -- 品牌：中英文混排，统一去空格；英文品牌统一大写便于比对
  CASE WHEN TRIM(p.brand) RLIKE '[A-Za-z]' THEN UPPER(TRIM(p.brand)) ELSE TRIM(p.brand) END AS brand,

  CAST(TRIM(p.price) AS DOUBLE) AS price,
  CAST(TRIM(p.cost)  AS DOUBLE) AS cost,
  CAST(TRIM(p.stock) AS INT)    AS stock,
  TRIM(p.status)                AS status,

  -- 上架日期：缺失按同品类最早上架日期补全，品类内也无值则兜底 2023-01-01
  CASE
    WHEN TRIM(p.launch_date) = '' THEN COALESCE(c.min_launch, '2023-01-01')
    WHEN TRIM(p.launch_date) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN REGEXP_REPLACE(TRIM(p.launch_date), '/', '-')
    WHEN TRIM(p.launch_date) RLIKE '^[0-9]{8}$'
      THEN CONCAT(SUBSTR(TRIM(p.launch_date),1,4), '-', SUBSTR(TRIM(p.launch_date),5,2), '-', SUBSTR(TRIM(p.launch_date),7,2))
    ELSE TRIM(p.launch_date)
  END AS launch_date

FROM ydsh_ods.ods_product p
LEFT JOIN (
  SELECT TRIM(category) AS category, MIN(TRIM(launch_date)) AS min_launch
  FROM ydsh_ods.ods_product
  WHERE TRIM(launch_date) RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  GROUP BY TRIM(category)
) c
  ON TRIM(p.category) = c.category;

-- =============================================================
-- 三、dwd_store_clean —— 门店表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_store_clean;
CREATE TABLE ydsh_dwd.dwd_store_clean
COMMENT 'DWD 清洗中间表-门店（第 1 周评估五维度全 0，仅做规范化落地）'
STORED AS ORC
AS
SELECT
  TRIM(store_id)   AS store_id,
  TRIM(store_name) AS store_name,
  TRIM(province)   AS province,
  TRIM(city)       AS city,
  TRIM(district)   AS district,
  TRIM(address)    AS address,
  CASE
    WHEN TRIM(open_date) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN REGEXP_REPLACE(TRIM(open_date), '/', '-')
    WHEN TRIM(open_date) RLIKE '^[0-9]{8}$'
      THEN CONCAT(SUBSTR(TRIM(open_date),1,4), '-', SUBSTR(TRIM(open_date),5,2), '-', SUBSTR(TRIM(open_date),7,2))
    ELSE TRIM(open_date)
  END AS open_date,
  CAST(TRIM(area) AS DOUBLE) AS area,
  TRIM(manager) AS manager
FROM ydsh_ods.ods_store;

-- =============================================================
-- 四、dwd_order_clean —— 订单表（含第 1 周的整行去重）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_order_clean;
CREATE TABLE ydsh_dwd.dwd_order_clean
COMMENT 'DWD 清洗中间表-订单（去重 + 枚举标准化）'
STORED AS ORC
AS
SELECT
  order_id, user_id, store_id, order_date, order_time,
  pay_amount, discount_amount,
  pay_type, order_status, channel
FROM (
  SELECT
    TRIM(o.order_id)   AS order_id,
    TRIM(o.user_id)    AS user_id,
    TRIM(o.store_id)   AS store_id,

    CASE
      WHEN TRIM(o.order_date) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN REGEXP_REPLACE(TRIM(o.order_date), '/', '-')
      WHEN TRIM(o.order_date) RLIKE '^[0-9]{8}$'
        THEN CONCAT(SUBSTR(TRIM(o.order_date),1,4), '-', SUBSTR(TRIM(o.order_date),5,2), '-', SUBSTR(TRIM(o.order_date),7,2))
      ELSE TRIM(o.order_date)
    END AS order_date,

    TRIM(o.order_time) AS order_time,

    CAST(TRIM(o.pay_amount)      AS DOUBLE) AS pay_amount,
    CAST(TRIM(o.discount_amount) AS DOUBLE) AS discount_amount,

    -- 支付方式：7 种 → 微信支付 / 支付宝 / 银行卡 / 货到付款
    CASE
      WHEN LOWER(TRIM(o.pay_type)) IN ('微信支付','微信','wechat','weixin','wx') THEN '微信支付'
      WHEN LOWER(TRIM(o.pay_type)) IN ('支付宝','alipay','ali')                  THEN '支付宝'
      WHEN LOWER(TRIM(o.pay_type)) IN ('银行卡','bank','bankcard','card','unionpay') THEN '银行卡'
      WHEN LOWER(TRIM(o.pay_type)) IN ('货到付款','cod','cash')                  THEN '货到付款'
      ELSE '其他'
    END AS pay_type,

    -- 订单状态：12 种 → 待支付 / 已支付 / 已完成 / 已取消 / 退款中
    -- 数字编码按状态流转顺序对应：1=已支付 2=待支付 3=已取消 4=退款中
    CASE
      WHEN LOWER(TRIM(o.order_status)) IN ('待支付','2')                      THEN '待支付'
      WHEN LOWER(TRIM(o.order_status)) IN ('已支付','已付款','1')              THEN '已支付'
      WHEN LOWER(TRIM(o.order_status)) IN ('已完成','完成','5','finished')     THEN '已完成'
      WHEN LOWER(TRIM(o.order_status)) IN ('已取消','cancelled','canceled','3') THEN '已取消'
      WHEN LOWER(TRIM(o.order_status)) IN ('退款中','refunding','4')           THEN '退款中'
      ELSE '未知'
    END AS order_status,

    -- 渠道：6 种 → 门店 / APP / 小程序 / PC官网
    CASE
      WHEN LOWER(TRIM(o.channel)) IN ('门店','store','offline')   THEN '门店'
      WHEN LOWER(TRIM(o.channel)) IN ('app')                      THEN 'APP'
      WHEN LOWER(TRIM(o.channel)) IN ('小程序','miniapp','mini')  THEN '小程序'
      WHEN LOWER(TRIM(o.channel)) IN ('pc官网','pc','官网','web')  THEN 'PC官网'
      ELSE '其他'
    END AS channel,

    ROW_NUMBER() OVER (
      PARTITION BY TRIM(o.order_id)
      ORDER BY TRIM(o.order_date) DESC, TRIM(o.order_time) DESC
    ) AS rn
  FROM ydsh_ods.ods_order o
) t
WHERE rn = 1;

-- =============================================================
-- 五、dwd_order_item_clean —— 订单明细表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_order_item_clean;
CREATE TABLE ydsh_dwd.dwd_order_item_clean
COMMENT 'DWD 清洗中间表-订单明细'
STORED AS ORC
AS
SELECT
  TRIM(item_id)    AS item_id,
  TRIM(order_id)   AS order_id,
  TRIM(product_id) AS product_id,
  CAST(TRIM(quantity)   AS INT)    AS quantity,
  CAST(TRIM(unit_price) AS DOUBLE) AS unit_price,
  CAST(TRIM(discount)   AS DOUBLE) AS discount
FROM ydsh_ods.ods_order_item;

-- =============================================================
-- 六、dwd_user_behavior_clean —— 用户行为表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_user_behavior_clean;
CREATE TABLE ydsh_dwd.dwd_user_behavior_clean
COMMENT 'DWD 清洗中间表-用户行为（行为类型中英文归并 + 时间格式统一）'
STORED AS ORC
AS
SELECT
  TRIM(behavior_id) AS behavior_id,
  TRIM(user_id)     AS user_id,
  TRIM(product_id)  AS product_id,

  -- 行为类型：10 种 → 浏览 / 加购 / 收藏 / 购买
  CASE
    WHEN LOWER(TRIM(b.behavior_type)) IN ('pv','浏览','view','page_view') THEN '浏览'
    WHEN LOWER(TRIM(b.behavior_type)) IN ('cart','加购','add_cart','addcart') THEN '加购'
    WHEN LOWER(TRIM(b.behavior_type)) IN ('fav','收藏','favorite','collect')  THEN '收藏'
    WHEN LOWER(TRIM(b.behavior_type)) IN ('buy','购买','purchase','order')    THEN '购买'
    ELSE '其他'
  END AS behavior_type,

  -- 行为时间统一为 yyyy-MM-dd HH:mm:ss
  -- 实际存在两种脏形态：2024/11/05 15:49（斜杠且缺秒）、2024-12-06 09:16:24（已规范）
  CASE
    -- ① 斜杠 + 无秒 → 换分隔符并补 :00
    WHEN TRIM(b.behavior_time) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}$'
      THEN CONCAT(REGEXP_REPLACE(SUBSTR(TRIM(b.behavior_time),1,10), '/', '-'),
                  ' ', SUBSTR(TRIM(b.behavior_time),12), ':00')
    -- ② 斜杠 + 有秒 → 只换分隔符
    WHEN TRIM(b.behavior_time) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
      THEN REGEXP_REPLACE(TRIM(b.behavior_time), '/', '-')
    -- ③ 横杠 + 无秒 → 补 :00
    WHEN TRIM(b.behavior_time) RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$'
      THEN CONCAT(TRIM(b.behavior_time), ':00')
    ELSE TRIM(b.behavior_time)
  END AS behavior_time,

  TRIM(b.session_id) AS session_id
FROM ydsh_ods.ods_user_behavior b;

-- =============================================================
-- 七、取值收敛验证（答辩演示用：清洗前后 distinct 数量对比）
-- =============================================================
SELECT 'gender' AS field,
       COUNT(DISTINCT TRIM(gender)) AS ods_distinct,
       (SELECT COUNT(DISTINCT gender) FROM ydsh_dwd.dwd_user_clean) AS dwd_distinct,
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean) AS dwd_rows
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'member_level',
       COUNT(DISTINCT TRIM(member_level)),
       (SELECT COUNT(DISTINCT member_level) FROM ydsh_dwd.dwd_user_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean)
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'order_status',
       COUNT(DISTINCT TRIM(order_status)),
       (SELECT COUNT(DISTINCT order_status) FROM ydsh_dwd.dwd_order_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'pay_type',
       COUNT(DISTINCT TRIM(pay_type)),
       (SELECT COUNT(DISTINCT pay_type) FROM ydsh_dwd.dwd_order_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'channel',
       COUNT(DISTINCT TRIM(channel)),
       (SELECT COUNT(DISTINCT channel) FROM ydsh_dwd.dwd_order_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'behavior_type',
       COUNT(DISTINCT TRIM(behavior_type)),
       (SELECT COUNT(DISTINCT behavior_type) FROM ydsh_dwd.dwd_user_behavior_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean)
FROM ydsh_ods.ods_user_behavior
UNION ALL
SELECT 'category',
       COUNT(DISTINCT category),
       (SELECT COUNT(DISTINCT category) FROM ydsh_dwd.dwd_product_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean)
FROM ydsh_ods.ods_product;

-- 各表行数（去重是否生效）
SELECT 'dwd_user_clean' AS tbl, COUNT(*) AS cnt FROM ydsh_dwd.dwd_user_clean
UNION ALL SELECT 'dwd_product_clean',     COUNT(*) FROM ydsh_dwd.dwd_product_clean
UNION ALL SELECT 'dwd_store_clean',       COUNT(*) FROM ydsh_dwd.dwd_store_clean
UNION ALL SELECT 'dwd_order_clean',       COUNT(*) FROM ydsh_dwd.dwd_order_clean
UNION ALL SELECT 'dwd_order_item_clean',  COUNT(*) FROM ydsh_dwd.dwd_order_item_clean
UNION ALL SELECT 'dwd_user_behavior_clean', COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean;

-- ############################################################################
-- ## [10/21] sql/clean/21_abnormal_format.sql   （172 行）
-- ############################################################################

-- =============================================================
-- 21_abnormal_format.sql
-- 作用：数据清洗（二）· 子任务 2 —— 异常值处理 + 格式标准化
-- 输入 / 输出：ydsh_dwd.dwd_*_clean（原地更新，采用「暂存表 → 换名」的方式）
--
-- 为什么用「暂存表 → 换名」而不是 INSERT OVERWRITE：
--   本脚本需要新增标记列（phone_flag 等），INSERT OVERWRITE 要求列结构完全一致，
--   而 CTAS 建暂存表 + ALTER TABLE RENAME 可以一次完成「改结构 + 改数据」。
--
-- 处理策略一览：
--   ① 订单金额   pay_amount <= 0         → 删除该订单（金额无业务解释空间）
--   ② 订单金额   pay_amount > IQR 上界    → 删除（异常离群，见下方阈值说明）
--   ③ 明细数量   quantity <= 0           → 删除该明细行（0 件/负件不成立）
--   ④ 商品价格   price <= 0 或 cost > price → 按成本价 × 1.2 修正，无成本价则删除
--   ⑤ 手机号     非 11 位数字             → 置空并标记，不臆造号码
--   ⑥ 日期/时间  无法解析                 → 置空（避免下游按字符串比较时错乱）
--
-- 关于「多大算超大金额」：
--   直接取 P99 会被离群值本身带偏（本批数据的 P99 = 563 万，明显不合理，
--   因为约 2% 的记录被注入了百万级金额）。改用对离群值稳健的 IQR 上界：
--       上界 = Q3 + 3 × (Q3 - Q1)
--   3 倍 IQR 是箱线图的「极端离群」判定线，比绝对阈值更有数据依据，
--   同时避免把正常的高客单价订单误删。
--
-- 执行：bash scripts/run_sql.sh sql/clean/21_abnormal_format.sql
-- =============================================================

-- =============================================================
-- 一、dwd_order_clean —— 金额异常处理（会减少行数）
-- =============================================================
-- 先算出一个稳健的金额上界，供后续两个语句复用
DROP TABLE IF EXISTS ydsh_dwd.stg_amount_threshold;
CREATE TABLE ydsh_dwd.stg_amount_threshold STORED AS ORC AS
SELECT ROUND(p75 + 3 * (p75 - p25), 2) AS upper_bound,
       ROUND(p25, 2) AS q1, ROUND(p75, 2) AS q3
FROM (
  -- 阈值从贴源层计算而非从 dwd_order_clean 计算：
  -- 后者已被本脚本过滤过，重复执行会不断收窄阈值，导致结果不可复现
  SELECT PERCENTILE_APPROX(CAST(TRIM(pay_amount) AS DOUBLE), CAST(0.25 AS DOUBLE)) AS p25,
         PERCENTILE_APPROX(CAST(TRIM(pay_amount) AS DOUBLE), CAST(0.75 AS DOUBLE)) AS p75
  FROM ydsh_ods.ods_order
  -- 非数字字符串 CAST 后为 NULL，会被 > 0 条件自然过滤，无需额外正则
  WHERE CAST(TRIM(pay_amount) AS DOUBLE) > 0
) t;

SELECT CONCAT('金额 IQR 上界 = ', CAST(upper_bound AS STRING),
              ' 元（Q1=', CAST(q1 AS STRING), '，Q3=', CAST(q3 AS STRING), '）') AS threshold_info
FROM ydsh_dwd.stg_amount_threshold;

DROP TABLE IF EXISTS ydsh_dwd.stg_order;
CREATE TABLE ydsh_dwd.stg_order STORED AS ORC AS
SELECT o.*
FROM ydsh_dwd.dwd_order_clean o
CROSS JOIN ydsh_dwd.stg_amount_threshold t
WHERE o.pay_amount IS NOT NULL
  AND o.pay_amount > 0
  AND o.pay_amount <= t.upper_bound;

DROP TABLE ydsh_dwd.dwd_order_clean;
ALTER TABLE ydsh_dwd.stg_order RENAME TO ydsh_dwd.dwd_order_clean;

-- =============================================================
-- 二、dwd_order_item_clean —— 数量异常处理
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_order_item;
CREATE TABLE ydsh_dwd.stg_order_item STORED AS ORC AS
SELECT i.*
FROM ydsh_dwd.dwd_order_item_clean i
-- 只保留挂在有效订单下的明细，顺带保证事实表与明细表的引用完整性
WHERE i.quantity IS NOT NULL
  AND i.quantity BETWEEN 1 AND 100
  AND i.unit_price > 0
  AND i.discount BETWEEN 0 AND 1
  AND i.order_id IN (SELECT order_id FROM ydsh_dwd.dwd_order_clean);

DROP TABLE ydsh_dwd.dwd_order_item_clean;
ALTER TABLE ydsh_dwd.stg_order_item RENAME TO ydsh_dwd.dwd_order_item_clean;

-- =============================================================
-- 三、dwd_product_clean —— 价格异常修正
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_product;
CREATE TABLE ydsh_dwd.stg_product STORED AS ORC AS
SELECT
  p.product_id, p.product_name, p.category, p.sub_category, p.brand,

  -- 价格 <= 0，或成本高于售价（违反「成本 < 售价」的业务常识）→ 按成本 × 1.2 修正
  CASE
    WHEN (p.price IS NULL OR p.price <= 0 OR p.cost > p.price) AND p.cost > 0
      THEN ROUND(p.cost * 1.2, 2)
    ELSE p.price
  END AS price,

  p.cost, p.stock, p.status, p.launch_date,

  -- 修正标记，供质量报告统计
  CASE
    WHEN p.price IS NULL OR p.price <= 0 THEN '价格缺失或非正-已修正'
    WHEN p.cost > p.price                THEN '成本高于售价-已修正'
    ELSE '正常'
  END AS price_flag

FROM ydsh_dwd.dwd_product_clean p
WHERE p.cost > 0;   -- 无有效成本价的商品无法修正，剔除

DROP TABLE ydsh_dwd.dwd_product_clean;
ALTER TABLE ydsh_dwd.stg_product RENAME TO ydsh_dwd.dwd_product_clean;

-- =============================================================
-- 四、dwd_user_clean —— 手机号与日期格式复核
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_user;
CREATE TABLE ydsh_dwd.stg_user STORED AS ORC AS
SELECT
  user_id, user_name, gender, age, city, province, register_date, member_level, member_level_flag,

  -- 中国大陆手机号必须为 1 开头、共 11 位；不合规置空，不补位不猜测
  CASE WHEN u.phone RLIKE '^1[3-9][0-9]{9}$' THEN u.phone ELSE NULL END AS phone,
  CASE WHEN u.phone RLIKE '^1[3-9][0-9]{9}$' THEN '正常' ELSE '格式异常' END AS phone_flag,

  u.email, u.email_flag
FROM ydsh_dwd.dwd_user_clean u;

DROP TABLE ydsh_dwd.dwd_user_clean;
ALTER TABLE ydsh_dwd.stg_user RENAME TO ydsh_dwd.dwd_user_clean;

-- =============================================================
-- 五、dwd_user_behavior_clean —— 行为时间格式复核
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_behavior;
CREATE TABLE ydsh_dwd.stg_behavior STORED AS ORC AS
SELECT
  behavior_id, user_id, product_id, behavior_type,
  CASE WHEN behavior_time RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
       THEN behavior_time ELSE NULL END AS behavior_time,
  CASE WHEN behavior_time RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
       THEN '正常' ELSE '格式异常' END AS behavior_time_flag,
  session_id
FROM ydsh_dwd.dwd_user_behavior_clean;

DROP TABLE ydsh_dwd.dwd_user_behavior_clean;
ALTER TABLE ydsh_dwd.stg_behavior RENAME TO ydsh_dwd.dwd_user_behavior_clean;

-- 阈值表用完即删，避免污染数仓目录
DROP TABLE IF EXISTS ydsh_dwd.stg_amount_threshold;

-- =============================================================
-- 六、清洗效果复核
-- =============================================================
SELECT '订单：金额异常' AS item,
       COUNT(*) AS remain_bad,
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean) AS total
FROM ydsh_dwd.dwd_order_clean WHERE pay_amount <= 0
UNION ALL
SELECT '明细：数量异常', COUNT(*), (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_item_clean)
FROM ydsh_dwd.dwd_order_item_clean WHERE quantity <= 0
UNION ALL
SELECT '商品：价格异常', COUNT(*), (SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean)
FROM ydsh_dwd.dwd_product_clean WHERE price <= 0 OR cost > price
UNION ALL
SELECT '用户：手机号异常', COUNT(*), (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean)
FROM ydsh_dwd.dwd_user_clean WHERE phone_flag = '格式异常'
UNION ALL
SELECT '行为：时间异常', COUNT(*), (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean)
FROM ydsh_dwd.dwd_user_behavior_clean WHERE behavior_time_flag = '格式异常';

SELECT 'dwd_user_clean' AS tbl, COUNT(*) AS cnt FROM ydsh_dwd.dwd_user_clean
UNION ALL SELECT 'dwd_product_clean',        COUNT(*) FROM ydsh_dwd.dwd_product_clean
UNION ALL SELECT 'dwd_store_clean',          COUNT(*) FROM ydsh_dwd.dwd_store_clean
UNION ALL SELECT 'dwd_order_clean',          COUNT(*) FROM ydsh_dwd.dwd_order_clean
UNION ALL SELECT 'dwd_order_item_clean',     COUNT(*) FROM ydsh_dwd.dwd_order_item_clean
UNION ALL SELECT 'dwd_user_behavior_clean',  COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean;

-- ############################################################################
-- ## [11/21] sql/clean/22_split_merge_map.sql   （202 行）
-- ############################################################################

-- =============================================================
-- 22_split_merge_map.sql
-- 作用：数据清洗（二）· 子任务 3 —— 字段拆分合并 + 编码映射
-- 输入 / 输出：ydsh_dwd.dwd_*_clean（原地更新）
--
-- 做三件事：
--   ① 合并：order_date + order_time → order_timestamp（yyyy-MM-dd HH:mm:ss）
--   ② 合并：province + city → region（省-市，直辖市去重）
--   ③ 编码：为会员等级 / 支付方式 / 订单状态 / 渠道 / 行为类型建立码表，
--      DWD 层只存「编码」，展示层 JOIN 码表取中文名 —— 这是维度建模的标准做法，
--      好处是中文名变更时只改码表一行，不用扫全表更新。
--
-- 执行：bash scripts/run_sql.sh sql/clean/22_split_merge_map.sql
-- =============================================================

-- =============================================================
-- 一、编码映射表（码表 / 小型维度表）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_member_level;
CREATE TABLE ydsh_dwd.dim_member_level (
  member_code STRING COMMENT '会员等级编码',
  member_name STRING COMMENT '会员等级名称',
  sort_no     INT    COMMENT '等级排序（1 最低）'
) COMMENT '码表-会员等级' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_member_level VALUES
  ('ML01', '普通会员', 1),
  ('ML02', '银卡会员', 2),
  ('ML03', '金卡会员', 3),
  ('ML04', '钻石会员', 4);

DROP TABLE IF EXISTS ydsh_dwd.dim_pay_type;
CREATE TABLE ydsh_dwd.dim_pay_type (
  pay_code STRING COMMENT '支付方式编码',
  pay_name STRING COMMENT '支付方式名称'
) COMMENT '码表-支付方式' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_pay_type VALUES
  ('PT01', '微信支付'),
  ('PT02', '支付宝'),
  ('PT03', '银行卡'),
  ('PT04', '货到付款'),
  ('PT99', '其他');

DROP TABLE IF EXISTS ydsh_dwd.dim_order_status;
CREATE TABLE ydsh_dwd.dim_order_status (
  status_code STRING COMMENT '订单状态编码',
  status_name STRING COMMENT '订单状态名称',
  is_finished INT    COMMENT '是否终态（1 是 0 否）'
) COMMENT '码表-订单状态' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_order_status VALUES
  ('OS01', '待支付', 0),
  ('OS02', '已支付', 0),
  ('OS03', '已完成', 1),
  ('OS04', '已取消', 1),
  ('OS05', '退款中', 0),
  ('OS99', '未知',   0);

DROP TABLE IF EXISTS ydsh_dwd.dim_channel;
CREATE TABLE ydsh_dwd.dim_channel (
  channel_code STRING COMMENT '渠道编码',
  channel_name STRING COMMENT '渠道名称'
) COMMENT '码表-下单渠道' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_channel VALUES
  ('CH01', '门店'),
  ('CH02', 'APP'),
  ('CH03', '小程序'),
  ('CH04', 'PC官网'),
  ('CH99', '其他');

DROP TABLE IF EXISTS ydsh_dwd.dim_behavior_type;
CREATE TABLE ydsh_dwd.dim_behavior_type (
  behavior_code STRING COMMENT '行为类型编码',
  behavior_name STRING COMMENT '行为类型名称'
) COMMENT '码表-用户行为类型' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_behavior_type VALUES
  ('BT01', '浏览'),
  ('BT02', '加购'),
  ('BT03', '收藏'),
  ('BT04', '购买'),
  ('BT99', '其他');

-- =============================================================
-- 二、dwd_order_clean —— 合并时间戳 + 打上编码
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_order;
CREATE TABLE ydsh_dwd.stg_order STORED AS ORC AS
SELECT
  o.order_id,
  o.user_id,
  o.store_id,
  o.order_date,

  -- 拆出来的时间部分保留原字段，便于回溯
  o.order_time,

  -- ① 合并成完整时间戳，为时间维度建模与窗口函数排序做准备
  CONCAT(o.order_date, ' ', o.order_time) AS order_timestamp,

  o.pay_amount,
  o.discount_amount,

  COALESCE(p.pay_code, 'PT99')         AS pay_type_code,
  o.pay_type                           AS pay_type_name,   -- 保留中文名，方便直接查数

  COALESCE(s.status_code, 'OS99')      AS order_status_code,
  o.order_status                       AS order_status_name,

  COALESCE(c.channel_code, 'CH99')     AS channel_code,
  o.channel                            AS channel_name

FROM ydsh_dwd.dwd_order_clean o
LEFT JOIN ydsh_dwd.dim_pay_type     p ON o.pay_type     = p.pay_name
LEFT JOIN ydsh_dwd.dim_order_status s ON o.order_status = s.status_name
LEFT JOIN ydsh_dwd.dim_channel      c ON o.channel      = c.channel_name;

DROP TABLE ydsh_dwd.dwd_order_clean;
ALTER TABLE ydsh_dwd.stg_order RENAME TO ydsh_dwd.dwd_order_clean;

-- =============================================================
-- 三、dwd_user_clean —— 省 + 市 合并为 region，打上会员等级编码
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_user;
CREATE TABLE ydsh_dwd.stg_user STORED AS ORC AS
SELECT
  u.user_id,
  u.user_name,
  u.gender,
  u.age,
  u.city,
  u.province,

  -- ② 省 + 市 合并为大区字段：直辖市（省=市）只保留一个，避免「重庆-重庆」
  CASE
    -- 直辖市/省直管市：province 形如「重庆市」而 city 为「重庆」，用前缀匹配去重
    WHEN u.province = u.city OR u.province LIKE CONCAT(u.city, '%') THEN u.province
    WHEN u.province IS NULL OR u.province = '' THEN u.city
    WHEN u.city IS NULL OR u.city = '' THEN u.province
    ELSE CONCAT(u.province, '-', u.city)
  END AS region,

  u.register_date,

  COALESCE(m.member_code, 'ML01') AS member_level_code,
  u.member_level                  AS member_level_name,
  u.member_level_flag,

  u.phone, u.phone_flag, u.email, u.email_flag

FROM ydsh_dwd.dwd_user_clean u
LEFT JOIN ydsh_dwd.dim_member_level m ON u.member_level = m.member_name;

DROP TABLE ydsh_dwd.dwd_user_clean;
ALTER TABLE ydsh_dwd.stg_user RENAME TO ydsh_dwd.dwd_user_clean;

-- =============================================================
-- 四、dwd_user_behavior_clean —— 打上行为类型编码
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_behavior;
CREATE TABLE ydsh_dwd.stg_behavior STORED AS ORC AS
SELECT
  b.behavior_id, b.user_id, b.product_id,
  COALESCE(t.behavior_code, 'BT99') AS behavior_type_code,
  b.behavior_type                   AS behavior_type_name,
  b.behavior_time,
  -- 从时间戳拆出日期与小时，供后续时段分析使用
  SUBSTR(b.behavior_time, 1, 10)    AS behavior_date,
  SUBSTR(b.behavior_time, 12, 2)    AS behavior_hour,
  b.session_id
FROM ydsh_dwd.dwd_user_behavior_clean b
LEFT JOIN ydsh_dwd.dim_behavior_type t ON b.behavior_type = t.behavior_name;

DROP TABLE ydsh_dwd.dwd_user_behavior_clean;
ALTER TABLE ydsh_dwd.stg_behavior RENAME TO ydsh_dwd.dwd_user_behavior_clean;

-- =============================================================
-- 五、验证
-- =============================================================
-- ① 时间戳格式是否全部合规
SELECT 'order_timestamp 格式合规' AS item,
       SUM(CASE WHEN order_timestamp RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN 1 ELSE 0 END) AS ok_cnt,
       COUNT(*) AS total
FROM ydsh_dwd.dwd_order_clean;

-- ② 编码是否有未命中（应为 0）
SELECT 'order 编码未命中' AS item, COUNT(*) AS unmapped
FROM ydsh_dwd.dwd_order_clean
WHERE pay_type_code = 'PT99' OR order_status_code = 'OS99' OR channel_code = 'CH99'
UNION ALL
SELECT 'user 编码未命中', COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE member_level_code = 'ML01' AND member_level_flag = '未识别'
UNION ALL
SELECT 'behavior 编码未命中', COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean WHERE behavior_type_code = 'BT99';

-- ③ region 抽样
SELECT region, COUNT(*) AS user_cnt
FROM ydsh_dwd.dwd_user_clean
GROUP BY region
ORDER BY user_cnt DESC
LIMIT 10;

-- ############################################################################
-- ## [12/21] sql/clean/23_quality_compare.sql   （207 行）
-- ############################################################################

-- =============================================================
-- 23_quality_compare.sql
-- 作用：子任务 4 —— 清洗前后数据质量对比（五类脏数据修复率）
-- 输入：ydsh_ods.*（清洗前） / ydsh_dwd.dwd_*_clean（清洗后）
-- 输出：ydsh_dwd.dq_compare（供《数据质量清洗报告》取数）
--
-- 统计口径（与任务书一致）：
--   修复率 = (清洗前问题数 - 清洗后问题数) / 清洗前问题数
--   清洗前 = 贴源层 ODS 原始值；清洗后 = 22 号脚本产出的清洗完成态
--
-- 类目划分沿用第一周五维度的前四类（缺失/重复/异常/格式），
-- 「枚举不规范」在本州并入「格式/取值规范」，单列是为了让修复率更直观。
--
-- 执行：bash scripts/run_sql.sh sql/clean/23_quality_compare.sql
-- =============================================================

DROP TABLE IF EXISTS ydsh_dwd.dq_compare;
CREATE TABLE ydsh_dwd.dq_compare (
  category    STRING COMMENT '问题类别',
  item        STRING COMMENT '检查项',
  before_cnt  BIGINT COMMENT '清洗前问题数',
  after_cnt   BIGINT COMMENT '清洗后问题数',
  fixed_cnt   BIGINT COMMENT '修复数',
  fix_rate    DOUBLE COMMENT '修复率（%）',
  strategy    STRING COMMENT '处理策略'
) COMMENT '数据质量清洗前后对比' STORED AS ORC;

INSERT OVERWRITE TABLE ydsh_dwd.dq_compare
SELECT category, item, before_cnt, after_cnt,
       before_cnt - after_cnt AS fixed_cnt,
       CASE WHEN before_cnt = 0 THEN NULL
            ELSE ROUND(100.0 * (before_cnt - after_cnt) / before_cnt, 2) END AS fix_rate,
       strategy
FROM (
  -- ============ 一、枚举不规范 ============
  SELECT '枚举不规范' AS category, 'user.gender 非规范取值' AS item,
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(gender) <> '' AND LOWER(TRIM(gender)) NOT IN ('男','女','未知')) AS before_cnt,
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean
      WHERE LOWER(TRIM(gender)) NOT IN ('男','女','未知')) AS after_cnt,
    'M/F/male/female 映射为 男/女，空值归入 未知' AS strategy
  UNION ALL
  SELECT '枚举不规范', 'user.member_level 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(member_level) <> ''
        AND LOWER(TRIM(member_level)) NOT IN ('普通会员','银卡会员','金卡会员','钻石会员')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean
      WHERE LOWER(TRIM(member_level_name)) NOT IN ('普通会员','银卡会员','金卡会员','钻石会员')),
    'gold/silver/短名称统一为四档全称'
  UNION ALL
  SELECT '枚举不规范', 'order.order_status 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE TRIM(order_status) <> ''
        AND LOWER(TRIM(order_status)) NOT IN ('待支付','已支付','已完成','已取消','退款中')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean
      WHERE LOWER(TRIM(order_status_name)) NOT IN ('待支付','已支付','已完成','已取消','退款中')),
    '数字编码与「完成/已付款」等变体统一为五态'
  UNION ALL
  SELECT '枚举不规范', 'order.pay_type 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE TRIM(pay_type) <> ''
        AND LOWER(TRIM(pay_type)) NOT IN ('微信支付','支付宝','银行卡','货到付款')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean
      WHERE LOWER(TRIM(pay_type_name)) NOT IN ('微信支付','支付宝','银行卡','货到付款')),
    'wechat/alipay/微信 统一为中文标准值'
  UNION ALL
  SELECT '枚举不规范', 'order.channel 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE TRIM(channel) <> ''
        AND TRIM(channel) NOT IN ('门店','APP','小程序','PC官网')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean
      WHERE TRIM(channel_name) NOT IN ('门店','APP','小程序','PC官网')),
    'app/pc 大小写变体统一为 APP/PC官网'
  UNION ALL
  SELECT '枚举不规范', 'behavior.behavior_type 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user_behavior
      WHERE TRIM(behavior_type) <> ''
        AND LOWER(TRIM(behavior_type)) NOT IN ('浏览','加购','收藏','购买')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean
      WHERE LOWER(TRIM(behavior_type_name)) NOT IN ('浏览','加购','收藏','购买')),
    'pv/cart/fav/buy 与中文混用统一为四类'
  UNION ALL
  SELECT '枚举不规范', 'product.category 含首尾空格',
    (SELECT COUNT(*) FROM ydsh_ods.ods_product WHERE category <> TRIM(category)),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean WHERE category <> TRIM(category)),
    'TRIM 去除首尾空格，类目收敛为 8 个规范值'

  -- ============ 二、缺失值 ============
  UNION ALL
  SELECT '缺失值', 'user.gender 空值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user WHERE TRIM(gender) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE gender IS NULL OR TRIM(gender) = ''),
    '空值归入「未知」，不臆造性别'
  UNION ALL
  SELECT '缺失值', 'user.member_level 空值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user WHERE TRIM(member_level) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean
      WHERE member_level_name IS NULL OR TRIM(member_level_name) = ''),
    '空值按最低等级「普通会员」兜底并打标'
  UNION ALL
  SELECT '缺失值', 'user.age 空值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user WHERE TRIM(age) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE age IS NULL),
    '取合法区间中位数填充，避免均值被离群值拉偏'
  UNION ALL
  SELECT '缺失值', 'product.launch_date 空值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_product WHERE TRIM(launch_date) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean WHERE TRIM(launch_date) = ''),
    '用同品类最早上架日期补全'
  UNION ALL
  SELECT '缺失值', 'user.email 空值（保留）',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user WHERE TRIM(email) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE email_flag = '缺失'),
    '弱依赖字段保留空值 + 标记位，不臆造邮箱'

  -- ============ 三、重复值 ============
  UNION ALL
  SELECT '重复值', 'order.order_id 重复行',
    (SELECT COUNT(*) - COUNT(DISTINCT TRIM(order_id)) FROM ydsh_ods.ods_order),
    (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM ydsh_dwd.dwd_order_clean),
    'ROW_NUMBER 按业务时间倒序保留最新一条'

  -- ============ 四、异常值 ============
  UNION ALL
  SELECT '异常值', 'user.age 越界或非数值（-3 / 0 / 150 等）',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(age) <> ''
        AND (TRIM(age) NOT RLIKE '^-?[0-9]+$' OR CAST(TRIM(age) AS INT) NOT BETWEEN 1 AND 120)),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE age NOT BETWEEN 1 AND 120),
    '非法值按合法区间中位数填充'
  UNION ALL
  SELECT '异常值', 'order.pay_amount 非正数',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE CAST(TRIM(pay_amount) AS DOUBLE) <= 0),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean WHERE pay_amount <= 0),
    '负金额无业务解释，整单剔除'
  UNION ALL
  SELECT '异常值', 'order.pay_amount 超上限（IQR 上界 11356.33）',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE CAST(TRIM(pay_amount) AS DOUBLE) > 11356.33),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean WHERE pay_amount > 11356.33),
    'Q3+3×IQR 稳健上界 = 11356.33 元，避免绝对阈值误删高客单'
  UNION ALL
  SELECT '异常值', 'order_item.quantity 非正数',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order_item WHERE CAST(TRIM(quantity) AS INT) <= 0),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_item_clean WHERE quantity <= 0),
    '0 件/负件不成立，明细行剔除'
  UNION ALL
  SELECT '异常值', 'product.price 非正或成本高于售价',
    (SELECT COUNT(*) FROM ydsh_ods.ods_product
      WHERE CAST(TRIM(price) AS DOUBLE) <= 0
         OR CAST(TRIM(cost) AS DOUBLE) > CAST(TRIM(price) AS DOUBLE)),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean WHERE price <= 0 OR cost > price),
    '按成本 × 1.2 修正，保留商品记录'

  -- ============ 五、格式不统一 ============
  UNION ALL
  SELECT '格式不统一', 'user.register_date 非 yyyy-MM-dd',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(register_date) NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean
      WHERE register_date IS NULL OR register_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
    '斜杠/8 位数字统一为 yyyy-MM-dd'
  UNION ALL
  SELECT '格式不统一', 'order.order_date 非 yyyy-MM-dd',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE TRIM(order_date) NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean
      WHERE order_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
    '斜杠日期统一为 yyyy-MM-dd'
  UNION ALL
  SELECT '格式不统一', 'behavior.behavior_time 非标准时间',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user_behavior
      WHERE TRIM(behavior_time) NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean
      WHERE behavior_time IS NULL OR behavior_time NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'),
    '斜杠并缺秒的格式统一并补 :00'
  UNION ALL
  SELECT '格式不统一', 'user.phone 非 11 位纯数字',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(phone) NOT RLIKE '^1[3-9][0-9]{9}$'),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE phone_flag = '格式异常'),
    '去分隔符后校验 11 位，不合规置空'
) t;

-- =============================================================
-- 输出对比表
-- =============================================================
SELECT category, item, before_cnt, after_cnt, fixed_cnt, fix_rate, strategy
FROM ydsh_dwd.dq_compare
ORDER BY category, before_cnt DESC;

-- 汇总：各类别修复率
SELECT category,
       SUM(before_cnt) AS before_total,
       SUM(after_cnt)  AS after_total,
       SUM(before_cnt) - SUM(after_cnt) AS fixed_total,
       ROUND(100.0 * (SUM(before_cnt) - SUM(after_cnt)) / SUM(before_cnt), 2) AS fix_rate
FROM ydsh_dwd.dq_compare
GROUP BY category
ORDER BY before_total DESC;

-- 总体修复率
SELECT SUM(before_cnt) AS before_total,
       SUM(after_cnt)  AS after_total,
       ROUND(100.0 * (SUM(before_cnt) - SUM(after_cnt)) / SUM(before_cnt), 2) AS overall_fix_rate
FROM ydsh_dwd.dq_compare;

-- ############################################################################
-- ## [13/21] sql/dwd/30_create_dim_tables.sql   （131 行）
-- ############################################################################

-- =============================================================
-- 30_create_dim_tables.sql
-- 作用：子任务 6 —— DWD 层维度表建模（星型模型的「角」）
-- 输入：ydsh_dwd.dwd_*_clean（22 号脚本产出的清洗完成态）
-- 输出：ydsh_dwd.dim_user / dim_product / dim_store / dim_date
--
-- 建模约定：
--   1) 维度表 = 描述性属性集合，只放「谁 / 什么 / 哪里 / 何时」；
--      度量（金额、数量）一律进事实表，避免维度表膨胀；
--   2) 主键统一命名为 <业务实体>_id，事实表用同名外键关联；
--   3) 所有维度表 STORED AS ORC + SNAPPY，压缩比高且支持谓词下推；
--   4) dim_date 是「日期维」，预先生成连续日期，避免事实表按日期
--      做字符串函数解析（比 SUBSTR/CAST 快，也便于按周/季汇总）。
--
-- 执行：bash scripts/run_sql.sh sql/dwd/30_create_dim_tables.sql
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_dwd;

-- =============================================================
-- 一、dim_user —— 用户维度
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_user;
CREATE TABLE ydsh_dwd.dim_user (
  user_id           STRING COMMENT '用户编号（主键）',
  user_name         STRING COMMENT '用户姓名',
  gender            STRING COMMENT '性别：男/女/未知',
  age               INT    COMMENT '年龄（缺失已用中位数填充）',
  province          STRING COMMENT '省份',
  city              STRING COMMENT '城市',
  region            STRING COMMENT '大区（省-市，直辖市已去重）',
  register_date     STRING COMMENT '注册日期 yyyy-MM-dd',
  member_level_code STRING COMMENT '会员等级编码（关联 dim_member_level）',
  member_level_name STRING COMMENT '会员等级名称',
  email             STRING COMMENT '邮箱（可空）',
  email_flag        STRING COMMENT '邮箱标记：正常/缺失',
  phone             STRING COMMENT '手机号（11 位，异常已置空）'
)
COMMENT 'DWD 维度表-用户'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- =============================================================
-- 二、dim_product —— 商品维度
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_product;
CREATE TABLE ydsh_dwd.dim_product (
  product_id   STRING COMMENT '商品编号（主键）',
  product_name STRING COMMENT '商品名称',
  category     STRING COMMENT '一级类目（已去空格）',
  sub_category STRING COMMENT '二级类目',
  brand        STRING COMMENT '品牌（英文统一大写）',
  price        DOUBLE COMMENT '售价（异常已按成本×1.2 修正）',
  cost         DOUBLE COMMENT '成本价',
  stock        INT    COMMENT '库存',
  status       STRING COMMENT '状态：在售/下架/缺货',
  launch_date  STRING COMMENT '上架日期 yyyy-MM-dd'
)
COMMENT 'DWD 维度表-商品'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- =============================================================
-- 三、dim_store —— 门店维度
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_store;
CREATE TABLE ydsh_dwd.dim_store (
  store_id   STRING COMMENT '门店编号（主键）',
  store_name STRING COMMENT '门店名称',
  province   STRING COMMENT '省份',
  city       STRING COMMENT '城市',
  district   STRING COMMENT '区县',
  address    STRING COMMENT '详细地址',
  open_date  STRING COMMENT '开业日期 yyyy-MM-dd',
  area       DOUBLE COMMENT '营业面积（㎡）',
  manager    STRING COMMENT '店长'
)
COMMENT 'DWD 维度表-门店'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- =============================================================
-- 四、dim_date —— 日期维度（预生成连续日期）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_date;
CREATE TABLE ydsh_dwd.dim_date (
  date_key    STRING COMMENT '日期主键 yyyy-MM-dd',
  year        INT    COMMENT '年',
  quarter     INT    COMMENT '季度 1-4',
  month       INT    COMMENT '月 1-12',
  day         INT    COMMENT '日 1-31',
  week_of_year INT   COMMENT '当年第几周',
  weekday     INT    COMMENT '星期几 1=周一 … 7=周日',
  is_weekend  INT    COMMENT '是否周末 1/0',
  year_month  STRING COMMENT '年月 yyyy-MM'
)
COMMENT 'DWD 维度表-日期（覆盖订单日期全区间）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 用 posexplode 生成从最早到最晚订单日期的连续日期序列
INSERT OVERWRITE TABLE ydsh_dwd.dim_date
SELECT
  DATE_FORMAT(d, 'yyyy-MM-dd')      AS date_key,
  YEAR(d)                           AS year,
  QUARTER(d)                        AS quarter,
  MONTH(d)                          AS month,
  DAY(d)                            AS day,
  WEEKOFYEAR(d)                     AS week_of_year,
  -- Hive 的 DAYOFWEEK 是 1=周日…7=周六，这里换算成 1=周一…7=周日
  CASE WHEN DAYOFWEEK(d) = 1 THEN 7 ELSE DAYOFWEEK(d) - 1 END AS weekday,
  CASE WHEN DAYOFWEEK(d) IN (1, 7) THEN 1 ELSE 0 END          AS is_weekend,
  DATE_FORMAT(d, 'yyyy-MM')         AS year_month
FROM (
  SELECT DATE_ADD(b.min_d, i) AS d
  FROM (
    SELECT MIN(TO_DATE(order_date)) AS min_d, MAX(TO_DATE(order_date)) AS max_d
    FROM ydsh_dwd.dwd_order_clean
  ) b
  LATERAL VIEW POSEXPLODE(SPLIT(SPACE(DATEDIFF(b.max_d, b.min_d)), ' ')) t AS i, x
) s;

-- =============================================================
-- 五、维度表行数核对
-- =============================================================
SELECT 'dim_user' AS tbl, COUNT(*) AS cnt FROM ydsh_dwd.dim_user
UNION ALL SELECT 'dim_product', COUNT(*) FROM ydsh_dwd.dim_product
UNION ALL SELECT 'dim_store',   COUNT(*) FROM ydsh_dwd.dim_store
UNION ALL SELECT 'dim_date',    COUNT(*) FROM ydsh_dwd.dim_date;

SELECT MIN(date_key) AS date_from, MAX(date_key) AS date_to FROM ydsh_dwd.dim_date;

-- ############################################################################
-- ## [14/21] sql/dwd/31_create_fact_order.sql   （71 行）
-- ############################################################################

-- =============================================================
-- 31_create_fact_order.sql
-- 作用：子任务 6 —— 订单事实表建模（星型模型的「心」）
-- 输出：
--   ydsh_dwd.dwd_order         订单事实表（按 order_date 分区）
--   ydsh_dwd.dwd_order_bucket  分桶表示例（按 user_id 哈希分 8 桶）
--
-- 为什么事实表按 order_date 分区：
--   ① 业务查询几乎都带时间范围（日报、月报、同环比），分区裁剪能直接跳过无关目录；
--   ② 按天分区粒度与 DWS 日汇总对齐，重跑某一天只需覆盖单个分区；
--   ③ 不用月份分区，是因为本项目数据量虽小但查询都按天切片，
--      月分区会让单分区过大、失去裁剪收益。
--
-- 为什么额外做一个分桶表：
--   分桶 = 按 user_id 哈希把数据切成固定份数，相同 user_id 必落同一桶。
--   当事实表需要按 user_id 做 JOIN（例如关联 dim_user 或做用户级窗口计算）时，
--   桶对桶的 Map 端连接可以省掉一轮全量 Shuffle。
--   本表用于演示与对比，主事实表仍保持「分区 + ORC」的最简组合。
--
-- 执行：bash scripts/run_sql.sh sql/dwd/31_create_fact_order.sql
-- =============================================================

-- =============================================================
-- 一、订单事实表（分区表）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_order;
CREATE TABLE ydsh_dwd.dwd_order (
  order_id          STRING COMMENT '订单编号（主键，已去重）',
  user_id           STRING COMMENT '用户编号（外键 → dim_user.user_id）',
  store_id          STRING COMMENT '门店编号（外键 → dim_store.store_id）',
  order_timestamp   STRING COMMENT '下单时间戳 yyyy-MM-dd HH:mm:ss',
  pay_amount        DOUBLE COMMENT '实付金额（度量）',
  discount_amount   DOUBLE COMMENT '优惠金额（度量）',
  pay_type_code     STRING COMMENT '支付方式编码（外键 → dim_pay_type.pay_code）',
  order_status_code STRING COMMENT '订单状态编码（外键 → dim_order_status.status_code）',
  channel_code      STRING COMMENT '渠道编码（外键 → dim_channel.channel_code）',
  order_cnt         INT    COMMENT '订单笔数恒为 1（度量，便于求和口径统一）'
)
COMMENT 'DWD 事实表-订单（星型模型核心，按日分区）'
PARTITIONED BY (order_date STRING COMMENT '下单日期 yyyy-MM-dd（同时是 dim_date 外键）')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- =============================================================
-- 二、分桶表示例（按 user_id 分 8 桶）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_order_bucket;
CREATE TABLE ydsh_dwd.dwd_order_bucket (
  order_id          STRING COMMENT '订单编号',
  user_id           STRING COMMENT '用户编号（分桶键）',
  store_id          STRING COMMENT '门店编号',
  order_date        STRING COMMENT '下单日期',
  order_timestamp   STRING COMMENT '下单时间戳',
  pay_amount        DOUBLE COMMENT '实付金额',
  discount_amount   DOUBLE COMMENT '优惠金额',
  pay_type_code     STRING COMMENT '支付方式编码',
  order_status_code STRING COMMENT '订单状态编码',
  channel_code      STRING COMMENT '渠道编码'
)
COMMENT 'DWD 订单事实表-分桶版（演示 user_id 哈希分桶，供 Map 端连接用）'
CLUSTERED BY (user_id) INTO 8 BUCKETS
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 开启分桶写入（Hive 2+ 默认已开，显式声明避免环境差异）
SET hive.enforce.bucketing = true;
SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

SELECT 'fact tables created' AS status,
       'dwd_order(partitioned) + dwd_order_bucket(8 buckets)' AS detail;

-- ############################################################################
-- ## [15/21] sql/dwd/32_load_dwd.sql   （98 行）
-- ############################################################################

-- =============================================================
-- 32_load_dwd.sql
-- 作用：子任务 6 —— DWD 层数据加载（维度表 + 事实表）
-- 输入：ydsh_dwd.dwd_*_clean / dim_* 码表
-- 输出：dim_user / dim_product / dim_store / dwd_order / dwd_order_bucket
--
-- 加载顺序：先维度、后事实 —— 事实表的外键必须在维度表里能查到，
-- 否则 JOIN 出报表时会出现「金额落不到维度上」的黑洞。
--
-- 执行：bash scripts/run_sql.sh sql/dwd/32_load_dwd.sql
-- =============================================================

SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;
SET hive.exec.max.dynamic.partitions = 2000;
SET hive.exec.max.dynamic.partitions.pernode = 2000;
SET hive.enforce.bucketing = true;

-- =============================================================
-- 一、加载维度表
-- =============================================================
INSERT OVERWRITE TABLE ydsh_dwd.dim_user
SELECT
  user_id, user_name, gender, age, province, city, region, register_date,
  member_level_code, member_level_name, email, email_flag, phone
FROM ydsh_dwd.dwd_user_clean;

INSERT OVERWRITE TABLE ydsh_dwd.dim_product
SELECT
  product_id, product_name, category, sub_category, brand,
  price, cost, stock, status, launch_date
FROM ydsh_dwd.dwd_product_clean;

INSERT OVERWRITE TABLE ydsh_dwd.dim_store
SELECT
  store_id, store_name, province, city, district, address, open_date, area, manager
FROM ydsh_dwd.dwd_store_clean;

-- =============================================================
-- 二、加载订单事实表（动态分区写入）
-- =============================================================
INSERT OVERWRITE TABLE ydsh_dwd.dwd_order PARTITION (order_date)
SELECT
  order_id,
  user_id,
  store_id,
  order_timestamp,
  pay_amount,
  discount_amount,
  pay_type_code,
  order_status_code,
  channel_code,
  1 AS order_cnt,
  order_date          -- 分区列放最后
FROM ydsh_dwd.dwd_order_clean;

-- =============================================================
-- 三、加载分桶表示例（用于对比 Map 端连接效果）
-- =============================================================
INSERT OVERWRITE TABLE ydsh_dwd.dwd_order_bucket
SELECT
  order_id, user_id, store_id, order_date, order_timestamp,
  pay_amount, discount_amount, pay_type_code, order_status_code, channel_code
FROM ydsh_dwd.dwd_order;

-- =============================================================
-- 四、加载结果核对
-- =============================================================
SELECT 'dim_user' AS tbl, COUNT(*) AS cnt FROM ydsh_dwd.dim_user
UNION ALL SELECT 'dim_product',       COUNT(*) FROM ydsh_dwd.dim_product
UNION ALL SELECT 'dim_store',         COUNT(*) FROM ydsh_dwd.dim_store
UNION ALL SELECT 'dim_date',          COUNT(*) FROM ydsh_dwd.dim_date
UNION ALL SELECT 'dwd_order',         COUNT(*) FROM ydsh_dwd.dwd_order
UNION ALL SELECT 'dwd_order_bucket',  COUNT(*) FROM ydsh_dwd.dwd_order_bucket;

-- 分区数量与分区样例
SELECT COUNT(DISTINCT order_date) AS partition_cnt,
       MIN(order_date) AS first_dt,
       MAX(order_date) AS last_dt
FROM ydsh_dwd.dwd_order;

SHOW PARTITIONS ydsh_dwd.dwd_order;

-- 引用完整性检查：事实表里有多少 user_id / store_id 在维度表中查不到
SELECT '孤儿 user_id' AS item, COUNT(*) AS cnt
FROM ydsh_dwd.dwd_order f
LEFT JOIN ydsh_dwd.dim_user d ON f.user_id = d.user_id
WHERE d.user_id IS NULL
UNION ALL
SELECT '孤儿 store_id', COUNT(*)
FROM ydsh_dwd.dwd_order f
LEFT JOIN ydsh_dwd.dim_store d ON f.store_id = d.store_id
WHERE d.store_id IS NULL;

-- 分桶文件数核对（应等于桶数 8 的整数倍）
SELECT INPUT__FILE__NAME AS file_path
FROM ydsh_dwd.dwd_order_bucket
LIMIT 3;

-- ############################################################################
-- ## [16/21] sql/dwd/33_load_dws.sql   （135 行）
-- ############################################################################

-- =============================================================
-- 33_load_dws.sql
-- 作用：四层架构落地 —— DWS 汇总层（按主题轻度汇总）
-- 输入：ydsh_dwd.dwd_order / dwd_order_item / dim_*
-- 输出：ydsh_dws.dws_daily_sales / dws_store_sales / dws_category_sales
--
-- DWS 的定位：把 DWD 的「明细」按分析主题做轻度聚合，只到「日 / 门店 / 类目」
-- 这一层，不再往上拼具体报表。往上（ADS）才是面向具体看板的指标。
-- 这样做的好处是：多个看板复用同一份汇总，口径不会各自算一遍导致对不上。
--
-- 执行：bash scripts/run_sql.sh sql/dwd/33_load_dws.sql
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_dws;

-- =============================================================
-- 一、日销售汇总
-- =============================================================
DROP TABLE IF EXISTS ydsh_dws.dws_daily_sales;
CREATE TABLE ydsh_dws.dws_daily_sales (
  date_key      STRING COMMENT '日期 yyyy-MM-dd（关联 dim_date）',
  order_cnt     BIGINT COMMENT '订单量',
  user_cnt      BIGINT COMMENT '下单用户数',
  store_cnt     BIGINT COMMENT '有成交门店数',
  gmv           DOUBLE COMMENT '成交总额（实付金额合计）',
  discount_sum  DOUBLE COMMENT '优惠金额合计',
  aov           DOUBLE COMMENT '客单价 = GMV / 订单量',
  cancel_cnt    BIGINT COMMENT '取消订单数'
)
COMMENT 'DWS 汇总-日销售'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_daily_sales
SELECT
  order_date,
  COUNT(DISTINCT order_id)                                   AS order_cnt,
  COUNT(DISTINCT user_id)                                    AS user_cnt,
  COUNT(DISTINCT store_id)                                   AS store_cnt,
  ROUND(SUM(pay_amount), 2)                                  AS gmv,
  ROUND(SUM(discount_amount), 2)                             AS discount_sum,
  ROUND(SUM(pay_amount) / COUNT(DISTINCT order_id), 2)       AS aov,
  COUNT(DISTINCT CASE WHEN order_status_code = 'OS04' THEN order_id END) AS cancel_cnt
FROM ydsh_dwd.dwd_order
GROUP BY order_date;

-- =============================================================
-- 二、门店销售汇总
-- =============================================================
DROP TABLE IF EXISTS ydsh_dws.dws_store_sales;
CREATE TABLE ydsh_dws.dws_store_sales (
  store_id    STRING COMMENT '门店编号',
  store_name  STRING COMMENT '门店名称',
  province    STRING COMMENT '省份',
  city        STRING COMMENT '城市',
  order_cnt   BIGINT COMMENT '订单量',
  user_cnt    BIGINT COMMENT '下单用户数',
  gmv         DOUBLE COMMENT '成交总额',
  aov         DOUBLE COMMENT '客单价'
)
COMMENT 'DWS 汇总-门店销售'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_store_sales
SELECT
  f.store_id,
  MAX(s.store_name)                        AS store_name,
  MAX(s.province)                          AS province,
  MAX(s.city)                              AS city,
  COUNT(DISTINCT f.order_id)               AS order_cnt,
  COUNT(DISTINCT f.user_id)                AS user_cnt,
  ROUND(SUM(f.pay_amount), 2)              AS gmv,
  ROUND(SUM(f.pay_amount) / COUNT(DISTINCT f.order_id), 2) AS aov
FROM ydsh_dwd.dwd_order f
LEFT JOIN ydsh_dwd.dim_store s ON f.store_id = s.store_id
GROUP BY f.store_id;

-- =============================================================
-- 三、类目销售汇总
-- =============================================================
-- 说明：订单事实表是「订单粒度」，类目信息在明细表里，
-- 所以类目 GMV 用「单价 × 数量 × (1 - 折扣率)」在明细粒度上还原。
DROP TABLE IF EXISTS ydsh_dws.dws_category_sales;
CREATE TABLE ydsh_dws.dws_category_sales (
  category    STRING COMMENT '一级类目',
  order_cnt   BIGINT COMMENT '关联订单数',
  item_qty    BIGINT COMMENT '销售件数',
  gmv         DOUBLE COMMENT '成交金额（明细还原）',
  avg_price   DOUBLE COMMENT '件单价'
)
COMMENT 'DWS 汇总-类目销售'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_category_sales
SELECT
  category,
  COUNT(DISTINCT order_id)                     AS order_cnt,
  SUM(quantity)                                AS item_qty,
  ROUND(SUM(alloc_gmv), 2)                     AS gmv,
  ROUND(SUM(alloc_gmv) / SUM(quantity), 2)     AS avg_price
FROM (
  SELECT
    a.category, a.order_id, a.quantity,
    -- 按明细金额占比把订单实付金额分摊到类目，
    -- 这样各类目 GMV 之和严格等于订单表总 GMV，报表才能对上账
    f.pay_amount * a.item_amt / t.order_item_amt AS alloc_gmv
  FROM (
    SELECT i.order_id, p.category, i.quantity,
           i.quantity * i.unit_price * (1 - i.discount) AS item_amt
    FROM ydsh_dwd.dwd_order_item_clean i
    JOIN ydsh_dwd.dim_product p ON i.product_id = p.product_id
  ) a
  JOIN (
    SELECT i.order_id, SUM(i.quantity * i.unit_price * (1 - i.discount)) AS order_item_amt
    FROM ydsh_dwd.dwd_order_item_clean i
    GROUP BY i.order_id
  ) t ON a.order_id = t.order_id
  JOIN ydsh_dwd.dwd_order f ON a.order_id = f.order_id
) x
GROUP BY category;

-- =============================================================
-- 四、汇总层核对
-- =============================================================
SELECT 'dws_daily_sales' AS tbl, COUNT(*) AS cnt FROM ydsh_dws.dws_daily_sales
UNION ALL SELECT 'dws_store_sales',    COUNT(*) FROM ydsh_dws.dws_store_sales
UNION ALL SELECT 'dws_category_sales', COUNT(*) FROM ydsh_dws.dws_category_sales;

-- 汇总层与事实表的口径一致性校验（两者 GMV 必须相等，否则说明有漏算）
SELECT
  (SELECT ROUND(SUM(pay_amount), 2) FROM ydsh_dwd.dwd_order)      AS fact_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_daily_sales) AS dws_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_store_sales) AS dws_store_gmv;

-- ############################################################################
-- ## [17/21] sql/dwd/40_eda.sql   （261 行）
-- ############################################################################

-- =============================================================
-- 40_eda.sql
-- 作用：子任务 7 —— 探索性数据分析（EDA）+ ADS 应用层落地
-- 输入：ydsh_dwd.dwd_order / dim_* / dwd_order_item / dwd_user_behavior / ydsh_dws.*
-- 输出：ydsh_ads.* 五张指标表 + 控制台分析结果（供《探索性分析简报》取数）
--
-- 分析顺序遵循「先总量、后结构、再个体」：
--   1) 总量：GMV / 订单量 / 用户数 / 客单价 —— 回答「盘子多大」
--   2) 结构：类目 / 区域 / 渠道 / 门店 / 时间 —— 回答「钱从哪来」
--   3) 个体：窗口函数做累计、排名、复购、RFM —— 回答「谁在买、买几次」
--
-- 执行：bash scripts/run_sql.sh sql/dwd/40_eda.sql
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_ads;

-- =============================================================
-- 一、总量指标（ads_kpi_overview）
-- =============================================================
DROP TABLE IF EXISTS ydsh_ads.ads_kpi_overview;
CREATE TABLE ydsh_ads.ads_kpi_overview (
  kpi_name   STRING COMMENT '指标名称',
  kpi_value  DOUBLE COMMENT '指标值',
  unit       STRING COMMENT '单位',
  calc_rule  STRING COMMENT '计算口径'
) COMMENT 'ADS-核心 KPI 总览' STORED AS ORC;

INSERT OVERWRITE TABLE ydsh_ads.ads_kpi_overview
SELECT '总成交额 GMV', ROUND(SUM(pay_amount), 2), '元', 'SUM(dwd_order.pay_amount)' FROM ydsh_dwd.dwd_order
UNION ALL
SELECT '订单总量', COUNT(DISTINCT order_id), '笔', 'COUNT(DISTINCT order_id)' FROM ydsh_dwd.dwd_order
UNION ALL
SELECT '下单用户数', COUNT(DISTINCT user_id), '人', 'COUNT(DISTINCT user_id)' FROM ydsh_dwd.dwd_order
UNION ALL
SELECT '客单价 AOV', ROUND(SUM(pay_amount) / COUNT(DISTINCT order_id), 2), '元', 'GMV / 订单量' FROM ydsh_dwd.dwd_order
UNION ALL
SELECT '人均消费 ARPU', ROUND(SUM(pay_amount) / COUNT(DISTINCT user_id), 2), '元', 'GMV / 下单用户数' FROM ydsh_dwd.dwd_order
UNION ALL
SELECT '人均下单次数', ROUND(COUNT(DISTINCT order_id) / COUNT(DISTINCT user_id), 2), '次', '订单量 / 下单用户数' FROM ydsh_dwd.dwd_order
UNION ALL
SELECT '优惠金额合计', ROUND(SUM(discount_amount), 2), '元', 'SUM(discount_amount)' FROM ydsh_dwd.dwd_order
UNION ALL
SELECT '取消订单占比', ROUND(100.0 * COUNT(DISTINCT CASE WHEN order_status_code = 'OS04' THEN order_id END) / COUNT(DISTINCT order_id), 2), '%', '取消订单数 / 订单量' FROM ydsh_dwd.dwd_order;

-- =============================================================
-- 二、区域分布（ads_region_sales）
-- =============================================================
DROP TABLE IF EXISTS ydsh_ads.ads_region_sales;
CREATE TABLE ydsh_ads.ads_region_sales (
  province    STRING COMMENT '省份',
  order_cnt   BIGINT COMMENT '订单量',
  user_cnt    BIGINT COMMENT '下单用户数',
  gmv         DOUBLE COMMENT '成交额',
  aov         DOUBLE COMMENT '客单价',
  gmv_ratio   DOUBLE COMMENT 'GMV 占比（%）'
) COMMENT 'ADS-省份销售分布' STORED AS ORC;

INSERT OVERWRITE TABLE ydsh_ads.ads_region_sales
SELECT
  COALESCE(u.province, '未知')                     AS province,
  COUNT(DISTINCT f.order_id)                       AS order_cnt,
  COUNT(DISTINCT f.user_id)                        AS user_cnt,
  ROUND(SUM(f.pay_amount), 2)                      AS gmv,
  ROUND(SUM(f.pay_amount) / COUNT(DISTINCT f.order_id), 2) AS aov,
  ROUND(100.0 * SUM(f.pay_amount) / SUM(SUM(f.pay_amount)) OVER (), 2) AS gmv_ratio
FROM ydsh_dwd.dwd_order f
LEFT JOIN ydsh_dwd.dim_user u ON f.user_id = u.user_id
GROUP BY COALESCE(u.province, '未知');

-- =============================================================
-- 三、渠道分布（ads_channel_sales）
-- =============================================================
DROP TABLE IF EXISTS ydsh_ads.ads_channel_sales;
CREATE TABLE ydsh_ads.ads_channel_sales (
  channel_code STRING COMMENT '渠道编码',
  channel_name STRING COMMENT '渠道名称',
  order_cnt    BIGINT COMMENT '订单量',
  gmv          DOUBLE COMMENT '成交额',
  aov          DOUBLE COMMENT '客单价',
  gmv_ratio    DOUBLE COMMENT 'GMV 占比（%）'
) COMMENT 'ADS-渠道销售分布' STORED AS ORC;

INSERT OVERWRITE TABLE ydsh_ads.ads_channel_sales
SELECT
  c.channel_code,
  c.channel_name,
  COUNT(DISTINCT f.order_id)  AS order_cnt,
  ROUND(SUM(f.pay_amount), 2) AS gmv,
  ROUND(SUM(f.pay_amount) / COUNT(DISTINCT f.order_id), 2) AS aov,
  ROUND(100.0 * SUM(f.pay_amount) / SUM(SUM(f.pay_amount)) OVER (), 2) AS gmv_ratio
FROM ydsh_dwd.dwd_order f
JOIN ydsh_dwd.dim_channel c ON f.channel_code = c.channel_code
GROUP BY c.channel_code, c.channel_name;

-- =============================================================
-- 四、门店排名（ads_store_rank）—— 窗口函数 RANK()
-- =============================================================
DROP TABLE IF EXISTS ydsh_ads.ads_store_rank;
CREATE TABLE ydsh_ads.ads_store_rank (
  rank_no    INT    COMMENT 'GMV 排名',
  store_id   STRING COMMENT '门店编号',
  store_name STRING COMMENT '门店名称',
  province   STRING COMMENT '省份',
  gmv        DOUBLE COMMENT '成交额',
  order_cnt  BIGINT COMMENT '订单量',
  aov        DOUBLE COMMENT '客单价'
) COMMENT 'ADS-门店 GMV 排名' STORED AS ORC;

INSERT OVERWRITE TABLE ydsh_ads.ads_store_rank
SELECT
  rk, store_id, store_name, province, gmv, order_cnt, aov
FROM (
  SELECT
    RANK() OVER (ORDER BY gmv DESC) AS rk,
    store_id, store_name, province, gmv, order_cnt, aov
  FROM ydsh_dws.dws_store_sales
) t
WHERE rk <= 15;

-- =============================================================
-- 五、用户价值分层（ads_user_value）—— 窗口函数 + RFM
-- =============================================================
-- R（Recency）= 距最近一次下单天数；F（Frequency）= 下单次数；M（Monetary）= 累计金额
-- 三者各按整体分位打 A/B/C 三档（1/3 分位），组合成用户分层，供运营差异化触达。
DROP TABLE IF EXISTS ydsh_ads.ads_user_value;
CREATE TABLE ydsh_ads.ads_user_value (
  user_id        STRING COMMENT '用户编号',
  order_cnt      BIGINT COMMENT '下单次数 F',
  total_gmv      DOUBLE COMMENT '累计消费 M',
  last_order_date STRING COMMENT '最近下单日期',
  recency_days   INT    COMMENT '距最近下单天数 R（以数据最大日期为基准）',
  f_level        STRING COMMENT 'F 档位 A/B/C',
  m_level        STRING COMMENT 'M 档位 A/B/C',
  user_segment   STRING COMMENT '用户分层：重要价值/重要保持/一般价值/流失预警'
) COMMENT 'ADS-用户价值分层（RFM）' STORED AS ORC;

INSERT OVERWRITE TABLE ydsh_ads.ads_user_value
SELECT
  user_id, order_cnt, total_gmv, last_order_date, recency_days,
  f_level, m_level,
  CASE
    WHEN f_level = 'A' AND m_level = 'A' THEN '重要价值用户'
    WHEN f_level = 'A' AND m_level <> 'A' THEN '高频潜力用户'
    WHEN f_level <> 'A' AND m_level = 'A' THEN '高价值低频用户'
    WHEN m_level = 'C' AND f_level = 'C'  THEN '低价值用户'
    ELSE '一般价值用户'
  END AS user_segment
FROM (
  SELECT
    user_id, order_cnt, total_gmv, last_order_date, recency_days,
    CASE WHEN f_pct >= 0.6667 THEN 'A' WHEN f_pct >= 0.3333 THEN 'B' ELSE 'C' END AS f_level,
    CASE WHEN m_pct >= 0.6667 THEN 'A' WHEN m_pct >= 0.3333 THEN 'B' ELSE 'C' END AS m_level
  FROM (
    SELECT
      user_id, order_cnt, total_gmv, last_order_date, recency_days,
      PERCENT_RANK() OVER (ORDER BY order_cnt)   AS f_pct,
      PERCENT_RANK() OVER (ORDER BY total_gmv)   AS m_pct
    FROM (
      SELECT
        user_id,
        COUNT(DISTINCT order_id)                       AS order_cnt,
        ROUND(SUM(pay_amount), 2)                      AS total_gmv,
        MAX(order_date)                                AS last_order_date,
        DATEDIFF(MAX(order_date), MIN(order_date))     AS recency_days
      FROM ydsh_dwd.dwd_order
      GROUP BY user_id
    ) a
  ) b
) c;

-- =============================================================
-- 六、分析结果输出（写进《探索性分析简报》）
-- =============================================================

-- 6.1 核心 KPI
SELECT kpi_name, kpi_value, unit FROM ydsh_ads.ads_kpi_overview;

-- 6.2 月度趋势 + 环比（窗口函数 LAG）
SELECT
  SUBSTR(order_date, 1, 7)                                   AS month,
  COUNT(DISTINCT order_id)                                   AS order_cnt,
  ROUND(SUM(pay_amount), 2)                                  AS gmv,
  ROUND(SUM(pay_amount) / COUNT(DISTINCT order_id), 2)       AS aov,
  ROUND(100.0 * (SUM(pay_amount) - LAG(SUM(pay_amount)) OVER (ORDER BY SUBSTR(order_date, 1, 7)))
        / LAG(SUM(pay_amount)) OVER (ORDER BY SUBSTR(order_date, 1, 7)), 2) AS gmv_mom_pct
FROM ydsh_dwd.dwd_order
GROUP BY SUBSTR(order_date, 1, 7)
ORDER BY month;

-- 6.3 类目销售排行
SELECT category, order_cnt, item_qty, gmv, avg_price
FROM ydsh_dws.dws_category_sales
ORDER BY gmv DESC;

-- 6.4 渠道分布
SELECT channel_name, order_cnt, gmv, aov, gmv_ratio
FROM ydsh_ads.ads_channel_sales
ORDER BY gmv DESC;

-- 6.5 省份 Top10
SELECT province, order_cnt, user_cnt, gmv, gmv_ratio
FROM ydsh_ads.ads_region_sales
ORDER BY gmv DESC
LIMIT 10;

-- 6.6 用户分层层级分布
SELECT user_segment, COUNT(*) AS user_cnt,
       ROUND(SUM(total_gmv), 2) AS gmv,
       ROUND(100.0 * SUM(total_gmv) / SUM(SUM(total_gmv)) OVER (), 2) AS gmv_ratio
FROM ydsh_ads.ads_user_value
GROUP BY user_segment
ORDER BY gmv DESC;

-- 6.7 复购情况：下单次数分布
SELECT order_cnt AS orders_per_user, COUNT(*) AS user_cnt
FROM ydsh_ads.ads_user_value
GROUP BY order_cnt
ORDER BY order_cnt;

-- 6.8 用户累计消费（窗口函数 SUM OVER）—— 取消费额最高的 3 个用户展示
SELECT user_id, order_date, pay_amount,
       SUM(pay_amount) OVER (PARTITION BY user_id ORDER BY order_date, order_timestamp
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_amount,
       ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY pay_amount DESC)        AS amount_rank_in_user
FROM ydsh_dwd.dwd_order
WHERE user_id IN (
  SELECT user_id FROM ydsh_ads.ads_user_value ORDER BY total_gmv DESC LIMIT 3
)
ORDER BY user_id, order_date
LIMIT 20;

-- 6.9 行为时段分布（按时段聚合，验证用户活跃规律）
SELECT
  CASE
    WHEN behavior_hour BETWEEN '00' AND '05' THEN '凌晨 00-05'
    WHEN behavior_hour BETWEEN '06' AND '08' THEN '早间 06-08'
    WHEN behavior_hour BETWEEN '09' AND '11' THEN '上午 09-11'
    WHEN behavior_hour BETWEEN '12' AND '13' THEN '午间 12-13'
    WHEN behavior_hour BETWEEN '14' AND '17' THEN '下午 14-17'
    WHEN behavior_hour BETWEEN '18' AND '21' THEN '晚间 18-21'
    ELSE '深夜 22-23'
  END AS time_bucket,
  COUNT(*) AS behavior_cnt,
  COUNT(DISTINCT user_id) AS user_cnt
FROM ydsh_dwd.dwd_user_behavior_clean
GROUP BY
  CASE
    WHEN behavior_hour BETWEEN '00' AND '05' THEN '凌晨 00-05'
    WHEN behavior_hour BETWEEN '06' AND '08' THEN '早间 06-08'
    WHEN behavior_hour BETWEEN '09' AND '11' THEN '上午 09-11'
    WHEN behavior_hour BETWEEN '12' AND '13' THEN '午间 12-13'
    WHEN behavior_hour BETWEEN '14' AND '17' THEN '下午 14-17'
    WHEN behavior_hour BETWEEN '18' AND '21' THEN '晚间 18-21'
    ELSE '深夜 22-23'
  END
ORDER BY behavior_cnt DESC;

-- 6.10 分桶效果验证：对分桶键做聚合时，Map 端连接可用（EXPLAIN 中应出现 bucket map join）
SELECT /*+ MAPJOIN(u) */ COUNT(*) AS joined_rows
FROM ydsh_dwd.dwd_order_bucket f
JOIN ydsh_dwd.dim_user u ON f.user_id = u.user_id;

-- ############################################################################
-- ## [18/21] sql/dws/50_build_dws_multi.sql   （258 行）
-- ############################################################################

-- =============================================================
-- 50_build_dws_multi.sql
-- 作用：第 3 周 DWS 汇总层（多维粒度）—— 按天 / 周 / 月 / 品类 / 门店 / 渠道
-- 输入：ydsh_dwd.dwd_order、dwd_order_item_clean、dim_product、dim_store
-- 输出：ydsh_dws.dws_trade_day / dws_trade_week / dws_trade_month
--       ydsh_dws.dws_category_day / dws_store_day / dws_channel_day
--
-- 与第 2 周 dws_daily_sales 的区别：
--   第 2 周是「全期一条汇总」，只够做总览；
--   本周改成「保留时间粒度」的汇总，才能支撑趋势、预测、同比环比。
-- 口径统一（详见 docs/指标定义文档.md）：
--   GMV = 所有有效订单实付金额之和，含后续取消单（取消另计 cancel_cnt）
--   订单量 = COUNT(DISTINCT order_id)
--   用户数 = COUNT(DISTINCT user_id)
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_dws;

-- =============================================================
-- 一、天粒度全站汇总
-- =============================================================
DROP TABLE IF EXISTS ydsh_dws.dws_trade_day;
CREATE TABLE ydsh_dws.dws_trade_day (
  dt            STRING COMMENT '日期 yyyy-MM-dd',
  gmv           DOUBLE COMMENT '成交总额（实付金额合计）',
  order_cnt     BIGINT COMMENT '订单量',
  user_cnt      BIGINT COMMENT '下单用户数',
  store_cnt     BIGINT COMMENT '有成交门店数',
  discount_sum  DOUBLE COMMENT '优惠金额合计',
  cancel_cnt    BIGINT COMMENT '取消订单数',
  aov           DOUBLE COMMENT '客单价 = GMV / 订单量'
)
COMMENT 'DWS-天粒度全站交易汇总'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_trade_day
SELECT
  order_date,
  ROUND(SUM(pay_amount), 2),
  COUNT(DISTINCT order_id),
  COUNT(DISTINCT user_id),
  COUNT(DISTINCT store_id),
  ROUND(SUM(discount_amount), 2),
  COUNT(DISTINCT CASE WHEN order_status_code = 'OS04' THEN order_id END),
  ROUND(SUM(pay_amount) / COUNT(DISTINCT order_id), 2)
FROM ydsh_dwd.dwd_order
GROUP BY order_date;

-- =============================================================
-- 二、周粒度汇总
-- =============================================================
-- next_day(d,'MO') 返回「下一个周一」，减 7 天即本周周一，作为周起始日
DROP TABLE IF EXISTS ydsh_dws.dws_trade_week;
CREATE TABLE ydsh_dws.dws_trade_week (
  week_start    STRING COMMENT '周起始日（周一）yyyy-MM-dd',
  week_end      STRING COMMENT '周结束日（周日）yyyy-MM-dd',
  gmv           DOUBLE COMMENT '成交总额',
  order_cnt     BIGINT COMMENT '订单量',
  user_cnt      BIGINT COMMENT '下单用户数',
  aov           DOUBLE COMMENT '客单价'
)
COMMENT 'DWS-周粒度交易汇总'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_trade_week
SELECT
  week_start,
  date_add(week_start, 6)                                 AS week_end,
  ROUND(SUM(gmv), 2)                                      AS gmv,
  SUM(order_cnt)                                          AS order_cnt,
  COUNT(DISTINCT user_id)                                 AS user_cnt,
  ROUND(SUM(gmv) / SUM(order_cnt), 2)                     AS aov
FROM (
  SELECT
    date_sub(next_day(order_date, 'MO'), 7) AS week_start,
    order_id, user_id, pay_amount           AS gmv,
    1                                       AS order_cnt
  FROM ydsh_dwd.dwd_order
) d
GROUP BY week_start;

-- =============================================================
-- 三、月粒度汇总
-- =============================================================
DROP TABLE IF EXISTS ydsh_dws.dws_trade_month;
CREATE TABLE ydsh_dws.dws_trade_month (
  month         STRING COMMENT '月份 yyyy-MM',
  gmv           DOUBLE COMMENT '成交总额',
  order_cnt     BIGINT COMMENT '订单量',
  user_cnt      BIGINT COMMENT '下单用户数',
  aov           DOUBLE COMMENT '客单价',
  cancel_cnt    BIGINT COMMENT '取消订单数',
  mom_rate      DOUBLE COMMENT 'GMV 环比（小数，0.05 = +5%）'
)
COMMENT 'DWS-月粒度交易汇总'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_trade_month
SELECT
  month,
  gmv,
  order_cnt,
  user_cnt,
  ROUND(gmv / order_cnt, 2) AS aov,
  cancel_cnt,
  ROUND((gmv - LAG(gmv) OVER (ORDER BY month)) / LAG(gmv) OVER (ORDER BY month), 4) AS mom_rate
FROM (
  SELECT
    substr(order_date, 1, 7)                                AS month,
    ROUND(SUM(pay_amount), 2)                               AS gmv,
    COUNT(DISTINCT order_id)                                AS order_cnt,
    COUNT(DISTINCT user_id)                                 AS user_cnt,
    COUNT(DISTINCT CASE WHEN order_status_code = 'OS04' THEN order_id END) AS cancel_cnt
  FROM ydsh_dwd.dwd_order
  GROUP BY substr(order_date, 1, 7)
) m;

-- =============================================================
-- 四、天 × 品类汇总（GMV 按订单内明细金额占比分摊，保证与订单侧对账）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dws.dws_category_day;
CREATE TABLE ydsh_dws.dws_category_day (
  dt          STRING COMMENT '日期 yyyy-MM-dd',
  category    STRING COMMENT '一级品类',
  order_cnt   BIGINT COMMENT '关联订单数',
  item_qty    BIGINT COMMENT '销售件数',
  gmv         DOUBLE COMMENT '分摊后成交金额'
)
COMMENT 'DWS-天×品类销售汇总'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 口径说明（第 5 周联调修正）：
--   订单表里有 139 笔订单的明细在清洗阶段被全部剔除（唯一明细的 unit_price 为负），
--   若仍用 inner join 关联明细，这 139 笔合计 349,609.44 元的 GMV 会从品类维度
--   静默消失——品类汇总 35,767,077.49 与全站 36,116,687.06 对不上，差 0.97%。
--   处理方式：明细为空的订单归入「未知品类」单独成行。
--   宁可多一个显式的「未知品类」，也不要让金额凭空少掉。
INSERT OVERWRITE TABLE ydsh_dws.dws_category_day
SELECT dt,
       category,
       COUNT(DISTINCT order_id)   AS order_cnt,
       SUM(item_qty)              AS item_qty,
       -- 这里不取整：先按分组 ROUND 再相加，3043 个分组会累积出 0.13 元的
       -- 「舍入漂移」，导致品类汇总与全站 GMV 差几分钱。取整交给展示层，
       -- 存储层保持可加性（sum(分组) == 总量）。
       SUM(gmv)                   AS gmv
FROM (
  -- 1) 有有效明细的订单：按「标价 × (1-折扣)」权重把实付金额分摊到品类
  SELECT f.order_date                                       AS dt,
         a.category                                         AS category,
         a.order_id                                         AS order_id,
         a.quantity                                         AS item_qty,
         f.pay_amount * a.item_amt / t.order_item_amt        AS gmv
  FROM (
    SELECT i.order_id, p.category, i.quantity,
           i.quantity * i.unit_price * (1 - i.discount) AS item_amt
    FROM ydsh_dwd.dwd_order_item_clean i
    JOIN ydsh_dwd.dim_product p ON i.product_id = p.product_id
  ) a
  JOIN (
    SELECT order_id, SUM(quantity * unit_price * (1 - discount)) AS order_item_amt
    FROM ydsh_dwd.dwd_order_item_clean
    GROUP BY order_id
  ) t ON a.order_id = t.order_id
  JOIN ydsh_dwd.dwd_order f ON a.order_id = f.order_id

  UNION ALL

  -- 2) 明细为空的订单：金额归入「未知品类」，不静默丢弃
  SELECT o.order_date   AS dt,
         '未知品类'      AS category,
         o.order_id     AS order_id,
         0              AS item_qty,
         o.pay_amount   AS gmv
  FROM ydsh_dwd.dwd_order o
  LEFT JOIN (SELECT DISTINCT order_id FROM ydsh_dwd.dwd_order_item_clean) i
         ON o.order_id = i.order_id
  WHERE i.order_id IS NULL
) u
GROUP BY dt, category;

-- =============================================================
-- 五、天 × 门店汇总
-- =============================================================
DROP TABLE IF EXISTS ydsh_dws.dws_store_day;
CREATE TABLE ydsh_dws.dws_store_day (
  dt          STRING COMMENT '日期 yyyy-MM-dd',
  store_id    STRING COMMENT '门店编号',
  gmv         DOUBLE COMMENT '成交总额',
  order_cnt   BIGINT COMMENT '订单量',
  user_cnt    BIGINT COMMENT '下单用户数',
  aov         DOUBLE COMMENT '客单价'
)
COMMENT 'DWS-天×门店销售汇总'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_store_day
SELECT
  order_date,
  store_id,
  ROUND(SUM(pay_amount), 2),
  COUNT(DISTINCT order_id),
  COUNT(DISTINCT user_id),
  ROUND(SUM(pay_amount) / COUNT(DISTINCT order_id), 2)
FROM ydsh_dwd.dwd_order
GROUP BY order_date, store_id;

-- =============================================================
-- 六、天 × 渠道汇总
-- =============================================================
DROP TABLE IF EXISTS ydsh_dws.dws_channel_day;
CREATE TABLE ydsh_dws.dws_channel_day (
  dt            STRING COMMENT '日期 yyyy-MM-dd',
  channel_code  STRING COMMENT '渠道编码（关联 dim_channel）',
  gmv           DOUBLE COMMENT '成交总额',
  order_cnt     BIGINT COMMENT '订单量',
  user_cnt      BIGINT COMMENT '下单用户数',
  aov           DOUBLE COMMENT '客单价'
)
COMMENT 'DWS-天×渠道销售汇总'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_channel_day
SELECT
  order_date,
  channel_code,
  ROUND(SUM(pay_amount), 2),
  COUNT(DISTINCT order_id),
  COUNT(DISTINCT user_id),
  ROUND(SUM(pay_amount) / COUNT(DISTINCT order_id), 2)
FROM ydsh_dwd.dwd_order
GROUP BY order_date, channel_code;

-- =============================================================
-- 七、装载结果与口径校验
-- =============================================================
SELECT 'dws_trade_day'    AS tbl, COUNT(*) AS cnt FROM ydsh_dws.dws_trade_day
UNION ALL SELECT 'dws_trade_week',    COUNT(*) FROM ydsh_dws.dws_trade_week
UNION ALL SELECT 'dws_trade_month',   COUNT(*) FROM ydsh_dws.dws_trade_month
UNION ALL SELECT 'dws_category_day',  COUNT(*) FROM ydsh_dws.dws_category_day
UNION ALL SELECT 'dws_store_day',     COUNT(*) FROM ydsh_dws.dws_store_day
UNION ALL SELECT 'dws_channel_day',   COUNT(*) FROM ydsh_dws.dws_channel_day;

-- 三处 GMV 必须完全一致，否则说明汇总口径有漏算/重算
SELECT
  (SELECT ROUND(SUM(pay_amount), 2) FROM ydsh_dwd.dwd_order)        AS fact_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_trade_day)    AS day_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_trade_week)   AS week_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_trade_month)  AS month_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_category_day) AS category_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_store_day)    AS store_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_channel_day)  AS channel_gmv;

-- ############################################################################
-- ## [19/21] sql/dws/51_build_dws_user.sql   （63 行）
-- ############################################################################

-- =============================================================
-- 51_build_dws_user.sql
-- 作用：DWS 用户粒度汇总（RFM 与复购率的计算底座）
-- 输入：ydsh_dwd.dwd_order
-- 输出：ydsh_dws.dws_user_stat
--
-- 为什么单独建一张用户宽表：
--   复购率、用户价值分层、活跃天数都基于「用户」这个粒度，
--   放在 ADS 层各算一遍会重复扫描事实表，也容易口径不一致。
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_dws;

DROP TABLE IF EXISTS ydsh_dws.dws_user_stat;
CREATE TABLE ydsh_dws.dws_user_stat (
  user_id            STRING COMMENT '用户编号',
  order_cnt          BIGINT COMMENT '累计下单次数',
  gmv                DOUBLE COMMENT '累计成交金额',
  first_order_date   STRING COMMENT '首单日期',
  last_order_date    STRING COMMENT '末单日期',
  active_days        BIGINT COMMENT '有下单行为的天数',
  avg_order_amount   DOUBLE COMMENT '笔单价 = GMV / 订单数',
  is_repurchase      INT    COMMENT '是否复购用户：订单数 >= 2 记 1',
  recency_days       INT    COMMENT '距今未下单天数（R），以数据最大日期为基准'
)
COMMENT 'DWS-用户交易汇总'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_user_stat
SELECT
  user_id,
  order_cnt,
  gmv,
  first_order_date,
  last_order_date,
  active_days,
  ROUND(gmv / order_cnt, 2)                          AS avg_order_amount,
  CASE WHEN order_cnt >= 2 THEN 1 ELSE 0 END         AS is_repurchase,
  datediff(g.max_dt, last_order_date)                AS recency_days
FROM (
  SELECT
    user_id,
    COUNT(DISTINCT order_id)        AS order_cnt,
    ROUND(SUM(pay_amount), 2)       AS gmv,
    MIN(order_date)                 AS first_order_date,
    MAX(order_date)                 AS last_order_date,
    COUNT(DISTINCT order_date)      AS active_days
  FROM ydsh_dwd.dwd_order
  GROUP BY user_id
) u
-- 观察窗口的「今天」用数据最大日期，而不是系统当前日期，
-- 否则历史数据集的 R 值会全部被拉到几百天，失去区分度
CROSS JOIN (SELECT MAX(order_date) AS max_dt FROM ydsh_dwd.dwd_order) g;

-- 装载校验：用户数、复购人数、GMV 三项与事实表对账
SELECT
  COUNT(*)                                                AS user_cnt,
  SUM(is_repurchase)                                      AS repurchase_user_cnt,
  ROUND(SUM(is_repurchase) / COUNT(*), 4)                 AS repurchase_rate,
  ROUND(SUM(gmv), 2)                                      AS user_gmv,
  (SELECT ROUND(SUM(pay_amount), 2) FROM ydsh_dwd.dwd_order) AS fact_gmv
FROM ydsh_dws.dws_user_stat;

-- ############################################################################
-- ## [20/21] sql/ads/60_build_ads_kpi.sql   （131 行）
-- ############################################################################

-- =============================================================
-- 60_build_ads_kpi.sql
-- 作用：ADS 应用层 —— 核心 KPI 指标表（统一口径的唯一出口）
-- 输入：ydsh_dws.dws_trade_day / dws_trade_month / dws_user_stat / dws_category_day
-- 输出：ydsh_ads.ads_kpi_core、ydsh_ads.ads_monthly_trend
--
-- 设计意图：
--   把「指标」做成一张长表（指标名 / 值 / 单位 / 口径说明），
--   而不是宽表。原因是宽表每加一个指标就要改表结构，
--   长表只增行不改结构，且「口径说明」能跟着指标一起交付，
--   避免出现「数出多门」——同一个 GMV 在不同报表里算出不同数。
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_ads;

DROP TABLE IF EXISTS ydsh_ads.ads_kpi_core;
CREATE TABLE ydsh_ads.ads_kpi_core (
  metric_code   STRING COMMENT '指标编码',
  metric_name   STRING COMMENT '指标名称',
  metric_value  DOUBLE COMMENT '指标值',
  unit          STRING COMMENT '单位',
  calc_rule     STRING COMMENT '计算口径'
)
COMMENT 'ADS-核心 KPI 指标（长表，口径唯一出口）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_ads.ads_kpi_core

-- 1. GMV
SELECT 'KPI_GMV' AS metric_code, 'GMV 成交总额' AS metric_name,
       ROUND(SUM(gmv), 2) AS metric_value, '元' AS unit,
       '所有有效订单实付金额之和（含后续取消单，取消单另计取消率）' AS calc_rule
FROM ydsh_dws.dws_trade_day

UNION ALL
-- 2. 订单量
SELECT 'KPI_ORDER_CNT', '订单量',
       CAST(SUM(order_cnt) AS DOUBLE), '单',
       '去重订单数 COUNT(DISTINCT order_id)'
FROM ydsh_dws.dws_trade_day

UNION ALL
-- 3. 客单价
SELECT 'KPI_AOV', '客单价 AOV',
       ROUND(SUM(gmv) / SUM(order_cnt), 2), '元/单',
       'GMV ÷ 订单量'
FROM ydsh_dws.dws_trade_day

UNION ALL
-- 4. 活跃用户数
SELECT 'KPI_ACTIVE_USER', '活跃用户数',
       CAST(COUNT(*) AS DOUBLE), '人',
       '观察期内有下单行为的去重用户数'
FROM ydsh_dws.dws_user_stat

UNION ALL
-- 5. 复购率
SELECT 'KPI_REPURCHASE_RATE', '复购率',
       ROUND(SUM(is_repurchase) / COUNT(*), 4), '比率',
       '下单次数 ≥ 2 的用户数 ÷ 下单用户数'
FROM ydsh_dws.dws_user_stat

UNION ALL
-- 6. 人均下单次数
SELECT 'KPI_ORDER_PER_USER', '人均下单次数',
       ROUND(SUM(order_cnt) / COUNT(*), 2), '次/人',
       '订单量 ÷ 下单用户数'
FROM ydsh_dws.dws_user_stat

UNION ALL
-- 7. 取消率
SELECT 'KPI_CANCEL_RATE', '订单取消率',
       ROUND(SUM(cancel_cnt) / SUM(order_cnt), 4), '比率',
       '状态为「已取消」(OS04) 的订单数 ÷ 订单量'
FROM ydsh_dws.dws_trade_day

UNION ALL
-- 8. 优惠金额与折扣力度
SELECT 'KPI_DISCOUNT_RATE', '整体折扣率',
       ROUND(SUM(discount_sum) / (SUM(gmv) + SUM(discount_sum)), 4), '比率',
       '优惠金额 ÷（实付金额 + 优惠金额），衡量让利力度'
FROM ydsh_dws.dws_trade_day

UNION ALL
-- 9. 品类销售占比（Top1 品类）
SELECT 'KPI_TOP_CATEGORY_SHARE', '第一大品类 GMV 占比',
       ROUND(top.cat_gmv / tot.gmv, 4), '比率',
       'GMV 最高品类的成交额 ÷ 全站 GMV'
FROM (
  SELECT MAX(cat_gmv) AS cat_gmv
  FROM (SELECT SUM(gmv) AS cat_gmv FROM ydsh_dws.dws_category_day GROUP BY category) a
) top
CROSS JOIN (
  SELECT SUM(gmv) AS gmv FROM ydsh_dws.dws_category_day
) tot

UNION ALL
-- 10. 下单频次结构
SELECT 'KPI_ONCE_BUYER_RATIO', '单次购买用户占比',
       ROUND(SUM(CASE WHEN order_cnt = 1 THEN 1 ELSE 0 END) / COUNT(*), 4), '比率',
       '仅下单 1 次的用户数 ÷ 下单用户数'
FROM ydsh_dws.dws_user_stat;

-- =============================================================
-- 月度趋势表（供 Python 预测建模读取，也可直接做同比/环比）
-- =============================================================
DROP TABLE IF EXISTS ydsh_ads.ads_monthly_trend;
CREATE TABLE ydsh_ads.ads_monthly_trend (
  month         STRING COMMENT '月份 yyyy-MM',
  month_seq     INT    COMMENT '月份序号 1..12，供建模排序',
  gmv           DOUBLE COMMENT '成交总额',
  order_cnt     BIGINT COMMENT '订单量',
  user_cnt      BIGINT COMMENT '下单用户数',
  aov           DOUBLE COMMENT '客单价',
  mom_rate      DOUBLE COMMENT 'GMV 环比',
  gmv_share     DOUBLE COMMENT '该月 GMV 占全年比重'
)
COMMENT 'ADS-月度经营趋势'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_ads.ads_monthly_trend
SELECT
  month,
  CAST(substr(month, 6, 2) AS INT) AS month_seq,
  gmv, order_cnt, user_cnt, aov, mom_rate,
  ROUND(gmv / SUM(gmv) OVER (), 4) AS gmv_share
FROM ydsh_dws.dws_trade_month;

SELECT * FROM ydsh_ads.ads_kpi_core ORDER BY metric_code;

-- ############################################################################
-- ## [21/21] sql/ads/61_build_ads_app.sql   （137 行）
-- ############################################################################

-- =============================================================
-- 61_build_ads_app.sql
-- 作用：ADS 应用层 —— 面向具体业务场景的输出表
-- 输入：ydsh_dws.dws_trade_day / dws_category_day / dws_user_stat、ydsh_ads.ads_user_value
-- 输出：ydsh_ads.ads_sales_daily_report（销售日报）
--       ydsh_ads.ads_category_topn（品类 TopN）
--       ydsh_ads.ads_user_segment（用户价值分层汇总）
--
-- 这一层是「能直接给业务看」的表：
--   日报回答「今天怎么样」，TopN 回答「卖得最好的是什么」，
--   用户分层回答「客户结构健康吗」。三者都不再需要业务方自己 join。
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_ads;

-- =============================================================
-- 一、销售日报（含环比、周同比、7 日移动平均）
-- =============================================================
DROP TABLE IF EXISTS ydsh_ads.ads_sales_daily_report;
CREATE TABLE ydsh_ads.ads_sales_daily_report (
  dt          STRING COMMENT '日期',
  gmv         DOUBLE COMMENT '当日 GMV',
  order_cnt   BIGINT COMMENT '当日订单量',
  user_cnt    BIGINT COMMENT '当日下单用户数',
  aov         DOUBLE COMMENT '当日客单价',
  dod_rate    DOUBLE COMMENT 'GMV 日环比（对上一天）',
  wow_rate    DOUBLE COMMENT 'GMV 周同比（对 7 天前）',
  ma7_gmv     DOUBLE COMMENT '近 7 日 GMV 移动平均（含当日）'
)
COMMENT 'ADS-销售日报'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_ads.ads_sales_daily_report
SELECT
  dt, gmv, order_cnt, user_cnt, aov,
  ROUND((gmv - prev_gmv) / prev_gmv, 4)                                   AS dod_rate,
  ROUND((gmv - prev7_gmv) / prev7_gmv, 4)                                 AS wow_rate,
  ROUND(AVG(gmv) OVER (ORDER BY dt ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS ma7_gmv
FROM (
  SELECT
    dt, gmv, order_cnt, user_cnt, aov,
    LAG(gmv, 1) OVER (ORDER BY dt) AS prev_gmv,
    LAG(gmv, 7) OVER (ORDER BY dt) AS prev7_gmv
  FROM ydsh_dws.dws_trade_day
) d;

-- =============================================================
-- 二、品类 TopN（全年累计 + 占比 + 帕累托累计占比）
-- =============================================================
DROP TABLE IF EXISTS ydsh_ads.ads_category_topn;
CREATE TABLE ydsh_ads.ads_category_topn (
  rank_no         INT    COMMENT '排名（按 GMV 降序，ROW_NUMBER 保证名次唯一）',
  category        STRING COMMENT '一级品类',
  gmv             DOUBLE COMMENT '全年 GMV',
  gmv_share       DOUBLE COMMENT '占全站 GMV 比重',
  cum_share       DOUBLE COMMENT '累计占比（帕累托分析用）',
  order_cnt       BIGINT COMMENT '关联订单数',
  item_qty        BIGINT COMMENT '销售件数',
  avg_item_price  DOUBLE COMMENT '件单价 = GMV / 件数'
)
COMMENT 'ADS-品类销售 TopN'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_ads.ads_category_topn
SELECT
  rank_no, category, gmv, gmv_share, cum_share, order_cnt, item_qty,
  ROUND(gmv / item_qty, 2) AS avg_item_price
FROM (
  SELECT
    ROW_NUMBER() OVER (ORDER BY gmv DESC, category ASC)                  AS rank_no,
    category, gmv,
    ROUND(gmv / SUM(gmv) OVER (), 4)                                     AS gmv_share,
    ROUND(SUM(gmv) OVER (ORDER BY gmv DESC, category ASC
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
          / SUM(gmv) OVER (), 4)                                         AS cum_share,
    order_cnt, item_qty
  FROM (
    SELECT category, ROUND(SUM(gmv), 2) AS gmv,
           COUNT(DISTINCT dt)           AS order_cnt,
           SUM(item_qty)                AS item_qty
    FROM ydsh_dws.dws_category_day
    GROUP BY category
  ) c
) r;

-- =============================================================
-- 三、用户价值分层汇总（在 ads_user_value 的 RFM 分层之上做聚合）
-- =============================================================
DROP TABLE IF EXISTS ydsh_ads.ads_user_segment;
CREATE TABLE ydsh_ads.ads_user_segment (
  user_segment   STRING COMMENT '用户分层（RFM 组合）',
  user_cnt       BIGINT COMMENT '用户数',
  user_share     DOUBLE COMMENT '用户占比',
  gmv            DOUBLE COMMENT '分层 GMV',
  gmv_share      DOUBLE COMMENT 'GMV 占比',
  avg_gmv        DOUBLE COMMENT '人均 GMV',
  avg_order_cnt  DOUBLE COMMENT '人均订单数'
)
COMMENT 'ADS-用户价值分层汇总'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_ads.ads_user_segment
SELECT
  user_segment,
  user_cnt,
  ROUND(user_cnt / SUM(user_cnt) OVER (), 4) AS user_share,
  gmv,
  ROUND(gmv / SUM(gmv) OVER (), 4)           AS gmv_share,
  ROUND(gmv / user_cnt, 2)                   AS avg_gmv,
  ROUND(order_cnt / user_cnt, 2)             AS avg_order_cnt
FROM (
  SELECT
    user_segment,
    COUNT(*)                  AS user_cnt,
    ROUND(SUM(total_gmv), 2)  AS gmv,
    SUM(order_cnt)            AS order_cnt
  FROM ydsh_ads.ads_user_value
  GROUP BY user_segment
) s
ORDER BY gmv DESC;

-- =============================================================
-- 四、装载校验
-- =============================================================
SELECT 'ads_kpi_core'          AS tbl, COUNT(*) AS cnt FROM ydsh_ads.ads_kpi_core
UNION ALL SELECT 'ads_monthly_trend',      COUNT(*) FROM ydsh_ads.ads_monthly_trend
UNION ALL SELECT 'ads_sales_daily_report', COUNT(*) FROM ydsh_ads.ads_sales_daily_report
UNION ALL SELECT 'ads_category_topn',      COUNT(*) FROM ydsh_ads.ads_category_topn
UNION ALL SELECT 'ads_user_segment',       COUNT(*) FROM ydsh_ads.ads_user_segment;

-- 分层 GMV 合计必须等于全站 GMV（否则说明有用户没被打上标签）
SELECT
  (SELECT ROUND(SUM(gmv), 2) FROM ydsh_ads.ads_user_segment)   AS segment_gmv,
  (SELECT ROUND(SUM(gmv), 2) FROM ydsh_dws.dws_trade_day)      AS total_gmv;
