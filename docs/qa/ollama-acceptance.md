# Ollama 验收记录（D-035 / D-036）

**日期**：2026-10-27
**环境**：macOS 26.6.2 (25G83) arm64，Apple Swift 6.3.3，Command Line Tools（无 Xcode）
**构建**：`Scripts/build-app.sh`，自签名证书（`ShortcutSense Local Signing`）
**测试**：209 项全部通过（Linux / 真机 / CI 一致）

本文件记录开发侧的真机证据。**独立 GUI 验收由 Muse 完成**，见文末。

---

## 1. 修复前的状态

| ID | 问题 | 证据 |
|---|---|---|
| D-035 | `AppController.explain()` 有实现，但没有任何界面调用。打开 AI 开关后不会有任何请求发出 | 全仓库搜索调用点为零 |
| D-036 | 模型名硬编码 `qwen2.5:7b`；本机实际安装 `qwen3.5:9b`、`qwen3:14b` | `curl 127.0.0.1:11434/api/tags` |

---

## 2. 修复后的真机证据

### 2.1 真实发现与真实生成

`ShortcutSense --ai-probe`（只输出非敏感元数据，不含 prompt 或模型正文）：

```
discovery_status=connected
discovery_latency_ms=14
models=qwen3.5:9b,qwen3:14b
local_models=qwen3.5:9b,qwen3:14b
cloud_models=
selected_model=qwen3.5:9b
generation_latency_ms=9387
used_fallback=false
fallback_reason=none
category=efficiency
explanation_characters=201
exit=0
```

- 模型列表来自 `/api/tags`，**没有任何硬编码**
- `qwen3.5:9b` 是自动选中的（本机已安装的第一个本地模型）
- 一次真实的 `/api/generate` 调用，解析成功，`used_fallback=false`

### 2.2 失败路径

| 场景 | 命令 | 结果 |
|---|---|---|
| 服务健康 | `--ai-probe` | `connected`，8–10 s，解析成功 |
| 端口关闭（服务未运行） | `SHORTCUTSENSE_OLLAMA_URL=http://127.0.0.1:59999` | `installed_not_running`，8 ms 内失败，不卡界面 |
| 非环回地址 | `SHORTCUTSENSE_OLLAMA_URL=http://192.168.1.50:11434` | `failed:The endpoint is not loopback` |
| 云端模型 | 单元测试 `OllamaModelPolicyTests` | `gpt-oss:120b-cloud` 等被拒绝，不出现在选择列表 |

### 2.3 过程中发现并修复的三个真机问题

| ID | 问题 | 修法 |
|---|---|---|
| D-037 | 首次调用耗时 **12.6 s**（Ollama 冷加载 9B 模型权重），而超时设为 12 s，被误报为「模型没有回答」 | 发现用 3 s 快速失败，生成用 90 s |
| D-038 | qwen3.5 是 reasoning 模型，token 预算被隐藏的 `thinking` 吃光，`response` 为空 | `think:false` + `num_predict=1200`；并从信封中只取 `response` 再校验 |
| D-039 | 16 KiB 上限卡在 **Ollama 信封**上而不是答案上，reasoning 模型即使答案只有三个字段也会超标 | 上限移到提取后的对象 |

---

## 3. 实现要点（对应补丁要求）

| 要求 | 实现 |
|---|---|
| 1. 打开即真正调用，自动检测，不硬编码模型 | `OllamaService.discover()` 读 `/api/tags`；`OllamaModelPolicy` 过滤云端模型；用户可在设置里下拉切换 |
| 2. 详情页有真实「用本地 AI 分析」按钮 | `AIAnalysisModel` + `AIExplanationPanel`，已接入推荐详情与周报 |
| 3. 不要求手填 endpoint；未安装/未运行时明确提示 | 端点固定 `127.0.0.1:11434`；设置页显示状态；安装但未运行时提供「允许启动已安装的 Ollama」开关 |
| 4. 只用环回 + 已安装模型 + `stream:false` + 严格 JSON | 每次请求前 `OptionalAI.isLoopback`；模型必须来自 `/api/tags` 且非云端；`OptionalAI.parse` 三重校验 |
| 5. 全异步、可取消、不阻塞主线程 | `actor OllamaService` + async/await；视图消失时 `cancel()` |
| 6. 关闭 AI 后不再发请求 | `canAnalyze` 要求 `isAIEnabled`；关闭时 `stop()` 取消所有任务；从不关闭用户自己启动的 Ollama |
| 7. 云模型风险 | `OllamaModelPolicy` 拒绝名称含 `cloud` 的模型；设置页明示「仅检查环回不足以保证离线」 |

### 7 的诚实边界

**能验证的**：模型名是否带云端标记（Ollama 的约定是 `-cloud` 后缀）。
**不能验证的**：Ollama 服务端是否配置了 `OLLAMA_NO_CLOUD=1`——客户端没有读取该配置的 API。
**因此**：本应用只发送聚合字段（T0），不发送任何正文；这一限制已写进设置页文案。
**未实现**：代用户设置 `OLLAMA_NO_CLOUD=1` 需要接管服务端启动，超出本次补丁范围。

---

## 4. 仍未验证的部分（交给 Muse）

以下必须由人在 Mac 前操作，开发侧无法完成：

| 项 | 原因 |
|---|---|
| 设置页模型下拉是否显示真实模型、切换是否生效 | 需要 GUI 操作与截图 |
| 点「用本地 AI 分析」后卡片是否显示解释与「本地模型 qwen3.5:9b」标记 | 需要 GUI 操作 |
| 关闭 AI 后是否确实不再发请求 | 需要在关闭状态下点按钮并观察 |
| 服务停止时界面是否卡死 | 需要停掉 Ollama 后操作 GUI |
| 「允许启动已安装的 Ollama」是否真的能拉起来 | 需要 GUI 授权 |
| 中英双语与明暗主题下的显示 | 需要 GUI 截图 |

验收步骤见 `docs/qa/muse-ollama-dispatch.md`。
