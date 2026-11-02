-- =============================================================
-- 31_create_fact_order.sql
-- 作用：子任务 6 —— 订单事实表建模（星型模型的「心」）
-- 输出：
--   ydsh_dwd.dwd_order         订单事实表（按 order_date 分区）
--   ydsh_dwd.dwd_order_bucket  分桶表示例（按 user_id 哈希分 8 桶）
--
-- 为什么事实表按 order_date 分区：
--   ① 业务查询几乎都带时间范围（日报、月报、同环比），分区裁剪能直接跳过无关目录；
--   ② 按天分区粒度与 DWS 日汇总对齐，重跑某一天只需覆盖单个分区；
--   ③ 不用月份分区，是因为本项目数据量虽小但查询都按天切片，
--      月分区会让单分区过大、失去裁剪收益。
--
-- 为什么额外做一个分桶表：
--   分桶 = 按 user_id 哈希把数据切成固定份数，相同 user_id 必落同一桶。
--   当事实表需要按 user_id 做 JOIN（例如关联 dim_user 或做用户级窗口计算）时，
--   桶对桶的 Map 端连接可以省掉一轮全量 Shuffle。
--   本表用于演示与对比，主事实表仍保持「分区 + ORC」的最简组合。
--
-- 执行：bash scripts/run_sql.sh sql/dwd/31_create_fact_order.sql
-- =============================================================

-- =============================================================
-- 一、订单事实表（分区表）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_order;
CREATE TABLE ydsh_dwd.dwd_order (
  order_id          STRING COMMENT '订单编号（主键，已去重）',
  user_id           STRING COMMENT '用户编号（外键 → dim_user.user_id）',
  store_id          STRING COMMENT '门店编号（外键 → dim_store.store_id）',
  order_timestamp   STRING COMMENT '下单时间戳 yyyy-MM-dd HH:mm:ss',
  pay_amount        DOUBLE COMMENT '实付金额（度量）',
  discount_amount   DOUBLE COMMENT '优惠金额（度量）',
  pay_type_code     STRING COMMENT '支付方式编码（外键 → dim_pay_type.pay_code）',
  order_status_code STRING COMMENT '订单状态编码（外键 → dim_order_status.status_code）',
  channel_code      STRING COMMENT '渠道编码（外键 → dim_channel.channel_code）',
  order_cnt         INT    COMMENT '订单笔数恒为 1（度量，便于求和口径统一）'
)
COMMENT 'DWD 事实表-订单（星型模型核心，按日分区）'
PARTITIONED BY (order_date STRING COMMENT '下单日期 yyyy-MM-dd（同时是 dim_date 外键）')
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- =============================================================
-- 二、分桶表示例（按 user_id 分 8 桶）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_order_bucket;
CREATE TABLE ydsh_dwd.dwd_order_bucket (
  order_id          STRING COMMENT '订单编号',
  user_id           STRING COMMENT '用户编号（分桶键）',
  store_id          STRING COMMENT '门店编号',
  order_date        STRING COMMENT '下单日期',
  order_timestamp   STRING COMMENT '下单时间戳',
  pay_amount        DOUBLE COMMENT '实付金额',
  discount_amount   DOUBLE COMMENT '优惠金额',
  pay_type_code     STRING COMMENT '支付方式编码',
  order_status_code STRING COMMENT '订单状态编码',
  channel_code      STRING COMMENT '渠道编码'
)
COMMENT 'DWD 订单事实表-分桶版（演示 user_id 哈希分桶，供 Map 端连接用）'
CLUSTERED BY (user_id) INTO 8 BUCKETS
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 开启分桶写入（Hive 2+ 默认已开，显式声明避免环境差异）
SET hive.enforce.bucketing = true;
SET hive.exec.dynamic.partition = true;
SET hive.exec.dynamic.partition.mode = nonstrict;

SELECT 'fact tables created' AS status,
       'dwd_order(partitioned) + dwd_order_bucket(8 buckets)' AS detail;
