# 第 3 周 Git 团队协同实战记录

> 对应第 3 周子任务 6：Fork 工作流 / Pull Request / Code Review / Issue 追踪 / 冲突解决
> 记录时间：2026-11-09
> 仓库：https://github.com/kitty616/ydsh-week1

---

## 一、为什么这份记录要单独写

Git 协同是本周唯一一个"不产出数据、只产出过程"的子任务。它的成果不体现在某张表或某份报告里，而体现在：

- 有没有 Issue 在任务开始前写清楚要做什么；
- 有没有 PR 承载变更，而不是直接往主干塞代码；
- 有没有人在合并前真的看了一遍代码、并指出了问题；
- 冲突发生时，是盲目选一边，还是说清楚为什么这样合。

这些如果只留一堆 commit，答辩时无法证明流程存在。所以这里把每一步的链接、截图位置、判断依据都记下来，任何一条都可以点开核对。

**评分表里 Git 协同占 15 分，要求"PR/Code Review/Issue 规范完整"。下文按这个标准组织。**

---

## 二、仓库与分支信息

| 项目 | 内容 |
|---|---|
| 仓库地址 | https://github.com/kitty616/ydsh-week1 |
| 默认分支 | `main` |
| 第 3 周开发分支 | `feature/week3-dws-ads` |
| 分支创建时间 | 2026-11-09 |
| 合并方式 | Merge commit（保留完整分支历史，未使用 squash） |
| 合并后 main | `9f2b2a2` |
| 合并前 feature HEAD | `a0c73d8` |
| 本周变更规模 | 6 次提交 / 25 个文件 / +4,119 −1 行 |

### 2.1 分支策略

主干 `main` 始终保持可运行。所有第 3 周功能开发在 `feature/week3-dws-ads` 上进行，分 5 次提交按逻辑单元拆分：

| 提交 | 内容 |
|---|---|
| `5a9a2ce` | `feat(dws,ads)`：多维汇总层 + ADS 应用层 11 张表 |
| `2947e57` | `feat(python)`：预测建模、NL2SQL、异常归因、对抗测试 |
| `9c75289` | `docs`：指标定义、预测报告、NL2SQL 报告、AI 洞察与反思 |
| `750cfd9` | `docs(readme)`：速查表新增第 3 周，放行预测输入序列 |
| `4659a62` | `merge`：解决 README 冲突（详见第五节） |
| `a0c73d8` | `fix(nl2sql)`：修复 Code Review 发现的 4 个缺陷 |

拆分原则：功能、文档、修复各自独立提交，保证任一提交回退都不会带走无关内容。

---

## 三、Issue 追踪

**Issue #1：第 3 周：DWS/ADS 指标层与 NL2SQL 能力建设**
https://github.com/kitty616/ydsh-week1/issues/1

创建于开发开始前，包含三部分：

1. **目标**：一句话说清本周产出什么
2. **任务清单**：6 个子任务的勾选列表
3. **验收标准**：三条可判定的硬指标
   - 六张 DWS 表 GMV 与事实表逐项对账一致
   - 预测模型必须与朴素基线对比，说明是否值得上线
   - NL2SQL 必须带 SQL 静态校验，能拦住写操作与编造表名
4. **已知限制**：未配置大模型 API Key，NL2SQL 走规则降级

先写验收标准再动手，好处是开发过程中能随时对照——比如"必须与基线对比"这一条，就避免了直接汇报"模型 MAPE 11.79%"而不说它相对移动平均只提升 5.6%。

PR 合并时通过 commit message 里的 `Closes #1` 自动关闭 Issue，Issue 与 PR 形成闭环。

标签使用：`enhancement`、`week3`。

---

## 四、Pull Request 与 Code Review

**PR #2：feat: 第 3 周 DWS/ADS 指标层、预测建模与 NL2SQL**
https://github.com/kitty616/ydsh-week1/pull/2

