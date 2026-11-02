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
