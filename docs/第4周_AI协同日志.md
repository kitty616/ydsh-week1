# 第 4 周 AI 协同日志

- 团队：云购生活数据组　成员：曲欣锋　填写日期：2026-11-17
- 本周主题：可视化（Superset / ECharts / Streamlit）· 部署（Docker Compose）· 优化与压测

---

## 一、使用的 AI 工具 / 模型

- 对话与代码辅助：WorkBuddy（DeepSeek-V4 系列），用于方案讨论、报错定位、代码生成、文档撰写
- 业务代码调用的模型：沿用第 3 周的 `python/llm_provider.py`（五家 OpenAI 兼容服务商，填任一 Key 即可）
- 密钥管理：全部走 `.env`，`.env` 在 `.gitignore` 里；提交前 `git ls-files` 与 `git log -p -S "sk-"` 双查

---

## 二、AI 协同记录表

| 序号 | 提问 / 任务描述 | AI 产出摘要 | 人工修改与验证 | 是否采纳 |
|---|---|---|---|---|
| 1 | Superset 能不能用脚本把数据源、数据集、图表、仪表板一次性配好？ | 建议走 `/api/v1` REST 接口：登录取 Bearer Token，按 Database → Dataset → Chart → Dashboard 顺序 POST | **连撞三堵墙。** ① 写接口 400 `The CSRF token is missing`（纯 Bearer 不行）；② 补 Cookie + CSRF 后 GET 列表接口 422（两种凭证冲突）；③ 建 Hive 数据源 422 `Database could not be created`，真实原因是 4.1 会探测 `SHOW CATALOGS`，`apache/hive:4.0.0` 不认。**三次失败后决定弃用 REST**，改成在容器内用 Superset 自己的 ORM 写库（`provision.py`），绕开整条认证链路，顺便也绕开了 catalog 探测 | 未采纳，换方案 |
| 2 | 设计一套 SUPERSET 的图表参数，覆盖折线/柱状/地图/饼图/表格 | 给出 7 张图的 `params` JSON，包括 adhoc metric 结构与 `xAxisForceCategorical` | 结构可用，但三处必须改：① 月份是字符串不是时间戳，不强制 categorical 会报 temporal 列缺失；② 地图 entity 传英文省名（`Shaanxi`）不着色；③ 明细表的 `order_by_cols` 要写成 `['["rank_no", true]']` 这种"字符串里套 JSON"的形式，写法错就直接 500 | 采纳（改参数后） |
| 3 | 中国地图画出来了但一个省都不着色，也没图例 | 建议检查 `select_country` 是否为 `china`、`linear_color_scheme` 是否合法 | 两项都没问题。**最后是去前端产物里翻到判据**：`n.filter(e => e.country_id === t.properties.ISO)`——关联键写死在内置 geojson 的 `properties.ISO` 上，形如 `CN-SN`。把 entity 从 `name_en` 改成 `iso` 后立刻着色。**这条经验没法靠"看文档"得到，只能读代码** | 采纳（但结论是人工查出来的） |
| 4 | 热力图做出来整片颜色几乎一样，怎么调整？ | 建议换成 `visualMap` 分段、或把数据取对数 | 两者都治标。查数发现根因：明细表 `unit_price` 是**标价**不是成交价——`SUM(quantity*unit_price)` = 6.17 亿，而订单实付 3,611 万，**差 17 倍**。先改订单数口径（仍偏均匀），最后改**行内归一化**（该品类该时段订单 ÷ 该品类全天订单）才出规律：生鲜聚在 17–19 点、图书文娱聚在 21–23 点 | 部分采纳，根因人工定位 |
| 5 | 压测时怎么证明「分区裁剪生效」？ | 建议对比两种写法的**耗时**，快的那个就是生效了 | **判据选错了。** 实测三次：全表 1267 ms、裁剪后 604 ms、**函数包裹（扫 366 个分区）410 ms**——扫得最多的反而最快。原因是表只有 1.4 万行，耗时被 Tez 每次约 0.5 秒的启动开销主导。改用 `EXPLAIN DEPENDENCY` 数 `input_partitions`：裁剪后列出 1 个分区，函数包裹则为空（= 全表） | 未采纳，换判据 |
| 6 | Hive 里小表 JOIN 加 `/*+ MAPJOIN */` 能提速多少？ | 说能省掉一次 shuffle，通常有 20%~50% 提升 | **实测没有提升。** 先看计划：普通 JOIN 与加 hint 的 SQL，执行计划**都是 `Map Join Operator`**——Hive 4 默认 `hive.auto.convert.join=true`，CBO 看到维表只有 15 行早就自动转了。耗时差 +1.0%，在抖动区间内。这条纠正了一个常见误解：**网上教程的 hint 是给 Hive 1.x/2.x 的，照抄到新版本只是让 SQL 更难读** | 未采纳 |
| 7 | 仪表板配好了，点柱子没有任何联动反应 | 建议检查每张图的 `emitCrossFilters` 是否为 true | `emitCrossFilters` 确实都设了，`chart_configuration` 的作用域也配了，仍不生效。最后在 bundle 里找到原因：`if (isFeatureEnabled(DashboardCrossFilters)) {...}`——而我在 `superset_config.py` 里**整体重写了 `FEATURE_FLAGS`**，把 `config.py` 的默认项全丢了，包括这个开关。补回后仍未验证通过，如实记为待办 | 部分采纳，状态如实记录 |
| 8 | 品类销售柱状图报错 `Cannot read properties of undefined` | 建议检查 metric 的 `column.type` 是否写成 `DOUBLE` | 参数没问题。真实原因是这张图用的是**分类轴**（`category` 是字符串），必须显式 `"granularity_sqla": null` + `"time_range": "No filter"`，否则前端会去找时间列 | 部分采纳 |
| 9 | Streamlit 页面 headless 截图只有骨架屏，怎么办？ | 建议加 `--virtual-time-budget` 延长等待 | 无用。Streamlit 靠 WebSocket 增量推送，headless 下 WS 握手经常连不上。改用两条路：功能验证用 `streamlit.testing.v1.AppTest`（容器内跑，0 异常）；截图用 CDP 直连真实 Edge（`tools/shot.js`），顺带把"点输入框→输入→回车"也做了，截到了带真实回答的界面 | 未采纳，换方案 |
| 10 | 问"2024 年每个月的 GMV 趋势"，模型写 `WHERE year = '2024'`，但表里只有 `month` | 建议在 Prompt 里加强"不要编造列"的约束 | 约束加强了（第 11 条），但这类错误**静态校验拦不住**——语法完全合法，只是列不存在。补了执行期兜底：`ask_with_repair()` 把 Hive 的报错原文回灌给模型让它改一次。界面上的"已自修复 1 次"就是这条链路生效的证据 | 采纳（并加兜底） |
| 11 | Superset 图表全报 `No module named 'MySQLdb'`，URI 已经写了 `mysql+pymysql` | 建议 `pip install mysqlclient` | `mysqlclient` 要现场编译，镜像里没有 gcc。改用 PyMySQL 官方兼容层 `pymysql.install_as_MySQLdb()`——它把自身注册成 `sys.modules['MySQLdb']`，一行解决。**AI 给的方向对（要补 MySQLdb），给的方案重了** | 方向采纳，方案改轻 |
| 12 | 自查：压测脚本里 Hive 并发为什么只开 4 而 CK/MySQL 开 8？ | 未使用 AI | 因为再往上会把 HiveServer2 的会话池打满，测出来的不是查询能力而是排队时间。这条在《压力测试记录》第六节"局限"里写明，避免读者误读 QPS 数字 | 人工判断 |

