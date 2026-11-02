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
