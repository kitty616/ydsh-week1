-- =============================================================
-- 00_init_database.sql
-- 作用：创建项目所需的数据库
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 00_init_database.sql
-- =============================================================

-- ODS 贴源层：与 6 张 CSV 一一对应，不做任何加工
CREATE DATABASE IF NOT EXISTS ydsh_ods
  COMMENT '云购生活-ODS贴源层'
  LOCATION '/user/hive/warehouse/ydsh_ods.db';

-- DWD 明细层：清洗后的明细数据（本周产出 dwd_user / dwd_product / dwd_order）
CREATE DATABASE IF NOT EXISTS ydsh_dwd
  COMMENT '云购生活-DWD明细层'
  LOCATION '/user/hive/warehouse/ydsh_dwd.db';

SHOW DATABASES;
