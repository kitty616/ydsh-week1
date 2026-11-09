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