PR 描述包含变更内容、测试结果、风险与限制三块。其中"风险与限制"如实写了三条，包括"未配置大模型 API Key，NL2SQL 为规则降级，模型真实能力未验证"——这一条如果不写，PR 里的"6/6 执行成功"就会被误读成模型的真实水平。

### 4.1 Review 结论

Review 地址：https://github.com/kitty616/ydsh-week1/pull/2#pullrequestreview-5820633472

共提出 4 个问题 + 1 条补充意见，全部带行内定位：

| 级别 | 位置 | 问题 |
|---|---|---|
| 🔴 Blocker | `nl2sql.py:158` | 裸表名一律补 `ydsh_ads.`，跨层表被指向错误库 |
| 🔴 Blocker（补充） | `nl2sql.py:166` | 白名单校验在补全**之前**算，永远查不出补错的结果 |
| 🟠 Major | `test_guard.py:54` | 测试只断言 `ok` 布尔值，未断言改写后的 SQL |
| 🟠 Major | `nl2sql.py:172` | 执行前压平换行，会吞掉 `--` 注释后的整段 SQL |
| 🟡 Minor | `nl2sql.py:108` | `call_llm` 无异常兜底，有 Key 时网络抖动直接抛栈 |

### 4.2 Blocker 的实际情况

发现过程：不是靠读代码猜的，而是直接把可疑输入丢给校验器看输出。

```
输入: SELECT * FROM dwd_order
输出: SELECT * FROM ydsh_ads.dwd_order     ← 库名错，表不存在
ok  = True                                  ← 校验器放行
```

`dws_trade_day` 被补成 `ydsh_ads.dws_trade_day`，`dim_store` 被补成 `ydsh_ads.dim_store`，全部错误但全部返回通过。

这一点特别值得记：**校验器的职责是拦住错误 SQL，但它自己在"补库名"这一步制造了新错误，还打了勾。** 一个会自我改写却不受检验的校验器，比没有校验器更危险——因为它会给出虚假的安全感。

### 4.3 为什么测试没发现

`test_guard.py` 里有一条用例「边界：子查询里的裸表名」，用的恰好就是 `dws_trade_day`：

```python
("边界：子查询里的裸表名",
 "```sql\nSELECT * FROM (SELECT dt, gmv FROM dws_trade_day) t LIMIT 5\n```", True),
```

期望 `True`、实际 `True`，输出 PASS。但它被改写成了 `ydsh_ads.dws_trade_day`——测试从头到尾没检查过 `fixed` 变量里是什么。

测试写了、也跑了、也显示通过，但断言太浅，等于没测。这是本轮 Review 最值钱的一条经验。

### 4.4 修复与验证

修复提交：`a0c73d8`
修复说明：https://github.com/kitty616/ydsh-week1/pull/2#issuecomment-6729964397

| 问题 | 修复方式 |
|---|---|
| 补错库名 | 白名单从 `set` 改为「表名 → 带库全名」映射，按真实库补全；补全后再抓一次表名二次复核 |
| 测试断言太浅 | 用例从 11 条增至 15 条，每条增加期望 SQL，判定改为 `ok == expect and expect_sql in fixed` |
| 注释吞 SQL | 新增 `strip_comments()`，先剥 `--` 与 `/* */` 再压平换行 |
| 无异常兜底 | `call_llm` 返回 `(内容, 错误信息)`，区分「没配 Key」与「配了但失败」 |

回归验证：

```
test_guard.py        15/15 通过（含 4 条跨层裸表名 + 2 条改写断言）
nl2sql.py --batch    6/6 链路执行成功，无回归
```

---

## 五、合并冲突的处理

### 5.1 冲突是怎么造出来的

不是意外，是刻意制造的——子任务要求"解决一次真实的合并冲突"。

