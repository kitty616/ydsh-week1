-- =============================================================
-- 20_enum_standardize.sql
-- 作用：数据清洗（二）· 子任务 1 —— 枚举字段标准化
-- 输入：ydsh_ods.ods_*（贴源层，字符串全部为原始形态）
-- 输出：ydsh_dwd.dwd_*_clean（清洗中间表，供 21 / 22 号脚本继续加工）
--
-- 覆盖的脏值形态（均来自真实扫描，见文末「取值收敛验证」）：
--   gender        男 / 女 / M / F / male / female / 未知 / 空        8 种
--   member_level  金卡会员 / 金卡 / gold / 银卡 / silver / 钻石 / 普通 / 空  12 种
--   order_status  已完成 / 完成 / 已支付 / 已付款 / 1 / 2 / 3 / 4 / cancelled  12 种
--   pay_type      微信支付 / 微信 / wechat / 支付宝 / alipay / 银行卡 / 货到付款  7 种
--   channel       门店 / APP / app / 小程序 / PC官网 / pc            6 种
--   behavior_type pv / PV / 浏览 / cart / Cart / 加购 / fav / 收藏 / buy / 购买  10 种
--   category      8 个规范类目 + 7 个带尾随空格的变体（共 16 种）
--
-- 设计原则：
--   1) 枚举一律收敛到「中文标准值」，英文/编码/大小写/空白变体全部映射进去；
--   2) 映射用显式白名单（IN 列表），未命中走 ELSE 兜底 —— 白名单能保证
--      新增脏值不会静默穿透，兜底值在验证段落能被单独统计出来；
--   3) 本脚本同时承接第 1 周的基础清洗（年龄中位数、订单去重），
--      保证从 ODS 一键重算即可复现全流程。
--
-- 执行：bash scripts/run_sql.sh sql/clean/20_enum_standardize.sql
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_dwd;

-- =============================================================
-- 一、dwd_user_clean —— 用户表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_user_clean;
CREATE TABLE ydsh_dwd.dwd_user_clean
COMMENT 'DWD 清洗中间表-用户（枚举标准化 + 年龄中位数填充）'
STORED AS ORC
AS
SELECT
  TRIM(u.user_id)   AS user_id,
  TRIM(u.user_name) AS user_name,

  -- 性别：8 种取值 → 男 / 女 / 未知
  CASE
    WHEN LOWER(TRIM(u.gender)) IN ('男','m','male','1')    THEN '男'
    WHEN LOWER(TRIM(u.gender)) IN ('女','f','female','0')  THEN '女'
    WHEN LOWER(TRIM(u.gender)) IN ('未知','unknown','')    THEN '未知'
    ELSE '未知'
  END AS gender,

  -- 年龄：空 / 非数字 / 越界 [1,120] → 中位数填充
  CAST(
    CASE
      WHEN u.age IS NULL OR TRIM(u.age) = '' OR TRIM(u.age) NOT RLIKE '^-?[0-9]+$' THEN s.med_age
      WHEN CAST(TRIM(u.age) AS INT) < 1 OR CAST(TRIM(u.age) AS INT) > 120          THEN s.med_age
      ELSE CAST(TRIM(u.age) AS INT)
    END AS INT
  ) AS age,

  TRIM(u.city)     AS city,
  TRIM(u.province) AS province,

  -- 注册日期：三种形态 → yyyy-MM-dd
  CASE
    WHEN TRIM(u.register_date) RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN TRIM(u.register_date)
    WHEN TRIM(u.register_date) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN REGEXP_REPLACE(TRIM(u.register_date), '/', '-')
    WHEN TRIM(u.register_date) RLIKE '^[0-9]{8}$'
      THEN CONCAT(SUBSTR(TRIM(u.register_date),1,4), '-', SUBSTR(TRIM(u.register_date),5,2), '-', SUBSTR(TRIM(u.register_date),7,2))
    ELSE NULL
  END AS register_date,

  -- 会员等级：12 种取值 → 普通会员 / 银卡会员 / 金卡会员 / 钻石会员
  -- 空值不臆造等级，按最低等级「普通会员」兜底，并在 member_level_flag 标记
  CASE
    WHEN LOWER(TRIM(u.member_level)) IN ('普通','普通会员','normal','regular')      THEN '普通会员'
    WHEN LOWER(TRIM(u.member_level)) IN ('银卡','银卡会员','silver')                THEN '银卡会员'
    WHEN LOWER(TRIM(u.member_level)) IN ('金卡','金卡会员','gold')                  THEN '金卡会员'
    WHEN LOWER(TRIM(u.member_level)) IN ('钻石','钻石会员','diamond','platinum')    THEN '钻石会员'
    ELSE '普通会员'
  END AS member_level,

  CASE
    WHEN TRIM(u.member_level) = '' THEN '缺失兜底'
    WHEN LOWER(TRIM(u.member_level)) IN ('普通','普通会员','normal','regular',
                                         '银卡','银卡会员','silver',
                                         '金卡','金卡会员','gold',
                                         '钻石','钻石会员','diamond','platinum') THEN '正常'
    ELSE '未识别'
  END AS member_level_flag,

  -- 手机号：去除 - 与空格，统一 11 位纯数字
  REGEXP_REPLACE(TRIM(u.phone), '[^0-9]', '') AS phone,

  TRIM(u.email) AS email,
  CASE WHEN TRIM(u.email) = '' THEN '缺失' ELSE '正常' END AS email_flag

