-- =============================================================
-- 02_load_data.sql
-- 作用：将 6 张 CSV 从容器内 /data 目录加载进 ODS 表
-- 说明：
--   docker-compose.yml 已把宿主机 ./data 映射到容器 /data，
--   因此 LOCAL INPATH 使用 /data/xxx.csv（由 HiveServer2 所在容器读取）
--   使用 OVERWRITE 保证脚本可重复执行（不会重复追加）
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 02_load_data.sql
-- =============================================================

SET hive.exec.compress.output = false;

LOAD DATA LOCAL INPATH '/data/ods_user.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_user;

LOAD DATA LOCAL INPATH '/data/ods_product.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_product;

LOAD DATA LOCAL INPATH '/data/ods_store.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_store;

LOAD DATA LOCAL INPATH '/data/ods_order.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_order;

LOAD DATA LOCAL INPATH '/data/ods_order_item.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_order_item;

LOAD DATA LOCAL INPATH '/data/ods_user_behavior.csv'
  OVERWRITE INTO TABLE ydsh_ods.ods_user_behavior;

-- ---------------------------------------------------------------
-- 若报 "Invalid path '/data/xxx.csv': No files matching path file"
-- 说明宿主机 data/ 目录里缺文件，或文件名大小写不一致：
--   Windows 下 ods_user.CSV 与 ods_user.csv 在容器 Linux 中不是同一个文件，
--   请统一改成全小写 .csv
-- ---------------------------------------------------------------
