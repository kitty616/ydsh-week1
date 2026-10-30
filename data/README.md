# data/ 目录说明

## 放什么

把老师提供的 6 个 CSV 文件**原样**放进本目录，文件名必须全小写、与下表完全一致：

| 文件名 | 预期行数 |
|---|---|
| `ods_user.csv` | 1,000 |
| `ods_product.csv` | 600 |
| `ods_store.csv` | 60 |
| `ods_order.csv` | 15,600 |
| `ods_order_item.csv` | 37,549 |
| `ods_user_behavior.csv` | 60,000 |

## 为什么这个目录是空的 / 不进 Git

- CSV 属于数据资产，体积大（合计数十 MB），不适合提交到代码仓库
- `.gitignore` 中已配置忽略 `data/*.csv`，团队成员各自本地存放即可
- Docker Compose 已把本目录挂载到容器内的 `/data`，Hive 通过 `/data/xxx.csv` 读取

## 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `No files matching path file` | 文件名大小写不一致 | 改成全小写 `.csv`（Linux 区分大小写） |
| 导入后行数 = 预期 + 1 | 表头被当数据 | 确认建表带了 `skip.header.line.count='1'` |
| 某几行字段错位 | 字段内含英文逗号 | 需要改用 OpenCSVSerde 建表，见下 |

## 若 CSV 含引号包裹的字段

把建表语句中的

```sql
ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
```

替换为

```sql
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
  "separatorChar" = ",",
  "quoteChar"     = "\"",
  "escapeChar"    = "\\"
)
```

并去掉 `skip.header.line.count`（OpenCSVSerde 会自己识别表头）。
