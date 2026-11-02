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