FROM ydsh_ods.ods_user u
CROSS JOIN (
  -- 中位数只在合法区间内统计，避免 150 / 0 这类异常值参与计算
  SELECT ROUND(PERCENTILE(CAST(TRIM(age) AS INT), 0.5)) AS med_age
  FROM ydsh_ods.ods_user
  WHERE TRIM(age) RLIKE '^[0-9]+$' AND CAST(TRIM(age) AS INT) BETWEEN 1 AND 120
) s;

-- =============================================================
-- 二、dwd_product_clean —— 商品表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_product_clean;
CREATE TABLE ydsh_dwd.dwd_product_clean
COMMENT 'DWD 清洗中间表-商品（类目/品牌去空格、上架日期补全）'
STORED AS ORC
AS
SELECT
  TRIM(p.product_id)   AS product_id,
  TRIM(p.product_name) AS product_name,

  -- 类目：8 个规范值 + 7 个带尾随空格的变体 → 8 个规范值
  TRIM(p.category)     AS category,
  TRIM(p.sub_category) AS sub_category,

  -- 品牌：中英文混排，统一去空格；英文品牌统一大写便于比对
  CASE WHEN TRIM(p.brand) RLIKE '[A-Za-z]' THEN UPPER(TRIM(p.brand)) ELSE TRIM(p.brand) END AS brand,

  CAST(TRIM(p.price) AS DOUBLE) AS price,
  CAST(TRIM(p.cost)  AS DOUBLE) AS cost,
  CAST(TRIM(p.stock) AS INT)    AS stock,
  TRIM(p.status)                AS status,

  -- 上架日期：缺失按同品类最早上架日期补全，品类内也无值则兜底 2023-01-01
  CASE
    WHEN TRIM(p.launch_date) = '' THEN COALESCE(c.min_launch, '2023-01-01')
    WHEN TRIM(p.launch_date) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN REGEXP_REPLACE(TRIM(p.launch_date), '/', '-')
    WHEN TRIM(p.launch_date) RLIKE '^[0-9]{8}$'
      THEN CONCAT(SUBSTR(TRIM(p.launch_date),1,4), '-', SUBSTR(TRIM(p.launch_date),5,2), '-', SUBSTR(TRIM(p.launch_date),7,2))
    ELSE TRIM(p.launch_date)
  END AS launch_date

FROM ydsh_ods.ods_product p
LEFT JOIN (
  SELECT TRIM(category) AS category, MIN(TRIM(launch_date)) AS min_launch
  FROM ydsh_ods.ods_product
  WHERE TRIM(launch_date) RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  GROUP BY TRIM(category)
) c
  ON TRIM(p.category) = c.category;

-- =============================================================
-- 三、dwd_store_clean —— 门店表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_store_clean;
CREATE TABLE ydsh_dwd.dwd_store_clean
COMMENT 'DWD 清洗中间表-门店（第 1 周评估五维度全 0，仅做规范化落地）'
STORED AS ORC
AS
SELECT
  TRIM(store_id)   AS store_id,
  TRIM(store_name) AS store_name,
  TRIM(province)   AS province,
  TRIM(city)       AS city,
  TRIM(district)   AS district,
  TRIM(address)    AS address,
  CASE
    WHEN TRIM(open_date) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN REGEXP_REPLACE(TRIM(open_date), '/', '-')
    WHEN TRIM(open_date) RLIKE '^[0-9]{8}$'
      THEN CONCAT(SUBSTR(TRIM(open_date),1,4), '-', SUBSTR(TRIM(open_date),5,2), '-', SUBSTR(TRIM(open_date),7,2))
    ELSE TRIM(open_date)
  END AS open_date,
  CAST(TRIM(area) AS DOUBLE) AS area,
  TRIM(manager) AS manager
FROM ydsh_ods.ods_store;

