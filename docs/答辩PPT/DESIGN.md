# DESIGN.md · 第 5 周综合答辩

## 全局视觉约定

- 画布 1280×720，padding 60（内容区 1160×600，y 60–660）
- 四区：页眉 y60–92（eyebrow）｜标题 y100–141｜正文 y157–638｜页脚 y660–676
- 配色：主蓝 `#1E4FA8`、藏蓝 `#0E3F8C`、中蓝 `#3D7BD9`、浅蓝底 `#F0F5FC` / `#E8EFF8`、
  正文 `#1A2230`、副文 `#4A5568`、辅助 `#8B97A8`、线 `#D6DCE5`、
  警示红 `#D9534F`（≤3%）、数据黄 `#FFC107`（≤3%）；背景 `#FFFFFF` / `#F7F9FC`；金色 = 0
- 字体：中文思源黑 / 系统无衬线；西文同族。字号阶梯：封面主标 64 / 页面主标 34 /
  KPI 巨数字 80 / 卡内标题 22–24 / 正文 18–20 / 注解 14–15
- 视觉母题：每页标题下 1px 贯通细线（`#D6DCE5`）+ 右上角章节标记；全篇只此一处装饰
- 页脚：左「云购生活数据仓库项目组」14px 灰，右页码 14px 深蓝

## 配图清单

| 文件 | 用途 | 来源 | 内容 | 使用页 |
|---|---|---|---|---|
| `assets/wall.png` | L1 证据 | 项目截图 | ECharts 七面板数据大屏 | P11 |
| `assets/superset.png` | L1 证据 | 项目截图 | Superset 八图仪表板 | P11 |
| `assets/qa.png` | L1 证据 | 项目截图 | Streamlit 问答界面 | P11 |

## 逐页设计

| # | title | type | role | rhythm | layout | visual | density | anti_pattern |
|---|---|---|---|---|---|---|---|---|
| 01 | 云购生活 · 企业级数据仓库与经营分析可视化系统 | cover | hero | peak | 深蓝顶条 + 论文式主标 + 底部信息条 | 无图，靠排版 | 约 60 字 / 0 图 / 留白 40% | 禁人物照；禁红金 |
| 02 | 一页看懂：7 个位置同一个数 | content | hero | peak | 三联 KPI + 四层链路条 | SVG 链路 | 约 160 字 / 1 图 / 留白 15% | 禁等宽四卡；禁把巨数字塞进卡片角落 |
| 03 | 目录 | catalog | supporting | valley | 左深蓝栏 + 5 条编号 | 无 | 约 90 字 | 禁圆球编号 |
| 04 | 01 业务与目标 | section | transition | transition | 大数字 + 标题 + 3 要点 | 无 | 约 70 字 | 禁四卡预览 |
| 05 | 四个困境，一个目标 | content | supporting | valley | 双栏：左痛点 / 右目标 + 底部结论条 | 无 | 约 300 字 | 禁 50:50 对称无连接 |
| 06 | 02 架构与数据 | section | transition | transition | 同上 | 无 | 约 70 字 | 禁与 P04 雷同 |
| 07 | 四层数仓：每层都能独立对账 | content | supporting | valley | 横向流程 + 下方规模表 | SVG 流程 | 约 260 字 | 禁纯表格铺满 |
| 08 | 数据治理：99.73% 修复率怎么来的 | content | supporting | valley | 左表 + 右三条判断 | 无 | 约 280 字 | 禁只摆百分比不给判断 |
| 09 | 联调抓到的真问题：0.97% 的钱去哪了 | content | hero | peak | 四步诊断链 + 右侧结论 | SVG 诊断链 | 约 280 字 | 禁平铺四卡；禁把结论藏在角落 |
| 10 | 03 应用与交付 | section | transition | transition | 同上 | 无 | 约 70 字 | 禁四卡预览 |
| 11 | 三端交付：BI / 大屏 / 问答 | content | supporting | valley | 三图并排 + 底部结论 | 3 张截图 | 约 120 字 / 3 图 | 禁图片拉伸变形；禁无说明的截图 |
| 12 | 预测与问答：都能给出可复核的结果 | content | supporting | valley | 左右双栏 + 数据锚点 | 无 | 约 260 字 | 禁只贴指标不对比基线 |
| 13 | 一键部署：7 个服务，口令零明文 | content | supporting | valley | 服务表 + 右侧验收清单 | 无 | 约 250 字 | 禁堆命令行截图 |
| 14 | 04 复盘 | section | transition | transition | 同上 | 无 | 约 70 字 | 禁四卡预览 |
| 15 | 三条教训与下一步 | content | supporting | valley | 三行教训 + 改进清单 | 无 | 约 280 字 | 禁 emoji；禁空话式「持续优化」 |
| 16 | 谢谢 · 请提问 | ending | hero | peak | 与封面同体系 | 无 | 约 30 字 | 禁烟花金饰 |