> 说明：第 1、3、5、6 条是本周最有价值的三类记录。它们的共同点是——**AI 的方案在逻辑上都讲得通，只有真的跑一遍才会发现是错的**：
> 第 1 条是"文档路径"在新版本上失效，第 3、5 条是"判据"选错导致结论反向，第 6 条是"经验"过期。
> 如果只做纸面评审，这四条都会被写进交付物。

---

## 三、AI 产出成果清单

**由 AI 生成、我逐条验证后使用的**

- `superset/provision.py` 的整体骨架（幂等 upsert、adhoc metric 构造、layout 生成）
- `dashboard/echarts/index.html` 的 7 个面板配置（双轴、气泡散点、横向条形）
- `app/app.py` 的 `ask_with_repair()` 自修复循环
- `python/bench_query.py` 四个实验的执行框架（线程池、P50/P95 统计）
- `tools/shot.js` 的 CDP 调用骨架
- 六份文档的初稿结构与措辞打磨

**由人工编写、AI 未参与的**

- 全部口径判断：热力图用"行内归一化"而不是绝对金额或订单数；地图用 ISO 而不是省名
- 压测判据的更换（从秒表 → `EXPLAIN DEPENDENCY`）
- 所有"AI 说能优化、实测没优化"的结论反转（MAPJOIN、两阶段聚合）
- 交叉筛选的三项配置检查与"未验证通过"的如实记录

---

## 四、本周协同效率自评

| 环节 | 用时占比 | 说明 |
|---|---|---|
| AI 生成可用骨架 | ~35% | 建表参数、前端面板配置、脚本框架，产出速度快 |
| 人工验证与纠偏 | ~50% | **本周一半以上时间花在"验证 AI 说的对不对"上** |
| 纯人工定位 | ~15% | 地图关联键、热力图口径、FEATURE_FLAGS 覆盖，这三处 AI 都没找对 |

一句话总结：**这周 AI 帮我"写得快"，但没帮我"写得对"**。12 条记录里 6 条被驳回或改写，
驳回的原因高度集中在同一类——AI 给的是"通用最佳实践"，而本项目的约束是"这个版本 + 这个数据"。
所以流程必须是：AI 出方案 → **跑一遍** → 用实测结果决定采纳与否，而不是用逻辑自洽度决定。
