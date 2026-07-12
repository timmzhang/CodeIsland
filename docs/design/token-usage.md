# Token 用量统计与洞察 — 设计终稿

> 需求讨论任务：p-wb9y（2026-07-11 定稿）
> 视觉稿：本目录 [`token-usage-mockup.html`](token-usage-mockup.html)（可交互，直接浏览器打开）；在线版 https://claude.ai/code/artifact/d5a46d94-b6f3-48ca-86c8-7d084fdae4ac
> 目标：洞察自己一天/一周消耗多少 token、每个 AI 工具各消耗多少。

## 1. 产品设计

三层信息架构，各层只回答一个问题：

### L1 · notch 面板 — 「今天烧了多少」
- **收起态**：现有会话状态右侧常驻「今日用量」徽标 —— token 总量 + 等效成本 + 近 7 日迷你柱（今天高亮）。约占 90pt 宽，设置可关。
- **展开态**：顶部工具栏右上角放下划线文字入口「今日 token 燃烧 N.NM」，点击打开 L2 统计窗口；面板内新增分区，按工具列今日小计条 + cache 命中率。

### L2 · 统计窗口 — 完整报表
独立窗口（与 Settings 同级）：
- 顶部 4 张汇总卡：今日 tokens / 等效 API 成本 / cache 命中率 / 活跃会话数
- 中间：日/周切换的按工具堆叠柱状图，柱子悬停出明细 tooltip，柱顶标当日合计
- 底部：工具 × 模型 明细表，input / output / cache 写 / cache 读 / 等效成本 / 占比分列

### L3 · 周报洞察 — 「烧在哪、什么时候烧的」
统计窗口第二个 tab：本周总量 + 环比、日均与峰值、Top 项目、Top 工具占比、7×12（每格 2 小时）活跃时段热力图。文案可复制作周报素材。

## 2. 五个决策点（2026-07-11 全部拍板）

| # | 问题 | 结论 |
|---|------|------|
| 1 | cache 读是否计入主图 | 否。主图口径 = input + output；cache 读写进汇总卡和明细表（cache 读单价约 input 的 1/10、量级大 10 倍以上，混入柱子失真） |
| 2 | 成本怎么标 | 统一叫「等效 API 成本」+ 脚注说明订阅用户不按此付费；它表示"同样用量走 API 要花多少" |
| 3 | L1 徽标常驻 vs 悬停 | 默认常驻，设置可关 |
| 4 | 统计窗口入口 | 展开面板右上角下划线文字「今日 token 燃烧 N.NM」（参考竞品形态） |
| 5 | 统计不到的工具（Cursor/Copilot 等 IDE 类） | 不出现在图表，仅明细表脚注声明「未列入」 |

## 3. 技术方案

### 数据源（per-tool UsageProvider 扩展点）

| 工具 | 数据源 | 状态 |
|------|--------|------|
| Claude Code | `~/.claude/projects/**/*.jsonl` assistant 消息的 `message.usage`（input/output/cache_creation/cache_read + model），JSONLTailer 已有 tail 管道 | ✅ 已验证 |
| Codex | app-server 事件流 token 计数（CodexAppServerClient 已连接）；`~/.codex/sessions` rollout jsonl 可回填 | ✅ |
| Gemini CLI | `~/.gemini/tmp` telemetry/session stats | ⚠️ 待验证 |
| IDE 类（Cursor/Copilot…） | 无公开数据 | ❌ 不支持 |

### 关键设计
- **去重**：同一 assistant 消息因 streaming/retry 会在 jsonl 里重复落行，用 `messageId + requestId` 去重（ccusage 验证过的坑）
- **回填**：首启全量扫描历史 jsonl 一次性回填（逐行 `"usage"` 子串预筛再 JSON 解析，控制并发）；之后增量 tail
- **存储**：SQLite 小时级聚合行 `(date_hour, tool, model, input, output, cache_write, cache_read)`，每天几百行封顶；以本地库为准，transcript 被清理/compact 不丢数不重复
- **口径**：subagent/sidechain 的 usage 计入，保留 top-level/subagent 维度可区分
- **成本**：内置 model→单价表随版本更新，Settings 可覆盖
- **隐私**：全本地计算，不上传

### 图表实现与配色
SwiftUI Charts（macOS 13+）。系列色已通过色盲区分度/对比度校验（暗面 `#111318`，5 系列全过）：

| 系列 | 色值 |
|------|------|
| Claude | `#d95926` |
| Codex | `#199e70` |
| Gemini | `#3987e5` |
| Kimi | `#c98500` |
| 其他 | `#9085e9` |

图形规范：堆叠段之间 2px 间隙、顶段 4px 圆角、悬停 tooltip、图例常显；热力图用蓝色单色渐变 `#181d26 → #86b6ef`。

## 4. 实施分期

- **P1（MVP）**：Usage 数据模型 + SQLite 聚合存储 → Claude Code 采集与历史回填 → 统计窗口（汇总卡 + 日/周堆叠图 + 明细表）→ notch L1 徽标与右上角入口
- **P2**：Codex 接入、等效成本折算、Top 排行
- **P3**：周报洞察 tab、其他 CLI 工具 UsageProvider 适配
- **待定（未纳入）**：竞品顶栏的 5h/7d 订阅限额用量条