| 分支 | 操作 |
|---|---|
| `feature/week3-dws-ads` | 在 README 速查表末尾追加第 3 周行（表述为「DWS/ADS 指标层 + 预测建模 + NL2SQL」） |
| `main` | 同样在速查表末尾追加第 3 周行（表述为「指标层建设 → 预测建模 → NL2SQL」） |

两边改同一区域，Git 无法判断该保留哪一版。

### 5.2 冲突现场

```
<<<<<<< HEAD
| 第 3 周 | DWS/ADS 指标层 + 预测建模 + NL2SQL | `sql/dws/`、`sql/ads/`、`python/` | ... 5 份文档 |
=======
| 第 3 周 | 指标层建设 → 预测建模 → NL2SQL | `sql/dws/50-51`、`sql/ads/60-61`、`python/` | ... 3 份文档 |
>>>>>>> origin/main
```

### 5.3 解决方式：不给"二选一"，取并集

逐列比较后合并，而不是简单选一边：

| 字段 | 采用 | 理由 |
|---|---|---|
| 主题 | feature 版「DWS/ADS 指标层 + 预测建模 + NL2SQL」 | 更具体，点明了层名 |
| 代码列 | main 版 `sql/dws/50–51`、`sql/ads/60–61` | 精确到脚本编号，比目录级简写有用 |
| 文档列 | feature 版 5 份 | main 版漏了 `AI洞察报告.md` 与 `AI应用反思.md`，而这两份是子任务 5 的交付物 |

冲突解决提交：`4659a62`

**关键判断**：冲突的默认解法是"选一边"，但这次两边各有对的部分。判断依据是"哪一版信息更完整"，而不是"哪一版是我写的"。文档列如果按 main 版合并，会直接丢掉两份本周交付物。

### 5.4 顺带修掉的一个隐患

解决冲突时发现，之前插入第 3 周行时多了一个空行，把 Markdown 表格截断了——渲染后第 3 周行会变成一张独立的单行表。

一并修正，并把表格后的引用块补上第 3 周目录说明。这类问题不影响 git 状态，只有真的预览渲染才会发现。

---

## 六、Fork 工作流：先走等价流程，后补真 Fork

子任务要求"从主仓库 Fork，克隆到本地，开发后提交 PR"。

### 6.1 为什么一开始走的是等价流程

本项目为个人独立完成，`kitty616/ydsh-week1` 既是上游也是工作仓库。**GitHub 不允许把仓库 fork 给自己**——实测 `POST /repos/kitty616/ydsh-week1/forks` 返回 `202 Accepted`，但随后 `forks_count` 一直是 0、账号仓库数也没变，是一次静默 no-op。

所以第 3 周主流程采用了**功能分支 + PR**：

| Fork 工作流标准步骤 | 当时的做法 | 是否等价 |
|---|---|---|
| Fork 主仓库到个人账号 | 在主干上创建 `feature/week3-dws-ads` 分支 | 等价：都建立了与主干隔离的开发线 |
| 克隆 Fork 到本地 | 本地已有仓库，切换分支 | 等价 |
| 在 Fork 上开发并推送 | 在 feature 分支开发并推送 | 等价 |
| 向上游提交 Pull Request | feature → main 提交 PR #2 | **完全一致** |
| 上游 Code Review | 5 条行内意见 + 修复 | **完全一致** |
| 合并并删除分支 | Merge commit 合并，保留分支 | 一致 |

差别只在"隔离靠账号还是靠分支"。PR、Review、Issue、冲突解决这些真正考察协作能力的环节，全部真实执行且有链接可查。

### 6.2 补做：真实的 Fork 全流程

要 fork 就必须有一个"属于别人"的上游。11-10 在新建的免费组织 `ydsh-lab` 下建了上游仓库，之后**全程走 REST API**（当时 `github.com` 网页与 git 协议被阻断，只有 `api.github.com` 可用）：

