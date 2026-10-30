-- =============================================================
-- 10_quality_assessment.sql
-- 作用：对 6 张 ODS 表做五维度数据质量预评估，结果写入 ydsh_dwd.dq_report
-- 五维度：
--   完整性 Completeness —— 字段是否为空
--   唯一性 Uniqueness   —— 主键是否重复 / 整行是否重复
--   有效性 Validity     —— 枚举取值是否在合法集合内
--   一致性 Consistency  —— 格式是否统一（日期 / 手机号 / 大小写）
--   准确性 Accuracy     —— 数值是否在业务合理区间
-- 结果：执行完成后直接查 dq_report 即可，无需再手工汇总
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 10_quality_assessment.sql
-- =============================================================

-- -------------------------------------------------------------
-- 环境说明（重要）
-- Tez / MR 默认 mapreduce.job.counters.max = 120，
-- 而本脚本单条 INSERT 内含 8 个 UNION ALL 分支，计数器会超过上限，报：
--   Counters limit exceeded: Too many counters: 121 max=120
--
-- 该上限必须在 HiveServer2 启动时读取，运行期 SET 或在 beeline 启动参数里
-- 注入 --hiveconf 都无效。已通过 conf/hive-site.xml 挂载覆盖容器默认配置：
--   mapreduce.job.counters.max        = 4000
--   mapreduce.job.counters.groups.max = 4000
--   tez.counters.max                  = 4000
-- 若重装环境，请确认 docker-compose.yml 中 hive-server 的
-- ./conf/hive-site.xml 挂载存在，否则本脚本会报上述错误。
-- -------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS ydsh_dwd;

DROP TABLE IF EXISTS ydsh_dwd.dq_report;
CREATE TABLE ydsh_dwd.dq_report (
  table_name  STRING COMMENT '表名',
  dimension   STRING COMMENT '质量维度',
  metric      STRING COMMENT '检查项',
  total_cnt   BIGINT COMMENT '总行数',
  bad_cnt     BIGINT COMMENT '问题行数',
  bad_ratio   DOUBLE COMMENT '问题占比'
)
COMMENT '数据质量预评估汇总表'
STORED AS ORC;

