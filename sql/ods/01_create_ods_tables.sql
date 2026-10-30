-- =============================================================
-- 01_create_ods_tables.sql
-- 作用：在 ydsh_ods 库中创建 6 张贴源表
-- 要点：
--   1) 字段全部先按 string 落贴源层（贴源层原则：不做过早类型转换）
--   2) 分隔符 ','，并跳过 CSV 表头
--   3) 每张表加 TBLPROPERTIES 记录来源文件，便于溯源
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 01_create_ods_tables.sql
-- =============================================================

USE ydsh_ods;

-- -------------------------------------------------------------
-- (1) ods_user —— 用户信息表（预期 1,000 行）
-- 脏数据：gender 中英文混用/空、age 为空/200/-3、
--         register_date 三种日期格式、member_level 中英文混用、phone 格式不一、email 部分缺失
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_user;
CREATE TABLE ods_user (
  user_id        STRING COMMENT '用户编号（主键）',
  user_name      STRING COMMENT '用户姓名',
  gender         STRING COMMENT '性别（含异常值：男/女/M/F/未知/空）',
  age            STRING COMMENT '年龄（含缺失、异常：空/200/-3）',
  city           STRING COMMENT '城市',
  province       STRING COMMENT '省份',
  register_date  STRING COMMENT '注册日期（格式不一致）',
  member_level   STRING COMMENT '会员等级（中英文混用）',
  phone          STRING COMMENT '手机号（格式不一致）',
  email          STRING COMMENT '邮箱（部分缺失）'
)
COMMENT 'ODS-用户信息表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_user.csv'
);

-- -------------------------------------------------------------
-- (2) ods_product —— 商品信息表（预期 600 行）
-- 脏数据：category/brand 大小写与空格异常、price 含负数与 999999 异常高价、launch_date 部分缺失
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_product;
CREATE TABLE ods_product (
  product_id    STRING COMMENT '商品编号（主键）',
  product_name  STRING COMMENT '商品名称',
  category      STRING COMMENT '一级类目（大小写/空格异常）',
  sub_category  STRING COMMENT '二级类目',
  brand         STRING COMMENT '品牌（大小写异常）',
  price         STRING COMMENT '售价（含负数、异常高价）',
  cost          STRING COMMENT '成本价',
  stock         STRING COMMENT '库存数量',
  status        STRING COMMENT '状态：在售/下架/缺货',
  launch_date   STRING COMMENT '上架日期（部分缺失）'
)
COMMENT 'ODS-商品信息表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_product.csv'
);

-- -------------------------------------------------------------
-- (3) ods_store —— 门店信息表（预期 60 行）
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_store;
CREATE TABLE ods_store (
  store_id    STRING COMMENT '门店编号（主键）',
  store_name  STRING COMMENT '门店名称',
  province    STRING COMMENT '省份',
  city        STRING COMMENT '城市',
  district    STRING COMMENT '区县',
  address     STRING COMMENT '详细地址',
  open_date   STRING COMMENT '开业日期',
  area        STRING COMMENT '营业面积（㎡）',
  manager     STRING COMMENT '店长姓名'
)
COMMENT 'ODS-门店信息表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_store.csv'
);

-- -------------------------------------------------------------
-- (4) ods_order —— 订单主表（预期 15,600 行，含约 600 条重复）
-- 脏数据：order_id 重复、order_date 格式不一、pay_amount 含负数与 5000000 异常值、
--         pay_type / order_status / channel 中英文与大小写混用
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_order;
CREATE TABLE ods_order (
  order_id         STRING COMMENT '订单编号（应唯一，含重复）',
  user_id          STRING COMMENT '用户编号',
  store_id         STRING COMMENT '门店编号',
  order_date       STRING COMMENT '下单日期（格式不一致）',
  order_time       STRING COMMENT '下单时间',
  pay_amount       STRING COMMENT '实付金额（含负数、异常）',
  discount_amount  STRING COMMENT '优惠金额',
  pay_type         STRING COMMENT '支付方式（中英文混用）',
  order_status     STRING COMMENT '订单状态（取值不规范）',
  channel          STRING COMMENT '下单渠道（大小写混用）'
)
COMMENT 'ODS-订单主表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_order.csv'
);

-- -------------------------------------------------------------
-- (5) ods_order_item —— 订单明细表（预期 37,549 行）
-- 脏数据：quantity 含 0 / 负数 / 99 超大值
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_order_item;
CREATE TABLE ods_order_item (
  item_id      STRING COMMENT '明细编号（主键）',
  order_id     STRING COMMENT '所属订单编号',
  product_id   STRING COMMENT '商品编号',
  quantity     STRING COMMENT '购买数量（含 0、负数、超大值）',
  unit_price   STRING COMMENT '商品单价',
  discount     STRING COMMENT '折扣率（0~1）'
)
COMMENT 'ODS-订单明细表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_order_item.csv'
);

-- -------------------------------------------------------------
-- (6) ods_user_behavior —— 用户行为日志表（预期 60,000 行）
-- 脏数据：behavior_type 中英文混用、behavior_time 格式不一
-- -------------------------------------------------------------
DROP TABLE IF EXISTS ods_user_behavior;
CREATE TABLE ods_user_behavior (
  behavior_id    STRING COMMENT '行为编号（主键）',
  user_id        STRING COMMENT '用户编号',
  product_id     STRING COMMENT '商品编号',
  behavior_type  STRING COMMENT '行为类型（中英文混用：pv/cart/fav/buy/浏览）',
  behavior_time  STRING COMMENT '行为发生时间（格式不一致）',
  session_id     STRING COMMENT '会话编号'
)
COMMENT 'ODS-用户行为日志表'
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY ','
STORED AS TEXTFILE
TBLPROPERTIES (
  'skip.header.line.count' = '1',
  'source.file'            = 'ods_user_behavior.csv'
);

SHOW TABLES;
