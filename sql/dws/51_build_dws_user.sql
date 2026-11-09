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
