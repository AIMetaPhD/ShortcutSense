# Muse — Ollama 修复的独立验证（D-035 / D-036）

**日期**：2026-10-27
**构建**：`/Applications/ShortcutSense.app`，自签名证书，209 项测试通过
**开发侧证据**：`docs/qa/ollama-acceptance.md`

## 你能做的（不需要 macOS 桌面）

### 1. 静态审阅以下不变量

源码包随任务下发（`inputs.sources_b64`，JSON→gzip→base64）。重点核对：

| # | 不变量 | 检查点 |
|---|---|---|
| 1 | 打开 AI 后确实会发请求，而不是只有开关 | `AIAnalysisModel.analyze` 是否被 UI 按钮调用；`OllamaService.explain` 是否真的 POST `/api/generate` |
| 2 | 模型名不硬编码 | 全仓库搜索 `qwen`、`llama`、`mistral` 等字面量；应只在测试里出现 |
| 3 | 只用环回 | 每次请求前是否有 `OptionalAI.isLoopback` |
| 4 | 只发聚合字段 | `AIExplanationRequest` 的字段是否仍为白名单；有没有新增自由文本字段 |
| 5 | 云端模型被拒 | `OllamaModelPolicy` 的标记列表；是否可能漏掉某种云端命名 |
| 6 | 请求可取消、不阻塞主线程 | 是否有 `Task` 句柄、`cancel()`、视图消失时是否取消 |
| 7 | 关闭 AI 后不再请求 | `canAnalyze` 的前置条件；关闭时是否调用 `stop()` |
| 8 | 不代用户启动/关闭服务 | `startInstalledAppAndWait` 是否只在显式允许后调用；有没有 kill 逻辑 |
| 9 | 失败状态语义正确 | 未安装 / 已安装未运行 / 仅云端 / 非环回 是否各自可区分 |
| 10 | 不记录敏感内容 | 是否有日志输出 prompt、模型正文、token |

### 2. 指出你无法验证的部分

你已经确认过自己没有 macOS 桌面。所以以下**必须标 BLOCKED，不要标 PASS**：

- 设置页模型下拉是否显示真实模型
- 点「用本地 AI 分析」后界面是否显示解释
- 服务停止时界面是否卡死
- 「允许启动已安装的 Ollama」是否真的能拉起
- 中英双语与明暗主题

## 开发侧已完成的真机证据（供你核对，不作为你的结论）

```
discovery_status=connected
models=qwen3.5:9b,qwen3:14b
local_models=qwen3.5:9b,qwen3:14b
cloud_models=
selected_model=qwen3.5:9b
generation_latency_ms=9387
used_fallback=false
```

失败路径：端口关闭 → `installed_not_running`（8 ms）；非环回 → `failed:The endpoint is not loopback`。

## 回传格式

每项：`#n | PASS / FAIL / BLOCKED | 文件:函数 | 不超过 8 行原文 | 理由`。
发现新问题标 S1–S4，S1 定义为「声称的功能实际不可达」或「数据发到了非本机」。

## 一个已知的诚实边界

`OllamaModelPolicy` 只能检查模型名是否带云端标记（Ollama 的 `-cloud` 约定）。
客户端没有 API 可以读取服务端的 `OLLAMA_NO_CLOUD` 配置，所以「模型完全在本机执行」
这件事**无法由客户端证明**。请判断这个限制在当前产品定位下是否可以接受，
以及文案是否如实披露。
