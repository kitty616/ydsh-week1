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

INSERT OVERWRITE TABLE ydsh_dws.dws_category_day
SELECT
  f.order_date                                                AS dt,
  a.category,
  COUNT(DISTINCT a.order_id)                                  AS order_cnt,
  SUM(a.quantity)                                             AS item_qty,
  ROUND(SUM(f.pay_amount * a.item_amt / t.order_item_amt), 2) AS gmv
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
GROUP BY f.order_date, a.category;

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
