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
