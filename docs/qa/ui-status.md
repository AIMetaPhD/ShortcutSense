# G-UI 现状盘点（2026-10-27）

对照 `09_UI_UX_PRODUCT_REQUIREMENTS.md` 与 `11_MUSE_UI_QA.md` 的 18 项 AC-UI。

## 已实现（可复用，不推倒）

| 组件 | 位置 | 状态 |
|---|---|---|
| NSStatusItem 菜单栏入口 | `AppDelegate.swift` | 有图标和菜单；**无紧凑 popover** |
| 独立 NSWindow 仪表盘 | `AppDelegate.swift` | 有，860×600，可调整 |
| 侧栏导航（6 项） | `RootView.swift` | Today / Shortcuts / Opportunities / Conflict / Weekly / Settings 全在 |
| Today（基础版） | `RootView.swift:66` | 有暂停开关、隐私说明、按应用的活动列表 |
| Shortcuts | `RootView.swift:132` | 有 7 天组合键排行表，按次数排序 |
| Opportunities | `Views.swift:11` | 有候选卡、Apply / Dismiss、Apply 前重新检查冲突 |
| Conflict Check | `Views.swift:240` | 四态 + 证据来源 |
| Weekly Review | `Views.swift:309` | Preview / Report 区分、生成时间、实测采纳数 |
| Settings | `Views.swift:372` | 权限分列、排除列表、AI 开关、删除数据 |

共 633 行 SwiftUI，全部绑定真实 store，无假数据。

## 缺失（AC-UI 要求，当前没有）

| AC-UI | 缺什么 |
|---|---|
| 01 | **紧凑 popover**（360–420pt，含 Open Dashboard / Pause / Settings） |
| 02 | 最小 880×620 的布局验证与滚动处理 |
| 03 | **Today hero**（蓝色大数字）、**3 个 KPI 卡**（快捷键触发/活跃应用/自管热键触发） |
| 04 | **快捷键热力图**（键盘图形，只用组合键着色，绝不画单字母） |
| 05 | **Top 5 快捷键** + 应用筛选 + 时间范围选择 |
| 06 | **活动时间线**（真实小时聚合，未启用则诚实显示 7 天曲线） |
| 07 | **Top Apps 排行**（图标、名称、按键数、比例条） |
| 08 | 推荐卡需要置信度/日期证据的可读呈现（部分已有，需按规格重做） |
| 09 | **推荐详情页**（为什么推荐、限制、冲突、预期效果标 estimated） |
| 10 | 冲突页需支持**任意组合键查询**，目前只看 6 个预选 |
| 11 | 周报已有，需补覆盖日期范围的可读展示 |
| 12 | 权限状态已有，需补 stale / 撤销后的可见提示 |
| 13 | 删除需真正清空仪表盘视图（当前需手动刷新） |
| 14 | AI 开关已可用，需补"无 Ollama 时不出现坏视图"的验证 |
| 15 | **中英双语 + 明暗主题**：有 loc() 但有硬编码英文，需系统性检查 |
| 16 | **键盘导航 / VoiceOver 标签**：完全没有 |
| 17 | **全新安装各状态**：无权限/部分权限/无数据/暂停/应用被卸载 |
| 18 | 需从 Release 产物安装后截图 |

## 数据层缺口

`12_UI_DATA_CONTRACT_DELTA.md` 指出 Today 需要的几项现在没有直接查询：

- `Today.total_keypresses` — 可从 `daily_app_activity` 求和，需加查询
- `Today.shortcut_uses` — 可从 `daily_combo_stats` 求和，需加查询
- `Today.apps_used` — 可从 `daily_app_activity` 去重 bundle id，需加查询
- `Today.managed_hotkey_triggers` — 已在 `applied_shortcut_usage_daily`
- `hourly_keyboard_activity` 表 — **不存在**，需新增（默认关闭，P1）

## 下一阶段实施顺序

1. **数据层**：新增 `TodayMetrics` 查询 + 迁移到 schema v2（含 hourly 表，默认不采集）
2. **组件库**：MetricCard、HeroSummary、ComboHeatmap（原生 SwiftUI 绘制键盘）、TimelineChart、TopAppsList
3. **Today 重做**：hero + KPI + 热力图 + 时间线 + Top Apps + 机会卡
4. **紧凑 popover**
5. **推荐详情页** + Apply/Undo 流程的可视化反馈
6. **可访问性**：VoiceOver 标签、键盘焦点、动态字体
7. **双语与主题**系统化
8. **空态矩阵**：17 种状态
9. **Muse 真机验收** 18 项

## 结论

前端不是"从零"，但离消费级还差一个完整的仪表盘层。现有 633 行可保留为骨架，
Today 和 Shortcuts 两个页面需要按规格重做，其余四个页面以补齐细节为主。
