-- =============================================================
-- 30_create_dim_tables.sql
-- 作用：子任务 6 —— DWD 层维度表建模（星型模型的「角」）
-- 输入：ydsh_dwd.dwd_*_clean（22 号脚本产出的清洗完成态）
-- 输出：ydsh_dwd.dim_user / dim_product / dim_store / dim_date
--
-- 建模约定：
--   1) 维度表 = 描述性属性集合，只放「谁 / 什么 / 哪里 / 何时」；
--      度量（金额、数量）一律进事实表，避免维度表膨胀；
--   2) 主键统一命名为 <业务实体>_id，事实表用同名外键关联；
--   3) 所有维度表 STORED AS ORC + SNAPPY，压缩比高且支持谓词下推；
--   4) dim_date 是「日期维」，预先生成连续日期，避免事实表按日期
--      做字符串函数解析（比 SUBSTR/CAST 快，也便于按周/季汇总）。
--
-- 执行：bash scripts/run_sql.sh sql/dwd/30_create_dim_tables.sql
-- =============================================================

CREATE DATABASE IF NOT EXISTS ydsh_dwd;

-- =============================================================
-- 一、dim_user —— 用户维度
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_user;
CREATE TABLE ydsh_dwd.dim_user (
  user_id           STRING COMMENT '用户编号（主键）',
  user_name         STRING COMMENT '用户姓名',
  gender            STRING COMMENT '性别：男/女/未知',
  age               INT    COMMENT '年龄（缺失已用中位数填充）',
  province          STRING COMMENT '省份',
  city              STRING COMMENT '城市',
  region            STRING COMMENT '大区（省-市，直辖市已去重）',
  register_date     STRING COMMENT '注册日期 yyyy-MM-dd',
  member_level_code STRING COMMENT '会员等级编码（关联 dim_member_level）',
  member_level_name STRING COMMENT '会员等级名称',
  email             STRING COMMENT '邮箱（可空）',
  email_flag        STRING COMMENT '邮箱标记：正常/缺失',
  phone             STRING COMMENT '手机号（11 位，异常已置空）'
)
COMMENT 'DWD 维度表-用户'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- =============================================================
-- 二、dim_product —— 商品维度
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_product;
CREATE TABLE ydsh_dwd.dim_product (
  product_id   STRING COMMENT '商品编号（主键）',
  product_name STRING COMMENT '商品名称',
  category     STRING COMMENT '一级类目（已去空格）',
  sub_category STRING COMMENT '二级类目',
  brand        STRING COMMENT '品牌（英文统一大写）',
  price        DOUBLE COMMENT '售价（异常已按成本×1.2 修正）',
  cost         DOUBLE COMMENT '成本价',
  stock        INT    COMMENT '库存',
  status       STRING COMMENT '状态：在售/下架/缺货',
  launch_date  STRING COMMENT '上架日期 yyyy-MM-dd'
)
COMMENT 'DWD 维度表-商品'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- =============================================================
-- 三、dim_store —— 门店维度
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_store;
CREATE TABLE ydsh_dwd.dim_store (
  store_id   STRING COMMENT '门店编号（主键）',
  store_name STRING COMMENT '门店名称',
  province   STRING COMMENT '省份',
  city       STRING COMMENT '城市',
  district   STRING COMMENT '区县',
  address    STRING COMMENT '详细地址',
  open_date  STRING COMMENT '开业日期 yyyy-MM-dd',
  area       DOUBLE COMMENT '营业面积（㎡）',
  manager    STRING COMMENT '店长'
)
COMMENT 'DWD 维度表-门店'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- =============================================================
-- 四、dim_date —— 日期维度（预生成连续日期）
-- =============================================================
DROP TABLE IF EXISTS ydsh_dwd.dim_date;
CREATE TABLE ydsh_dwd.dim_date (
  date_key    STRING COMMENT '日期主键 yyyy-MM-dd',
  year        INT    COMMENT '年',
  quarter     INT    COMMENT '季度 1-4',
  month       INT    COMMENT '月 1-12',
  day         INT    COMMENT '日 1-31',
  week_of_year INT   COMMENT '当年第几周',
  weekday     INT    COMMENT '星期几 1=周一 … 7=周日',
  is_weekend  INT    COMMENT '是否周末 1/0',
  year_month  STRING COMMENT '年月 yyyy-MM'
)
COMMENT 'DWD 维度表-日期（覆盖订单日期全区间）'
STORED AS ORC
TBLPROPERTIES ('orc.compress' = 'SNAPPY');

-- 用 posexplode 生成从最早到最晚订单日期的连续日期序列
INSERT OVERWRITE TABLE ydsh_dwd.dim_date
SELECT
  DATE_FORMAT(d, 'yyyy-MM-dd')      AS date_key,
  YEAR(d)                           AS year,
  QUARTER(d)                        AS quarter,
  MONTH(d)                          AS month,
  DAY(d)                            AS day,
  WEEKOFYEAR(d)                     AS week_of_year,
  -- Hive 的 DAYOFWEEK 是 1=周日…7=周六，这里换算成 1=周一…7=周日
  CASE WHEN DAYOFWEEK(d) = 1 THEN 7 ELSE DAYOFWEEK(d) - 1 END AS weekday,
  CASE WHEN DAYOFWEEK(d) IN (1, 7) THEN 1 ELSE 0 END          AS is_weekend,
  DATE_FORMAT(d, 'yyyy-MM')         AS year_month
FROM (
  SELECT DATE_ADD(b.min_d, i) AS d
  FROM (
    SELECT MIN(TO_DATE(order_date)) AS min_d, MAX(TO_DATE(order_date)) AS max_d
    FROM ydsh_dwd.dwd_order_clean
  ) b
  LATERAL VIEW POSEXPLODE(SPLIT(SPACE(DATEDIFF(b.max_d, b.min_d)), ' ')) t AS i, x
) s;

-- =============================================================
-- 五、维度表行数核对
-- =============================================================
SELECT 'dim_user' AS tbl, COUNT(*) AS cnt FROM ydsh_dwd.dim_user
UNION ALL SELECT 'dim_product', COUNT(*) FROM ydsh_dwd.dim_product
UNION ALL SELECT 'dim_store',   COUNT(*) FROM ydsh_dwd.dim_store
UNION ALL SELECT 'dim_date',    COUNT(*) FROM ydsh_dwd.dim_date;

SELECT MIN(date_key) AS date_from, MAX(date_key) AS date_to FROM ydsh_dwd.dim_date;
