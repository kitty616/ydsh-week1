-- =============================================================
-- 22_split_merge_map.sql
-- 作用：数据清洗（二）· 子任务 3 —— 字段拆分合并 + 编码映射
-- 输入 / 输出：ydsh_dwd.dwd_*_clean（原地更新）
--
-- 做三件事：
--   ① 合并：order_date + order_time → order_timestamp（yyyy-MM-dd HH:mm:ss）
--   ② 合并：province + city → region（省-市，直辖市去重）
--   ③ 编码：为会员等级 / 支付方式 / 订单状态 / 渠道 / 行为类型建立码表，
--      DWD 层只存「编码」，展示层 JOIN 码表取中文名 —— 这是维度建模的标准做法，
--      好处是中文名变更时只改码表一行，不用扫全表更新。
--
-- 执行：bash scripts/run_sql.sh sql/clean/22_split_merge_map.sql
-- =============================================================

-- =============================================================
-- 一、编码映射表（码表 / 小型维度表）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_member_level;
CREATE TABLE ydsh_dwd.dim_member_level (
  member_code STRING COMMENT '会员等级编码',
  member_name STRING COMMENT '会员等级名称',
  sort_no     INT    COMMENT '等级排序（1 最低）'
) COMMENT '码表-会员等级' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_member_level VALUES
  ('ML01', '普通会员', 1),
  ('ML02', '银卡会员', 2),
  ('ML03', '金卡会员', 3),
  ('ML04', '钻石会员', 4);

DROP TABLE IF EXISTS ydsh_dwd.dim_pay_type;
CREATE TABLE ydsh_dwd.dim_pay_type (
  pay_code STRING COMMENT '支付方式编码',
  pay_name STRING COMMENT '支付方式名称'
) COMMENT '码表-支付方式' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_pay_type VALUES
  ('PT01', '微信支付'),
  ('PT02', '支付宝'),
  ('PT03', '银行卡'),
  ('PT04', '货到付款'),
  ('PT99', '其他');

DROP TABLE IF EXISTS ydsh_dwd.dim_order_status;
CREATE TABLE ydsh_dwd.dim_order_status (
  status_code STRING COMMENT '订单状态编码',
  status_name STRING COMMENT '订单状态名称',
  is_finished INT    COMMENT '是否终态（1 是 0 否）'
) COMMENT '码表-订单状态' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_order_status VALUES
  ('OS01', '待支付', 0),
  ('OS02', '已支付', 0),
  ('OS03', '已完成', 1),
  ('OS04', '已取消', 1),
  ('OS05', '退款中', 0),
  ('OS99', '未知',   0);

DROP TABLE IF EXISTS ydsh_dwd.dim_channel;
CREATE TABLE ydsh_dwd.dim_channel (
  channel_code STRING COMMENT '渠道编码',
  channel_name STRING COMMENT '渠道名称'
) COMMENT '码表-下单渠道' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_channel VALUES
  ('CH01', '门店'),
  ('CH02', 'APP'),
  ('CH03', '小程序'),
  ('CH04', 'PC官网'),
  ('CH99', '其他');

DROP TABLE IF EXISTS ydsh_dwd.dim_behavior_type;
CREATE TABLE ydsh_dwd.dim_behavior_type (
  behavior_code STRING COMMENT '行为类型编码',
  behavior_name STRING COMMENT '行为类型名称'
) COMMENT '码表-用户行为类型' STORED AS ORC;

INSERT INTO ydsh_dwd.dim_behavior_type VALUES
  ('BT01', '浏览'),
  ('BT02', '加购'),
  ('BT03', '收藏'),
  ('BT04', '购买'),
  ('BT99', '其他');

-- =============================================================
-- 二、dwd_order_clean —— 合并时间戳 + 打上编码
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_order;
CREATE TABLE ydsh_dwd.stg_order STORED AS ORC AS
SELECT
  o.order_id,
  o.user_id,
  o.store_id,
  o.order_date,

  -- 拆出来的时间部分保留原字段，便于回溯
  o.order_time,

  -- ① 合并成完整时间戳，为时间维度建模与窗口函数排序做准备
  CONCAT(o.order_date, ' ', o.order_time) AS order_timestamp,

  o.pay_amount,
  o.discount_amount,

  COALESCE(p.pay_code, 'PT99')         AS pay_type_code,
  o.pay_type                           AS pay_type_name,   -- 保留中文名，方便直接查数

  COALESCE(s.status_code, 'OS99')      AS order_status_code,
  o.order_status                       AS order_status_name,

  COALESCE(c.channel_code, 'CH99')     AS channel_code,
  o.channel                            AS channel_name

