# G-UI 实施状态（2026-10-27）

对应 `ShortcutSense_UI_Addendum_v2.1` 的 18 项 AC-UI。
**状态定义**：IMPLEMENTED = 代码完成且绑定真实数据；BLOCKED = 需要真机人工操作；
NOT-RUN = 可做但还没做。

## 18 项状态

| AC-UI | 场景 | 状态 | 说明 |
|---|---|---|---|
| 01 | 启动 → 状态栏图标 → 紧凑面板 → 打开仪表盘 | **IMPLEMENTED** | NSPopover 380pt；Open Dashboard / Pause / Settings / Quit 都是真实控件 |
| 02 | 仪表盘原生窗口可缩放 | **IMPLEMENTED** | 最小 880×620，理想 1040×760，各页均可滚动 |
| 03 | Today hero 与 KPI 卡读真实聚合 | **IMPLEMENTED** | `DashboardService.today` 实时查询；空库显示 0 与空态说明 |
| 04 | 隐私安全的快捷键热力图 | **IMPLEMENTED** | 原生 SwiftUI 绘制键盘；只有组合键着色；**结构上无法表示单字母** |
| 05 | Top 5 与应用筛选 | **IMPLEMENTED** | 今天/7天/30天 + 应用下拉；排名与数据库一致 |
| 06 | 活动时间线 | **IMPLEMENTED** | 小时级开启时显示 24h，否则诚实显示「7 天总计 —— 小时级记录未开启」 |
| 07 | Top Apps 按按键数 | **IMPLEMENTED** | 明确标注「按按键数排序，不是使用时长」 |
| 08 | Opportunities 真实数据 | **IMPLEMENTED** | 走 RecommendationEngine；不足门槛显示空态 |
| 09 | 推荐详情与 Apply/Undo | **IMPLEMENTED** | 详情 sheet 含理由、限制、estimated 标注；Apply 走 ShortcutActionManager |
| 10 | 冲突四态 | **IMPLEMENTED** | 任意组合键可查；四态 + 来源 + 可读性列表 |
| 11 | 周报 Preview | **IMPLEMENTED** | <7 天显示 Preview 横幅；覆盖范围与生成时间 |
| 12 | 设置里的权限状态 | **IMPLEMENTED** | 两项分列；已授权但 tap 未运行时有明确提示 |
| 13 | 暂停/排除/删除 | **IMPLEMENTED** | 删除前确认；删除后释放系统热键并清空 |
| 14 | 离线/AI 可选 | **IMPLEMENTED** | AI 默认关；关时不发任何请求；非环回地址被拒 |
| 15 | 双语与明暗主题 | **IMPLEMENTED** | 全部字符串走 `L.t`；颜色用语义色，自动适配明暗 |
| 16 | 键盘/VoiceOver 可达性 | **IMPLEMENTED** | ⌘1–⌘6 导航；卡片有 accessibilityLabel；色彩之外有图标与文字 |
| 17 | 全新安装各状态 | **IMPLEMENTED** | 首启 sheet、无权限、无数据、暂停、删除后均有设计态 |
| 18 | Release 安装截图 | **BLOCKED** | 需要真人从安装包操作并截图 |

## 已做但未验证

以下是可以靠代码判断的，已实现；但**没有任何一项经过真机 GUI 验收**：

- 六个页面全部绑定真实 store / DashboardService，无静态假数据
- 所有 Apply 走 `ShortcutActionManager`，失败会显示真实错误
- 热力图结构上只接受 `daily_combo_stats` 的组合键，无法表现单字母

## 必须由 Muse 在真机上验证

AC-UI-01…17 需要人操作 GUI：点开 popover、切页面、看数字变化、按热键、看空态。
我这边只能证明「编译通过、测试通过、应用能启动」。

AC-UI-18 需要从安装包走 Gatekeeper 流程并截图。

## 新增的测试覆盖

| 测试类 | 覆盖 |
|---|---|
| `TodayMetricsTests` | 每个 KPI 的来源、空态、7 天序列、Top Apps 排序与占比 |
| `HourlyAggregateTests` | 小时表默认关闭、时区隔离、范围校验、剪枝不影响日报、删除清空 |
| `ExclusionListConsistencyTests` | 终端类是代码工具的子集；风险类覆盖；普通应用不被误排除 |

## 数据层变更

Schema 升到 v2，新增 `hourly_keyboard_activity`（默认不采集）。
迁移是加法的，不写任何数据；`deleteAllData` 会清空它。