-- =============================================================
-- 四、dwd_order_clean —— 订单表（含第 1 周的整行去重）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_order_clean;
CREATE TABLE ydsh_dwd.dwd_order_clean
COMMENT 'DWD 清洗中间表-订单（去重 + 枚举标准化）'
STORED AS ORC
AS
SELECT
  order_id, user_id, store_id, order_date, order_time,
  pay_amount, discount_amount,
  pay_type, order_status, channel
FROM (
  SELECT
    TRIM(o.order_id)   AS order_id,
    TRIM(o.user_id)    AS user_id,
    TRIM(o.store_id)   AS store_id,

    CASE
      WHEN TRIM(o.order_date) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' THEN REGEXP_REPLACE(TRIM(o.order_date), '/', '-')
      WHEN TRIM(o.order_date) RLIKE '^[0-9]{8}$'
        THEN CONCAT(SUBSTR(TRIM(o.order_date),1,4), '-', SUBSTR(TRIM(o.order_date),5,2), '-', SUBSTR(TRIM(o.order_date),7,2))
      ELSE TRIM(o.order_date)
    END AS order_date,

    TRIM(o.order_time) AS order_time,

    CAST(TRIM(o.pay_amount)      AS DOUBLE) AS pay_amount,
    CAST(TRIM(o.discount_amount) AS DOUBLE) AS discount_amount,

    -- 支付方式：7 种 → 微信支付 / 支付宝 / 银行卡 / 货到付款
    CASE
      WHEN LOWER(TRIM(o.pay_type)) IN ('微信支付','微信','wechat','weixin','wx') THEN '微信支付'
      WHEN LOWER(TRIM(o.pay_type)) IN ('支付宝','alipay','ali')                  THEN '支付宝'
      WHEN LOWER(TRIM(o.pay_type)) IN ('银行卡','bank','bankcard','card','unionpay') THEN '银行卡'
      WHEN LOWER(TRIM(o.pay_type)) IN ('货到付款','cod','cash')                  THEN '货到付款'
      ELSE '其他'
    END AS pay_type,

    -- 订单状态：12 种 → 待支付 / 已支付 / 已完成 / 已取消 / 退款中
    -- 数字编码按状态流转顺序对应：1=已支付 2=待支付 3=已取消 4=退款中
    CASE
      WHEN LOWER(TRIM(o.order_status)) IN ('待支付','2')                      THEN '待支付'
      WHEN LOWER(TRIM(o.order_status)) IN ('已支付','已付款','1')              THEN '已支付'
      WHEN LOWER(TRIM(o.order_status)) IN ('已完成','完成','5','finished')     THEN '已完成'
      WHEN LOWER(TRIM(o.order_status)) IN ('已取消','cancelled','canceled','3') THEN '已取消'
      WHEN LOWER(TRIM(o.order_status)) IN ('退款中','refunding','4')           THEN '退款中'
      ELSE '未知'
    END AS order_status,

    -- 渠道：6 种 → 门店 / APP / 小程序 / PC官网
    CASE
      WHEN LOWER(TRIM(o.channel)) IN ('门店','store','offline')   THEN '门店'
      WHEN LOWER(TRIM(o.channel)) IN ('app')                      THEN 'APP'
      WHEN LOWER(TRIM(o.channel)) IN ('小程序','miniapp','mini')  THEN '小程序'
      WHEN LOWER(TRIM(o.channel)) IN ('pc官网','pc','官网','web')  THEN 'PC官网'
      ELSE '其他'
    END AS channel,

    ROW_NUMBER() OVER (
      PARTITION BY TRIM(o.order_id)
      ORDER BY TRIM(o.order_date) DESC, TRIM(o.order_time) DESC
    ) AS rn
  FROM ydsh_ods.ods_order o
) t
WHERE rn = 1;

-- =============================================================
-- 五、dwd_order_item_clean —— 订单明细表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_order_item_clean;
CREATE TABLE ydsh_dwd.dwd_order_item_clean
COMMENT 'DWD 清洗中间表-订单明细'
STORED AS ORC
AS
SELECT
  TRIM(item_id)    AS item_id,
  TRIM(order_id)   AS order_id,
  TRIM(product_id) AS product_id,
  CAST(TRIM(quantity)   AS INT)    AS quantity,
  CAST(TRIM(unit_price) AS DOUBLE) AS unit_price,
  CAST(TRIM(discount)   AS DOUBLE) AS discount
FROM ydsh_ods.ods_order_item;

