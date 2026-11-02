-- =============================================================
-- 33_load_dws.sql
-- 作用：四层架构落地 —— DWS 汇总层（按主题轻度汇总）
-- 输入：ydsh_dwd.dwd_order / dwd_order_item / dim_*
-- 输出：ydsh_dws.dws_daily_sales / dws_store_sales / dws_category_sales
--
-- DWS 的定位：把 DWD 的「明细」按分析主题做轻度聚合，只到「日 / 门店 / 类目」
-- 这一层，不再往上拼具体报表。往上（ADS）才是面向具体看板的指标。
-- 这样做的好处是：多个看板复用同一份汇总，口径不会各自算一遍导致对不上。
--
-- 执行：bash scripts/run_sql.sh sql/dwd/33_load_dws.sql
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_dws;

-- =============================================================
-- 一、日销售汇总
-- =============================================================
DROP TABLE IF EXISTS ydsh_dws.dws_daily_sales;
CREATE TABLE ydsh_dws.dws_daily_sales (
  date_key      STRING COMMENT '日期 yyyy-MM-dd（关联 dim_date）',
  order_cnt     BIGINT COMMENT '订单量',
  user_cnt      BIGINT COMMENT '下单用户数',
  store_cnt     BIGINT COMMENT '有成交门店数',
  gmv           DOUBLE COMMENT '成交总额（实付金额合计）',
  discount_sum  DOUBLE COMMENT '优惠金额合计',
  aov           DOUBLE COMMENT '客单价 = GMV / 订单量',
  cancel_cnt    BIGINT COMMENT '取消订单数'
)
COMMENT 'DWS 汇总-日销售'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_daily_sales
SELECT
  order_date,
  COUNT(DISTINCT order_id)                                   AS order_cnt,
  COUNT(DISTINCT user_id)                                    AS user_cnt,
  COUNT(DISTINCT store_id)                                   AS store_cnt,
  ROUND(SUM(pay_amount), 2)                                  AS gmv,
  ROUND(SUM(discount_amount), 2)                             AS discount_sum,
  ROUND(SUM(pay_amount) / COUNT(DISTINCT order_id), 2)       AS aov,
  COUNT(DISTINCT CASE WHEN order_status_code = 'OS04' THEN order_id END) AS cancel_cnt
FROM ydsh_dwd.dwd_order
GROUP BY order_date;

-- =============================================================
-- 二、门店销售汇总
-- =============================================================
DROP TABLE IF EXISTS ydsh_dws.dws_store_sales;
CREATE TABLE ydsh_dws.dws_store_sales (
  store_id    STRING COMMENT '门店编号',
  store_name  STRING COMMENT '门店名称',
  province    STRING COMMENT '省份',
  city        STRING COMMENT '城市',
  order_cnt   BIGINT COMMENT '订单量',
  user_cnt    BIGINT COMMENT '下单用户数',
  gmv         DOUBLE COMMENT '成交总额',
  aov         DOUBLE COMMENT '客单价'
)
COMMENT 'DWS 汇总-门店销售'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_store_sales
SELECT
  f.store_id,
  MAX(s.store_name)                        AS store_name,
  MAX(s.province)                          AS province,
  MAX(s.city)                              AS city,
  COUNT(DISTINCT f.order_id)               AS order_cnt,
  COUNT(DISTINCT f.user_id)                AS user_cnt,
  ROUND(SUM(f.pay_amount), 2)              AS gmv,
  ROUND(SUM(f.pay_amount) / COUNT(DISTINCT f.order_id), 2) AS aov
FROM ydsh_dwd.dwd_order f
LEFT JOIN ydsh_dwd.dim_store s ON f.store_id = s.store_id
GROUP BY f.store_id;

-- =============================================================
-- 三、类目销售汇总
-- =============================================================
-- 说明：订单事实表是「订单粒度」，类目信息在明细表里，
-- 所以类目 GMV 用「单价 × 数量 × (1 - 折扣率)」在明细粒度上还原。
DROP TABLE IF EXISTS ydsh_dws.dws_category_sales;
CREATE TABLE ydsh_dws.dws_category_sales (
  category    STRING COMMENT '一级类目',
  order_cnt   BIGINT COMMENT '关联订单数',
  item_qty    BIGINT COMMENT '销售件数',
  gmv         DOUBLE COMMENT '成交金额（明细还原）',
  avg_price   DOUBLE COMMENT '件单价'
)
COMMENT 'DWS 汇总-类目销售'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

INSERT OVERWRITE TABLE ydsh_dws.dws_category_sales
SELECT
  category,
  COUNT(DISTINCT order_id)                     AS order_cnt,
  SUM(quantity)                                AS item_qty,
  ROUND(SUM(alloc_gmv), 2)                     AS gmv,
  ROUND(SUM(alloc_gmv) / SUM(quantity), 2)     AS avg_price
FROM (
  SELECT
    a.category, a.order_id, a.quantity,
    -- 按明细金额占比把订单实付金额分摊到类目，
    -- 这样各类目 GMV 之和严格等于订单表总 GMV，报表才能对上账
    f.pay_amount * a.item_amt / t.order_item_amt AS alloc_gmv
  FROM (
    SELECT i.order_id, p.category, i.quantity,
           i.quantity * i.unit_price * (1 - i.discount) AS item_amt
    FROM ydsh_dwd.dwd_order_item_clean i
    JOIN ydsh_dwd.dim_product p ON i.product_id = p.product_id
  ) a
  JOIN (
    SELECT i.order_id, SUM(i.quantity * i.unit_price * (1 - i.discount)) AS order_item_amt
    FROM ydsh_dwd.dwd_order_item_clean i
    GROUP BY i.order_id
  ) t ON a.order_id = t.order_id
  JOIN ydsh_dwd.dwd_order f ON a.order_id = f.order_id
) x
GROUP BY category;

-- =============================================================
-- 四、汇总层核对
-- =============================================================
SELECT 'dws_daily_sales' AS tbl, COUNT(*) AS cnt FROM ydsh_dws.dws_daily_sales
UNION ALL SELECT 'dws_store_sales',    COUNT(*) FROM ydsh_dws.dws_store_sales
UNION ALL SELECT 'dws_category_sales', COUNT(*) FROM ydsh_dws.dws_category_sales;

-- 汇总层与事实表的口径一致性校验（两者 GMV 必须相等，否则说明有漏算）
SELECT
  (SELECT ROUND(SUM(pay_amount), 2) FROM ydsh_dwd.dwd_order)      AS fact_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_daily_sales) AS dws_gmv,
  (SELECT ROUND(SUM(gmv), 2)        FROM ydsh_dws.dws_store_sales) AS dws_store_gmv;
