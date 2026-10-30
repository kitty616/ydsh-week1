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