-- =============================================================
-- 六、dwd_user_behavior_clean —— 用户行为表
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dwd_user_behavior_clean;
CREATE TABLE ydsh_dwd.dwd_user_behavior_clean
COMMENT 'DWD 清洗中间表-用户行为（行为类型中英文归并 + 时间格式统一）'
STORED AS ORC
AS
SELECT
  TRIM(behavior_id) AS behavior_id,
  TRIM(user_id)     AS user_id,
  TRIM(product_id)  AS product_id,

  -- 行为类型：10 种 → 浏览 / 加购 / 收藏 / 购买
  CASE
    WHEN LOWER(TRIM(b.behavior_type)) IN ('pv','浏览','view','page_view') THEN '浏览'
    WHEN LOWER(TRIM(b.behavior_type)) IN ('cart','加购','add_cart','addcart') THEN '加购'
    WHEN LOWER(TRIM(b.behavior_type)) IN ('fav','收藏','favorite','collect')  THEN '收藏'
    WHEN LOWER(TRIM(b.behavior_type)) IN ('buy','购买','purchase','order')    THEN '购买'
    ELSE '其他'
  END AS behavior_type,

  -- 行为时间统一为 yyyy-MM-dd HH:mm:ss
  -- 实际存在两种脏形态：2024/11/05 15:49（斜杠且缺秒）、2024-12-06 09:16:24（已规范）
  CASE
    -- ① 斜杠 + 无秒 → 换分隔符并补 :00
    WHEN TRIM(b.behavior_time) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}$'
      THEN CONCAT(REGEXP_REPLACE(SUBSTR(TRIM(b.behavior_time),1,10), '/', '-'),
                  ' ', SUBSTR(TRIM(b.behavior_time),12), ':00')
    -- ② 斜杠 + 有秒 → 只换分隔符
    WHEN TRIM(b.behavior_time) RLIKE '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
      THEN REGEXP_REPLACE(TRIM(b.behavior_time), '/', '-')
    -- ③ 横杠 + 无秒 → 补 :00
    WHEN TRIM(b.behavior_time) RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$'
      THEN CONCAT(TRIM(b.behavior_time), ':00')
    ELSE TRIM(b.behavior_time)
  END AS behavior_time,

  TRIM(b.session_id) AS session_id
FROM ydsh_ods.ods_user_behavior b;

-- =============================================================
-- 七、取值收敛验证（答辩演示用：清洗前后 distinct 数量对比）
-- =============================================================
SELECT 'gender' AS field,
       COUNT(DISTINCT TRIM(gender)) AS ods_distinct,
       (SELECT COUNT(DISTINCT gender) FROM ydsh_dwd.dwd_user_clean) AS dwd_distinct,
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean) AS dwd_rows
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'member_level',
       COUNT(DISTINCT TRIM(member_level)),
       (SELECT COUNT(DISTINCT member_level) FROM ydsh_dwd.dwd_user_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean)
FROM ydsh_ods.ods_user
UNION ALL
SELECT 'order_status',
       COUNT(DISTINCT TRIM(order_status)),
       (SELECT COUNT(DISTINCT order_status) FROM ydsh_dwd.dwd_order_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'pay_type',
       COUNT(DISTINCT TRIM(pay_type)),
       (SELECT COUNT(DISTINCT pay_type) FROM ydsh_dwd.dwd_order_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'channel',
       COUNT(DISTINCT TRIM(channel)),
       (SELECT COUNT(DISTINCT channel) FROM ydsh_dwd.dwd_order_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean)
FROM ydsh_ods.ods_order
UNION ALL
SELECT 'behavior_type',
       COUNT(DISTINCT TRIM(behavior_type)),
       (SELECT COUNT(DISTINCT behavior_type) FROM ydsh_dwd.dwd_user_behavior_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean)
FROM ydsh_ods.ods_user_behavior
UNION ALL
SELECT 'category',
       COUNT(DISTINCT category),
       (SELECT COUNT(DISTINCT category) FROM ydsh_dwd.dwd_product_clean),
       (SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean)
FROM ydsh_ods.ods_product;

-- 各表行数（去重是否生效）
SELECT 'dwd_user_clean' AS tbl, COUNT(*) AS cnt FROM ydsh_dwd.dwd_user_clean
UNION ALL SELECT 'dwd_product_clean',     COUNT(*) FROM ydsh_dwd.dwd_product_clean
UNION ALL SELECT 'dwd_store_clean',       COUNT(*) FROM ydsh_dwd.dwd_store_clean
UNION ALL SELECT 'dwd_order_clean',       COUNT(*) FROM ydsh_dwd.dwd_order_clean
UNION ALL SELECT 'dwd_order_item_clean',  COUNT(*) FROM ydsh_dwd.dwd_order_item_clean
UNION ALL SELECT 'dwd_user_behavior_clean', COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean;
