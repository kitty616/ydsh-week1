-- =============================================================
-- ClickHouse 初始化脚本（容器首次启动时自动执行）
--
-- 为什么要在编排里放 ClickHouse：Hive 走 Tez，一条聚合查询要秒级到十秒级，
-- 不适合直接支撑交互式大屏。常见做法是「Hive 负责重计算与存储，
-- 结果集同步到列存做服务层」。这里用 ClickHouse 承载 ADS 结果的副本，
-- 第 4 周的压测就是拿它和 Hive 做同口径对比。
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_ads;

-- 日销售汇总（对应 Hive: ydsh_ads.ads_sales_daily_report）
CREATE TABLE IF NOT EXISTS ydsh_ads.sales_daily
(
    dt        Date,
    gmv       Float64,
    order_cnt UInt32,
    user_cnt  UInt32,
    aov       Float64
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(dt)
ORDER BY dt;

-- 月度趋势（对应 Hive: ydsh_ads.ads_monthly_trend）
CREATE TABLE IF NOT EXISTS ydsh_ads.trade_monthly
(
    month     String,
    gmv       Float64,
    order_cnt UInt32,
    user_cnt  UInt32,
    aov       Float64,
    mom_rate  Nullable(Float64)
)
ENGINE = MergeTree
ORDER BY month;

-- 品类日汇总（对应 Hive: ydsh_dws.dws_category_day）
CREATE TABLE IF NOT EXISTS ydsh_ads.category_day
(
    dt       Date,
    category String,
    gmv      Float64,
    item_qty UInt32
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(dt)
ORDER BY (category, dt);

-- 渠道日汇总（对应 Hive: ydsh_dws.dws_channel_day）
CREATE TABLE IF NOT EXISTS ydsh_ads.channel_day
(
    dt           Date,
    channel_code String,
    gmv          Float64,
    order_cnt    UInt32
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(dt)
ORDER BY (channel_code, dt);