FROM ydsh_dwd.dwd_order_clean o
LEFT JOIN ydsh_dwd.dim_pay_type     p ON o.pay_type     = p.pay_name
LEFT JOIN ydsh_dwd.dim_order_status s ON o.order_status = s.status_name
LEFT JOIN ydsh_dwd.dim_channel      c ON o.channel      = c.channel_name;

DROP TABLE ydsh_dwd.dwd_order_clean;
ALTER TABLE ydsh_dwd.stg_order RENAME TO ydsh_dwd.dwd_order_clean;

-- =============================================================
-- 三、dwd_user_clean —— 省 + 市 合并为 region，打上会员等级编码
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_user;
CREATE TABLE ydsh_dwd.stg_user STORED AS ORC AS
SELECT
  u.user_id,
  u.user_name,
  u.gender,
  u.age,
  u.city,
  u.province,

  -- ② 省 + 市 合并为大区字段：直辖市（省=市）只保留一个，避免「重庆-重庆」
  CASE
    -- 直辖市/省直管市：province 形如「重庆市」而 city 为「重庆」，用前缀匹配去重
    WHEN u.province = u.city OR u.province LIKE CONCAT(u.city, '%') THEN u.province
    WHEN u.province IS NULL OR u.province = '' THEN u.city
    WHEN u.city IS NULL OR u.city = '' THEN u.province
    ELSE CONCAT(u.province, '-', u.city)
  END AS region,

  u.register_date,

  COALESCE(m.member_code, 'ML01') AS member_level_code,
  u.member_level                  AS member_level_name,
  u.member_level_flag,

  u.phone, u.phone_flag, u.email, u.email_flag

FROM ydsh_dwd.dwd_user_clean u
LEFT JOIN ydsh_dwd.dim_member_level m ON u.member_level = m.member_name;

DROP TABLE ydsh_dwd.dwd_user_clean;
ALTER TABLE ydsh_dwd.stg_user RENAME TO ydsh_dwd.dwd_user_clean;

-- =============================================================
-- 四、dwd_user_behavior_clean —— 打上行为类型编码
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.stg_behavior;
CREATE TABLE ydsh_dwd.stg_behavior STORED AS ORC AS
SELECT
  b.behavior_id, b.user_id, b.product_id,
  COALESCE(t.behavior_code, 'BT99') AS behavior_type_code,
  b.behavior_type                   AS behavior_type_name,
  b.behavior_time,
  -- 从时间戳拆出日期与小时，供后续时段分析使用
  SUBSTR(b.behavior_time, 1, 10)    AS behavior_date,
  SUBSTR(b.behavior_time, 12, 2)    AS behavior_hour,
  b.session_id
FROM ydsh_dwd.dwd_user_behavior_clean b
LEFT JOIN ydsh_dwd.dim_behavior_type t ON b.behavior_type = t.behavior_name;

DROP TABLE ydsh_dwd.dwd_user_behavior_clean;
ALTER TABLE ydsh_dwd.stg_behavior RENAME TO ydsh_dwd.dwd_user_behavior_clean;

-- =============================================================
-- 五、验证
-- =============================================================
-- ① 时间戳格式是否全部合规
SELECT 'order_timestamp 格式合规' AS item,
       SUM(CASE WHEN order_timestamp RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' THEN 1 ELSE 0 END) AS ok_cnt,
       COUNT(*) AS total
FROM ydsh_dwd.dwd_order_clean;

-- ② 编码是否有未命中（应为 0）
SELECT 'order 编码未命中' AS item, COUNT(*) AS unmapped
FROM ydsh_dwd.dwd_order_clean
WHERE pay_type_code = 'PT99' OR order_status_code = 'OS99' OR channel_code = 'CH99'
UNION ALL
SELECT 'user 编码未命中', COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE member_level_code = 'ML01' AND member_level_flag = '未识别'
UNION ALL
SELECT 'behavior 编码未命中', COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean WHERE behavior_type_code = 'BT99';

-- ③ region 抽样
SELECT region, COUNT(*) AS user_cnt
FROM ydsh_dwd.dwd_user_clean
GROUP BY region
ORDER BY user_cnt DESC
LIMIT 10;
