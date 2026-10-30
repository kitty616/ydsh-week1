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