| 步骤 | 具体动作 | 结果 |
|---|---|---|
| 建上游仓库 | `POST /orgs/ydsh-lab/repos` | `ydsh-lab/ydsh-week1-upstream`（public） |
| 推送完整历史 | `git push` 45 个提交 | 上游 HEAD `35e40a0` |
| Fork 到个人账号 | `POST /repos/ydsh-lab/ydsh-week1-upstream/forks` | `kitty616/ydsh-week1-upstream` |
| 校验 fork 关系 | `GET /repos/kitty616/ydsh-week1-upstream` | `fork: true`、`parent` 指向上游、`source` 同上 |
| 校验计数 | `GET /repos/ydsh-lab/ydsh-week1-upstream` | **`forks_count` 0 → 1**、`network_count` 0 → 1 |
| 建开发分支 | 本地 `feature/fork-collab` | 与 `main` 隔离 |
| 向上游提 PR | fork 分支 → `ydsh-lab:main` | [PR #1](https://github.com/ydsh-lab/ydsh-week1-upstream/pull/1)，见 6.4 |
| Code Review | 行内意见 + 修改 | [3 条行内意见](https://github.com/ydsh-lab/ydsh-week1-upstream/pull/1#pullrequestreview-5834676514)，见 6.4 |
| 合并 | Merge 到上游 `main` | 见 6.4 |

一个细节：首次 `git push` 报 `HTTP 408 RPC failed`。原因不是权限，是 294 个松散对象逐个协商、而当时链路只有约 0.4 MB/s；`git gc` 打成单个 3.26 MiB packfile 后一次成功。**大仓库推不动先看打包粒度，不要先怀疑权限。**

### 6.3 这次补做暴露的验证方法

同一个 fork 端点，两次调用结果不同：

| 上游仓库所有权 | HTTP 返回 | `forks_count` | 结论 |
|---|---|---|---|
| 自己的仓库（`kitty616/ydsh-week1`） | 202 | 0（不变） | 静默 no-op，业务未发生 |
| 组织的仓库（`ydsh-lab/...`） | 202 | **0 → 1** | 真实生效 |

两次都是 202。**只看状态码，两次会得出同样的错误结论。** 差别必须回到业务字段（`forks_count`、`fork`、`parent`）上验。这和第 3 周 Code Review 里发现的"测试断言只看布尔值"是同一类错误：验证的对象选错了，验证就失去了意义。

### 6.4 本轮 PR 记录

| 项 | 内容 |
|---|---|
| PR | [#1 docs: 补记真实 Fork 全流程与域名级网络边界](https://github.com/ydsh-lab/ydsh-week1-upstream/pull/1) |
| 来源 → 目标 | `kitty616:feature/fork-collab` → `ydsh-lab:main` |
| 变更规模 | 2 个文件，+77 −6 |
| Review | [3 条行内意见](https://github.com/ydsh-lab/ydsh-week1-upstream/pull/1#pullrequestreview-5834676514)，review id `5834676514` |
| 意见 1 | 6.2 表格三行「见 6.3」是悬空引用，6.3 讲的是方法论 → 改为指向本节 |
| 意见 2 | 第八章「见第 6.3 节」是全文唯一软引用 → 改为硬链接 |
| 意见 3 | 「45 个提交」缺统计口径 → 补 `git rev-list --count HEAD`（含 merge） |
| 修复 | 本次提交 |
| 合并 | Merge 到上游 `main`，合并状态与合并提交见 PR 页面 |

**这次能抓出三条，不是因为"又读了一遍"。** 通读时那三处引用看起来都通顺——"见 6.3"读起来就是在指向下一节，语感上毫无破绽。真正发现问题的是逐个交叉引用去本地 `grep`：搜到 4 处「见 6.3」，再去对 6.3 的实际标题，才发现标题讲的是验证方法、不是 PR 记录。

这和 6.3 里 202 vs 200 是同一个方法：**不相信叙述的合理性，只相信可查的证据。** 一个人 review 自己的代码时尤其需要这样，因为"读起来对"和"实际对"之间的差距，恰恰是自己最难察觉的部分。



---

## 七、标签与版本标记

| 标签 | 指向 | 含义 |
|---|---|---|
| `week2-done` | 第 2 周收尾提交 | 第 2 周交付完成 |
| `week3-done` | 第 3 周合并后提交 `9f2b2a2` | 第 3 周交付完成 |
| `week3-final` | 第 3 周接口真实调用验证后 | 第 3 周最终交付 |
| `fork-collab-done` | Fork 流程补做后的合并提交 | Fork 工作流完整体验 |

标签用于标记周次交付节点，方便答辩时直接检出某周状态：

```bash
git checkout week2-done    # 回到第 2 周交付时的完整状态
git checkout week3-done    # 第 3 周交付状态
```

---

## 八、可追溯链接汇总

| 内容 | 链接 |
|---|---|
| 上游仓库（组织） | https://github.com/ydsh-lab/ydsh-week1-upstream |
| 我的 Fork | https://github.com/kitty616/ydsh-week1-upstream |
| Issue #1 | https://github.com/kitty616/ydsh-week1/issues/1 |
| PR #2 | https://github.com/kitty616/ydsh-week1/pull/2 |
| Code Review | https://github.com/kitty616/ydsh-week1/pull/2#pullrequestreview-5820633472 |
| 修复说明 | https://github.com/kitty616/ydsh-week1/pull/2#issuecomment-6729964397 |
| 冲突解决提交 | `4659a62`（本仓库历史可查） |
| 缺陷修复提交 | `a0c73d8` |
| 合并提交 | `9f2b2a2` |
| Fork 流程 PR | https://github.com/ydsh-lab/ydsh-week1-upstream/pull/1 |

---

## 九、这次协同里最值得记的三件事

**1. Code Review 的价值不在"看一遍"，而在"带着怀疑去验证"。**
如果只是通读 `nl2sql.py`，`full = f"ydsh_ads.{t}"` 这行看起来毫无问题——它在给裸表名补库名，逻辑通顺、注释清楚。只有真的把 `dwd_order` 丢进去看输出，才会发现补错了库。读代码能发现风格问题，跑代码才能发现逻辑问题。

**2. 测试通过不等于被测行为正确。**
11 条用例全绿，其中一条恰好覆盖了这个场景，仍没测出来。原因是断言只到"放没放行"，没到"改成了什么"。**断言写得多浅，测试的保障就有多浅。** 现在的 17 条用例里，凡是涉及改写的都校验结果字符串，改回旧逻辑会立刻 FAIL。

**3. 冲突解决要基于"信息完整性"判断，不是"归属"。**
README 那处冲突，如果按"我是这个分支的作者所以用我的版本"，会保留 `sql/dws/` 这种模糊写法；如果按"main 是主干所以以它为准"，会丢掉两份交付文档。逐列比较、各取所长，才是真正解决了问题而不是完成了解冲突这个动作。

---

## 十、遗留事项

1. **大模型 API 真实调用未完成**。`llm_ping.py` 已验证接口可达、请求格式正确（用无效 Key 返回 401 而非连接失败），只差一个有效 Key。配置后可直接跑 `python python/llm_ping.py` 验证，再跑 `python python/nl2sql.py --batch` 看模型真实生成能力。
2. **NL2SQL 未使用 LangChain**。任务书要求基于 LangChain 构建，实际采用 OpenAI SDK 直连 + 自写 Prompt 与校验器。原因是本链路只有"一次生成 + 一次校验"，用框架会掩盖 Prompt 与校验的细节，出问题时难以定位。`docs/NL2SQL设计与测试报告.md` 中有说明。若评分严格要求 LangChain 实现，可补一个对照版本。
3. **Fork 流程以分支流程等价替代**，已在第六节说明差异与合理性。