-- =============================================================
-- 一、ods_user（用户信息表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
-- 完整性
SELECT 'ods_user','完整性','age 为空',
       COUNT(*),
       SUM(CASE WHEN age IS NULL OR TRIM(age)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN age IS NULL OR TRIM(age)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'ods_user','完整性','email 为空',
       COUNT(*),
       SUM(CASE WHEN email IS NULL OR TRIM(email)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN email IS NULL OR TRIM(email)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
-- 唯一性
UNION ALL
SELECT 'ods_user','唯一性','user_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT user_id),
       ROUND((COUNT(*) - COUNT(DISTINCT user_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
-- 有效性
UNION ALL
SELECT 'ods_user','有效性','gender 取值非法(含空)',
       COUNT(*),
       SUM(CASE WHEN gender IS NULL OR TRIM(gender)=''
                 OR LOWER(TRIM(gender)) NOT IN ('男','女','m','f','male','female','未知') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN gender IS NULL OR TRIM(gender)=''
                 OR LOWER(TRIM(gender)) NOT IN ('男','女','m','f','male','female','未知') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'ods_user','有效性','member_level 中英文混用/非法',
       COUNT(*),
       SUM(CASE WHEN member_level IS NULL OR TRIM(member_level)=''
                 OR LOWER(TRIM(member_level)) NOT IN ('普通','银卡','金卡','钻石','normal','silver','gold','diamond','普通会员','银卡会员','金卡会员','钻石会员') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN member_level IS NULL OR TRIM(member_level)=''
                 OR LOWER(TRIM(member_level)) NOT IN ('普通','银卡','金卡','钻石','normal','silver','gold','diamond','普通会员','银卡会员','金卡会员','钻石会员') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
-- 一致性
UNION ALL
SELECT 'ods_user','一致性','register_date 非 yyyy-MM-dd',
       COUNT(*),
       SUM(CASE WHEN register_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN register_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'ods_user','一致性','phone 去掉非数字后不是 11 位',
       COUNT(*),
       SUM(CASE WHEN REGEXP_REPLACE(phone,'[^0-9]','') NOT RLIKE '^[0-9]{11}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN REGEXP_REPLACE(phone,'[^0-9]','') NOT RLIKE '^[0-9]{11}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user
-- 准确性
UNION ALL
SELECT 'ods_user','准确性','age 超出 1~120 区间',
       COUNT(*),
       SUM(CASE WHEN age IS NOT NULL AND TRIM(age)<>'' AND age RLIKE '^-?[0-9]+$'
                 AND (CAST(age AS INT) < 1 OR CAST(age AS INT) > 120) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN age IS NOT NULL AND TRIM(age)<>'' AND age RLIKE '^-?[0-9]+$'
                 AND (CAST(age AS INT) < 1 OR CAST(age AS INT) > 120) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user;

-- =============================================================
-- 二、ods_product（商品信息表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_product','完整性','launch_date 为空',
       COUNT(*),
       SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN launch_date IS NULL OR TRIM(launch_date)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','唯一性','product_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT product_id),
       ROUND((COUNT(*) - COUNT(DISTINCT product_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','有效性','status 不在 在售/下架/缺货 之内',
       COUNT(*),
       SUM(CASE WHEN status IS NULL OR TRIM(status) NOT IN ('在售','下架','缺货') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN status IS NULL OR TRIM(status) NOT IN ('在售','下架','缺货') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','一致性','category 含首尾空格或大小写不统一',
       COUNT(*),
       SUM(CASE WHEN category IS NULL OR category <> TRIM(category)
                 OR TRIM(category) <> LOWER(TRIM(category)) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN category IS NULL OR category <> TRIM(category)
                 OR TRIM(category) <> LOWER(TRIM(category)) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','准确性','price 为负或 >= 100000',
       COUNT(*),
       SUM(CASE WHEN CAST(price AS DOUBLE) <= 0 OR CAST(price AS DOUBLE) >= 100000 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(price AS DOUBLE) <= 0 OR CAST(price AS DOUBLE) >= 100000 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product
UNION ALL
SELECT 'ods_product','准确性','cost 大于 price',
       COUNT(*),
       SUM(CASE WHEN CAST(cost AS DOUBLE) > CAST(price AS DOUBLE) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(cost AS DOUBLE) > CAST(price AS DOUBLE) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_product;

-- =============================================================
-- 三、ods_store（门店信息表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_store','完整性','manager 为空',
       COUNT(*),
       SUM(CASE WHEN manager IS NULL OR TRIM(manager)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN manager IS NULL OR TRIM(manager)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_store
UNION ALL
SELECT 'ods_store','唯一性','store_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT store_id),
       ROUND((COUNT(*) - COUNT(DISTINCT store_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_store
UNION ALL
SELECT 'ods_store','一致性','open_date 非 yyyy-MM-dd',
       COUNT(*),
       SUM(CASE WHEN open_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN open_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_store
UNION ALL
SELECT 'ods_store','准确性','area 非正数或 > 100000',
       COUNT(*),
       SUM(CASE WHEN CAST(area AS INT) <= 0 OR CAST(area AS INT) > 100000 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(area AS INT) <= 0 OR CAST(area AS INT) > 100000 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_store;

-- =============================================================
-- 四、ods_order（订单主表，重点）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_order','完整性','pay_amount 为空',
       COUNT(*),
       SUM(CASE WHEN pay_amount IS NULL OR TRIM(pay_amount)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN pay_amount IS NULL OR TRIM(pay_amount)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','唯一性','order_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT order_id),
       ROUND((COUNT(*) - COUNT(DISTINCT order_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','唯一性','整行完全重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT CONCAT_WS('|', order_id, user_id, store_id, order_date,
                                           order_time, pay_amount, discount_amount,
                                           pay_type, order_status, channel)),
       ROUND((COUNT(*) - COUNT(DISTINCT CONCAT_WS('|', order_id, user_id, store_id, order_date,
                                           order_time, pay_amount, discount_amount,
                                           pay_type, order_status, channel)))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','有效性','order_status 不在合法枚举内',
       COUNT(*),
       SUM(CASE WHEN LOWER(TRIM(order_status)) NOT IN ('已完成','已取消','待付款','已发货','待发货','退款中','completed','cancelled','canceled','pending','paid','shipped','refunding','1','0') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN LOWER(TRIM(order_status)) NOT IN ('已完成','已取消','待付款','已发货','待发货','退款中','completed','cancelled','canceled','pending','paid','shipped','refunding','1','0') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','有效性','pay_type 不在合法枚举内',
       COUNT(*),
       SUM(CASE WHEN LOWER(TRIM(pay_type)) NOT IN ('微信支付','支付宝','银行卡','现金','wechat','alipay','card','cash') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN LOWER(TRIM(pay_type)) NOT IN ('微信支付','支付宝','银行卡','现金','wechat','alipay','card','cash') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','一致性','order_date 非 yyyy-MM-dd',
       COUNT(*),
       SUM(CASE WHEN order_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN order_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','一致性','channel 大小写不统一',
       COUNT(*),
       SUM(CASE WHEN channel IS NULL OR TRIM(channel) <> LOWER(TRIM(channel)) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN channel IS NULL OR TRIM(channel) <> LOWER(TRIM(channel)) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','准确性','pay_amount 为负',
       COUNT(*),
       SUM(CASE WHEN CAST(pay_amount AS DOUBLE) < 0 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(pay_amount AS DOUBLE) < 0 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','准确性','pay_amount 异常高价(> 1000000)',
       COUNT(*),
       SUM(CASE WHEN CAST(pay_amount AS DOUBLE) > 1000000 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(pay_amount AS DOUBLE) > 1000000 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'ods_order','准确性','discount_amount 大于 pay_amount',
       COUNT(*),
       SUM(CASE WHEN CAST(discount_amount AS DOUBLE) > CAST(pay_amount AS DOUBLE) THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(discount_amount AS DOUBLE) > CAST(pay_amount AS DOUBLE) THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order;

-- =============================================================
-- 五、ods_order_item（订单明细表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_order_item','完整性','unit_price 为空',
       COUNT(*),
       SUM(CASE WHEN unit_price IS NULL OR TRIM(unit_price)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN unit_price IS NULL OR TRIM(unit_price)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item
UNION ALL
SELECT 'ods_order_item','唯一性','item_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT item_id),
       ROUND((COUNT(*) - COUNT(DISTINCT item_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item
UNION ALL
SELECT 'ods_order_item','有效性','discount 不在 0~1 区间',
       COUNT(*),
       SUM(CASE WHEN CAST(discount AS DOUBLE) < 0 OR CAST(discount AS DOUBLE) > 1 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(discount AS DOUBLE) < 0 OR CAST(discount AS DOUBLE) > 1 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item
UNION ALL
SELECT 'ods_order_item','准确性','quantity <= 0',
       COUNT(*),
       SUM(CASE WHEN CAST(quantity AS INT) <= 0 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(quantity AS INT) <= 0 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item
UNION ALL
SELECT 'ods_order_item','准确性','quantity 超大(>= 50)',
       COUNT(*),
       SUM(CASE WHEN CAST(quantity AS INT) >= 50 THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN CAST(quantity AS INT) >= 50 THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_order_item;

-- =============================================================
-- 六、ods_user_behavior（用户行为日志表）
-- =============================================================
INSERT INTO ydsh_dwd.dq_report
SELECT 'ods_user_behavior','完整性','session_id 为空',
       COUNT(*),
       SUM(CASE WHEN session_id IS NULL OR TRIM(session_id)='' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN session_id IS NULL OR TRIM(session_id)='' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user_behavior
UNION ALL
SELECT 'ods_user_behavior','唯一性','behavior_id 重复的多余行数',
       COUNT(*),
       COUNT(*) - COUNT(DISTINCT behavior_id),
       ROUND((COUNT(*) - COUNT(DISTINCT behavior_id))*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user_behavior
UNION ALL
SELECT 'ods_user_behavior','有效性','behavior_type 中英文混用/非法',
       COUNT(*),
       SUM(CASE WHEN LOWER(TRIM(behavior_type)) NOT IN ('pv','cart','fav','buy','浏览','加购','收藏','购买') THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN LOWER(TRIM(behavior_type)) NOT IN ('pv','cart','fav','buy','浏览','加购','收藏','购买') THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user_behavior
UNION ALL
SELECT 'ods_user_behavior','一致性','behavior_time 非 yyyy-MM-dd HH:mm:ss',
       COUNT(*),
       SUM(CASE WHEN behavior_time NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN 1 ELSE 0 END),
       ROUND(SUM(CASE WHEN behavior_time NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN 1 ELSE 0 END)*1.0/COUNT(*),4)
FROM ydsh_ods.ods_user_behavior;

-- =============================================================
-- 查看评估结果
-- =============================================================
SELECT table_name, dimension, metric, total_cnt, bad_cnt, bad_ratio
FROM ydsh_dwd.dq_report
ORDER BY table_name, dimension, metric;
