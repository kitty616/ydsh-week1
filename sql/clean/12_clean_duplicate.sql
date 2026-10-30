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
