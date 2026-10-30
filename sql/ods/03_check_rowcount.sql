-- =============================================================
-- 03_check_rowcount.sql
-- 作用：导入后行数校验，与《数据字典》预期行数对比
-- 判定：允许因脏数据造成极小偏差，但核心事实表必须达到万级规模
-- 执行：beeline -u jdbc:hive2://localhost:10000 -f 03_check_rowcount.sql
-- =============================================================

USE ydsh_ods;

SELECT 'ods_user'         AS table_name, COUNT(*) AS actual_cnt, 1000  AS expect_cnt, COUNT(*) - 1000  AS diff FROM ods_user
UNION ALL
SELECT 'ods_product'      AS table_name, COUNT(*) AS actual_cnt, 600   AS expect_cnt, COUNT(*) - 600   AS diff FROM ods_product
UNION ALL
SELECT 'ods_store'        AS table_name, COUNT(*) AS actual_cnt, 60    AS expect_cnt, COUNT(*) - 60    AS diff FROM ods_store
UNION ALL
SELECT 'ods_order'        AS table_name, COUNT(*) AS actual_cnt, 15600 AS expect_cnt, COUNT(*) - 15600 AS diff FROM ods_order
UNION ALL
SELECT 'ods_order_item'   AS table_name, COUNT(*) AS actual_cnt, 37549 AS expect_cnt, COUNT(*) - 37549 AS diff FROM ods_order_item
UNION ALL
SELECT 'ods_user_behavior' AS table_name, COUNT(*) AS actual_cnt, 60000 AS expect_cnt, COUNT(*) - 60000 AS diff FROM ods_user_behavior;

-- ---------------------------------------------------------------
-- 若某张表行数为 0，常见原因：
--   1) CSV 未放进 data/ 目录
--   2) 文件名大小写不一致（Linux 区分大小写）
--   3) 表头未跳过（行数 = 预期 + 1）→ 检查 skip.header.line.count
--   4) CSV 使用了引号包裹且字段内含逗号 → 改用 OpenCSVSerde 建表
-- ---------------------------------------------------------------
