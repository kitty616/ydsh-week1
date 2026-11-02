-- =============================================================
-- 23_quality_compare.sql
-- 作用：子任务 4 —— 清洗前后数据质量对比（五类脏数据修复率）
-- 输入：ydsh_ods.*（清洗前） / ydsh_dwd.dwd_*_clean（清洗后）
-- 输出：ydsh_dwd.dq_compare（供《数据质量清洗报告》取数）
--
-- 统计口径（与任务书一致）：
--   修复率 = (清洗前问题数 - 清洗后问题数) / 清洗前问题数
--   清洗前 = 贴源层 ODS 原始值；清洗后 = 22 号脚本产出的清洗完成态
--
-- 类目划分沿用第一周五维度的前四类（缺失/重复/异常/格式），
-- 「枚举不规范」在本州并入「格式/取值规范」，单列是为了让修复率更直观。
--
-- 执行：bash scripts/run_sql.sh sql/clean/23_quality_compare.sql
-- =============================================================

DROP TABLE IF EXISTS ydsh_dwd.dq_compare;
CREATE TABLE ydsh_dwd.dq_compare (
  category    STRING COMMENT '问题类别',
  item        STRING COMMENT '检查项',
  before_cnt  BIGINT COMMENT '清洗前问题数',
  after_cnt   BIGINT COMMENT '清洗后问题数',
  fixed_cnt   BIGINT COMMENT '修复数',
  fix_rate    DOUBLE COMMENT '修复率（%）',
  strategy    STRING COMMENT '处理策略'
) COMMENT '数据质量清洗前后对比' STORED AS ORC;

INSERT OVERWRITE TABLE ydsh_dwd.dq_compare
SELECT category, item, before_cnt, after_cnt,
       before_cnt - after_cnt AS fixed_cnt,
       CASE WHEN before_cnt = 0 THEN NULL
            ELSE ROUND(100.0 * (before_cnt - after_cnt) / before_cnt, 2) END AS fix_rate,
       strategy
