# G-A / G-B / G-C 状态（2026-10-27）

按 `ShortcutSense_v3_final_decision_2026-10-27.md` 执行。**未发布**，仓库保持 Private。

---

## G-A：Ollama 收尾 — **PASS（1 项 NOT-RUN）**

| 项 | 状态 | 证据 |
|---|---|---|
| D-035 / D-036 已修 | **PASS** | `docs/qa/ollama-acceptance.md`；真机 `/api/tags` 发现 `qwen3.5:9b`、`qwen3:14b`；一次 `/api/generate` 真调用 9.4 s、`used_fallback=false` |
| 不夸大「绝对本地」 | **PASS** | README 中英双段明确写出：客户端只能证明环回、拒绝重定向、无云端标记；**无法**证明用户的 Ollama 服务端不代理云端，并指向 `OLLAMA_NO_CLOUD=1` |
| 只发结构化聚合字段 | **PASS** | 字段白名单测试；`AIExplanationRequest` 9 个固定字段 |
| Settings 显示真实模型 → 点分析 → 显示结果与 fallback 来源 | **PASS** | Owner 实机截图：`已连接，检测到 2 个本地模型`、`qwen3:14b (9.28 GB)`、绿色 `本地模型 qwen3:14b`、20,260 ms |
| 关闭服务/AI 不冻结窗口 | **PASS** | 20 秒等待期间界面可操作 |
| 允许时能启动已安装的 Ollama | **NOT-RUN** | Ollama 本就在运行，未触发该路径 |

Muse 第四轮静态审阅：10 项不变量全 PASS，指出 3 个问题（S2 关闭后竞态、S3 探针旁路、S4 注释与实现不符），已全部修复。

---

## G-B：菜单点击 Spike — **工具就绪 / 测量 BLOCKED-GUI**

**工具**：`ShortcutSense --menu-spike [秒数]`

- 用应用自身的 TCC 身份运行（已实测 `accessibilityGranted: true`、`inputMonitoringGranted: true`）
- 逐次点击分类为：`staticHit`（可用的静态菜单命令）、`rejectedDynamic`（标题像用户数据，已拒绝）、`nonMenu`（页面正文/按钮/空白）
- 只写计数、bundle id 和已过滤的静态标题；**不写窗口标题、文件名、坐标或点击流**
- 报告：`~/Library/Application Support/ShortcutSense/menu-spike-report.json`

**操作协议**：`docs/qa/G-B-protocol.md`，约 8 分钟，门槛为每 App ≥6/7 命中、误报 0。

**当前**：工具已验证可启动并写出报告，但**没有任何真实点击数据**。按裁定书，G-B 结论必须来自真人点击，因此标 `BLOCKED-GUI`，不预判通过。

**降级路径已确定**：若命中率不足或出现误报，立即改用「当前 App 菜单快捷键扫描 + 用户明确 ManualMark」，不再投入全局鼠标归因。

---

## G-C：最小价值闭环 — **部分完成**

### 已完成：工作区一键启动 / 撤销

| 能力 | 状态 | 证据 |
|---|---|---|
| `launchOrFocusWorkspace(bundleIDs:)` | **PASS** | `ShortcutActionManager.applyWorkspace`，测试覆盖 |
| 白名单强制执行 | **PASS** | 只接受 2–3 个**已安装**应用；少于 2 或多于 3 被拒；任一未安装则整体拒绝，且不注册热键 |
| 不执行任意脚本/URL | **PASS** | `ShortcutActionKind` 只有 `launchApp` / `launchWorkspace` 两个取值，没有第三种 |
| 一键绑定 Carbon 热键、真实触发 | **PASS（逻辑）** | 按下后按顺序启动/前置全部成员；一次按键只计一次触发 |
| Undo 释放 | **PASS** | 注销热键并删除记录 |
| 重启恢复 | **PASS** | 恢复时使用**完整列表**而不是首个 bundle（此处修了一个真实缺陷） |
| Schema v3 加法迁移 | **PASS** | 旧行默认 `launch_app`，读回不丢失 |

### 未完成（下一轮）

| 项 | 原因 |
|---|---|
| 受控 T1 Opt-in 与结构化序列聚合 | 尚未实现 |
| 跨天重复应用组发现 → 生成工作区建议 | 依赖 T1 |
| ManualMark 界面 | 尚未实现 |
| Learn 推荐带来源/置信度 | 依赖 G-B 结论 |
| 第一周诚实进度 + 快捷键速查 | 尚未实现 |
| 本地模型对候选模式排序 | 未接线 |

---

## 测试与构建

| 项 | 结果 |
|---|---|
| 单元测试 | **220 项**，Linux 与 macOS 真机一致通过 |
| macOS 构建 | 通过，证书签名，指定要求跨重建稳定 |
| 应用部署 | `/Applications/ShortcutSense.app`，运行中 |
| CI | 见仓库 Actions |

---

## 剩余阻断项

1. **G-A 的 GUI 验收**（3 项）：需要人在 Mac 前操作
2. **G-B 的真实点击测量**：需要人按协议点击 8 分钟；这是 G-C 里 Learn 是否可自动化的前提
3. **G-C 的 T1/ManualMark/Learn**：等 G-B 结论决定 Learn 的形态，T1 可并行
4. **公开发布**：未获批准，仓库保持 Private

## 需要 Owner 的最小行动

两件，按顺序：

1. 按 `docs/qa/G-B-protocol.md` 跑一次 8 分钟的点击测量（这一步决定 Learn 走自动还是手动）
2. 在应用里打开设置 → 本地 AI → 看模型是否显示 `qwen3.5:9b` → 到推荐详情点「用本地 AI 分析」，截个图

其余我可以在你做完第 1 项后继续推进 T1 与 ManualMark。