FROM (
  -- ============ 一、枚举不规范 ============
  SELECT '枚举不规范' AS category, 'user.gender 非规范取值' AS item,
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(gender) <> '' AND LOWER(TRIM(gender)) NOT IN ('男','女','未知')) AS before_cnt,
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean
      WHERE LOWER(TRIM(gender)) NOT IN ('男','女','未知')) AS after_cnt,
    'M/F/male/female 映射为 男/女，空值归入 未知' AS strategy
  UNION ALL
  SELECT '枚举不规范', 'user.member_level 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(member_level) <> ''
        AND LOWER(TRIM(member_level)) NOT IN ('普通会员','银卡会员','金卡会员','钻石会员')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean
      WHERE LOWER(TRIM(member_level_name)) NOT IN ('普通会员','银卡会员','金卡会员','钻石会员')),
    'gold/silver/短名称统一为四档全称'
  UNION ALL
  SELECT '枚举不规范', 'order.order_status 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE TRIM(order_status) <> ''
        AND LOWER(TRIM(order_status)) NOT IN ('待支付','已支付','已完成','已取消','退款中')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean
      WHERE LOWER(TRIM(order_status_name)) NOT IN ('待支付','已支付','已完成','已取消','退款中')),
    '数字编码与「完成/已付款」等变体统一为五态'
  UNION ALL
  SELECT '枚举不规范', 'order.pay_type 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE TRIM(pay_type) <> ''
        AND LOWER(TRIM(pay_type)) NOT IN ('微信支付','支付宝','银行卡','货到付款')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean
      WHERE LOWER(TRIM(pay_type_name)) NOT IN ('微信支付','支付宝','银行卡','货到付款')),
    'wechat/alipay/微信 统一为中文标准值'
  UNION ALL
  SELECT '枚举不规范', 'order.channel 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE TRIM(channel) <> ''
        AND TRIM(channel) NOT IN ('门店','APP','小程序','PC官网')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean
      WHERE TRIM(channel_name) NOT IN ('门店','APP','小程序','PC官网')),
    'app/pc 大小写变体统一为 APP/PC官网'
  UNION ALL
  SELECT '枚举不规范', 'behavior.behavior_type 非规范取值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user_behavior
      WHERE TRIM(behavior_type) <> ''
        AND LOWER(TRIM(behavior_type)) NOT IN ('浏览','加购','收藏','购买')),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean
      WHERE LOWER(TRIM(behavior_type_name)) NOT IN ('浏览','加购','收藏','购买')),
    'pv/cart/fav/buy 与中文混用统一为四类'
  UNION ALL
  SELECT '枚举不规范', 'product.category 含首尾空格',
    (SELECT COUNT(*) FROM ydsh_ods.ods_product WHERE category <> TRIM(category)),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean WHERE category <> TRIM(category)),
    'TRIM 去除首尾空格，类目收敛为 8 个规范值'

  -- ============ 二、缺失值 ============
  UNION ALL
  SELECT '缺失值', 'user.gender 空值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user WHERE TRIM(gender) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE gender IS NULL OR TRIM(gender) = ''),
    '空值归入「未知」，不臆造性别'
  UNION ALL
  SELECT '缺失值', 'user.member_level 空值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user WHERE TRIM(member_level) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean
      WHERE member_level_name IS NULL OR TRIM(member_level_name) = ''),
    '空值按最低等级「普通会员」兜底并打标'
  UNION ALL
  SELECT '缺失值', 'user.age 空值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user WHERE TRIM(age) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE age IS NULL),
    '取合法区间中位数填充，避免均值被离群值拉偏'
  UNION ALL
  SELECT '缺失值', 'product.launch_date 空值',
    (SELECT COUNT(*) FROM ydsh_ods.ods_product WHERE TRIM(launch_date) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean WHERE TRIM(launch_date) = ''),
    '用同品类最早上架日期补全'
  UNION ALL
  SELECT '缺失值', 'user.email 空值（保留）',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user WHERE TRIM(email) = ''),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE email_flag = '缺失'),
    '弱依赖字段保留空值 + 标记位，不臆造邮箱'

  -- ============ 三、重复值 ============
  UNION ALL
  SELECT '重复值', 'order.order_id 重复行',
    (SELECT COUNT(*) - COUNT(DISTINCT TRIM(order_id)) FROM ydsh_ods.ods_order),
    (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM ydsh_dwd.dwd_order_clean),
    'ROW_NUMBER 按业务时间倒序保留最新一条'

  -- ============ 四、异常值 ============
  UNION ALL
  SELECT '异常值', 'user.age 越界或非数值（-3 / 0 / 150 等）',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(age) <> ''
        AND (TRIM(age) NOT RLIKE '^-?[0-9]+$' OR CAST(TRIM(age) AS INT) NOT BETWEEN 1 AND 120)),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE age NOT BETWEEN 1 AND 120),
    '非法值按合法区间中位数填充'
  UNION ALL
  SELECT '异常值', 'order.pay_amount 非正数',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE CAST(TRIM(pay_amount) AS DOUBLE) <= 0),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean WHERE pay_amount <= 0),
    '负金额无业务解释，整单剔除'
  UNION ALL
  SELECT '异常值', 'order.pay_amount 超上限（IQR 上界 8840.59）',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE CAST(TRIM(pay_amount) AS DOUBLE) > 8840.59),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean WHERE pay_amount > 8840.59),
    'Q3+3×IQR 稳健上界，避免绝对阈值误删高客单'
  UNION ALL
  SELECT '异常值', 'order_item.quantity 非正数',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order_item WHERE CAST(TRIM(quantity) AS INT) <= 0),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_item_clean WHERE quantity <= 0),
    '0 件/负件不成立，明细行剔除'
  UNION ALL
  SELECT '异常值', 'product.price 非正或成本高于售价',
    (SELECT COUNT(*) FROM ydsh_ods.ods_product
      WHERE CAST(TRIM(price) AS DOUBLE) <= 0
         OR CAST(TRIM(cost) AS DOUBLE) > CAST(TRIM(price) AS DOUBLE)),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_product_clean WHERE price <= 0 OR cost > price),
    '按成本 × 1.2 修正，保留商品记录'

  -- ============ 五、格式不统一 ============
  UNION ALL
  SELECT '格式不统一', 'user.register_date 非 yyyy-MM-dd',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(register_date) NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean
      WHERE register_date IS NULL OR register_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
    '斜杠/8 位数字统一为 yyyy-MM-dd'
  UNION ALL
  SELECT '格式不统一', 'order.order_date 非 yyyy-MM-dd',
    (SELECT COUNT(*) FROM ydsh_ods.ods_order
      WHERE TRIM(order_date) NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_order_clean
      WHERE order_date NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
    '斜杠日期统一为 yyyy-MM-dd'
  UNION ALL
  SELECT '格式不统一', 'behavior.behavior_time 非标准时间',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user_behavior
      WHERE TRIM(behavior_time) NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_behavior_clean
      WHERE behavior_time IS NULL OR behavior_time NOT RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'),
    '斜杠并缺秒的格式统一并补 :00'
  UNION ALL
  SELECT '格式不统一', 'user.phone 非 11 位纯数字',
    (SELECT COUNT(*) FROM ydsh_ods.ods_user
      WHERE TRIM(phone) NOT RLIKE '^1[3-9][0-9]{9}$'),
    (SELECT COUNT(*) FROM ydsh_dwd.dwd_user_clean WHERE phone_flag = '格式异常'),
    '去分隔符后校验 11 位，不合规置空'
) t;

-- =============================================================
-- 输出对比表
-- =============================================================
SELECT category, item, before_cnt, after_cnt, fixed_cnt, fix_rate, strategy
FROM ydsh_dwd.dq_compare
ORDER BY category, before_cnt DESC;

-- 汇总：各类别修复率
SELECT category,
       SUM(before_cnt) AS before_total,
       SUM(after_cnt)  AS after_total,
       SUM(before_cnt) - SUM(after_cnt) AS fixed_total,
       ROUND(100.0 * (SUM(before_cnt) - SUM(after_cnt)) / SUM(before_cnt), 2) AS fix_rate
FROM ydsh_dwd.dq_compare
GROUP BY category
ORDER BY before_total DESC;

-- 总体修复率
SELECT SUM(before_cnt) AS before_total,
       SUM(after_cnt)  AS after_total,
       ROUND(100.0 * (SUM(before_cnt) - SUM(after_cnt)) / SUM(before_cnt), 2) AS overall_fix_rate
FROM ydsh_dwd.dq_compare;
