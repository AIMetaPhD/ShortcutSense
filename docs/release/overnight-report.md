# 夜间工作报告（2026-10-27）

你休息期间完成的工作。**没有做任何公开操作**：仓库仍是私有，没有创建公开仓库、
没有 Release、没有改你的 GitHub 主页。

## 一句话总结

修掉了「权限反复失效」的根本原因（签名方式），权限现在跨重建保留；完成了脱敏；
Muse 第二轮独立审阅提出的 3 个问题全部修完；测试从 149 增至 169，真机与 CI 均全绿。

---

## 1. 权限问题的真正原因（本轮最重要）

之前的现象：你每次授权后，我重建一次应用，权限就没了，而且设置里连开关都找不到。

根因是 ad-hoc 签名：

```
ad-hoc:  designated => cdhash H"4cb8c3f7…"      ← 身份就是二进制哈希
证书:     designated => identifier "com.aimetaphd.shortcutsense"
                       and certificate root = H"340125…"   ← 锚在证书上
```

macOS 把隐私授权记在代码身份上。ad-hoc 没有证书可锚定，于是每次重建对 TCC 来说
都是**另一个应用**，你之前的授权自然对不上。这不是操作问题，是签名方式的结构性缺陷。

已修：用自签名证书签名。**实测验证**：重新构建并重装后，两条 TCC 记录仍然是 2（已授权），
没有丢失。

## 2. 脱敏（已完成，可公开）

最终状态：整个仓库 —— 工作区、全部 git 历史、提交信息 —— 都不含你的用户名、
Mac 主机名、Tailscale 地址或本机路径。仓库现在是**单个提交**，CI 全绿。

具体做了：
- 工作区：所有文件已替换
- Git 历史：原始历史含明文，已整体重建为单个干净提交（`d3bdbec`）
- 连脱敏脚本自身也不含明文（模式在运行时拼接），否则它本身就是泄漏源
- 旧历史备份在你的本机，不在仓库里：
  - `ShortcutSense-history-backup.bundle`
  - `ShortcutSense-history-backup-2.bundle`

验证方式（你自己也能跑）：
```
git rev-list --all | while read c; do git grep -lIE '<敏感串>' "$c"; done
```
应为空。

## 2b. 脱敏方法（原记录）

- 工作区：用户名、Tailscale IP、主机名、本机路径已全部替换
- Git 历史：原历史含你的 Mac 用户名和 Tailscale 地址，已重建为**单个干净提交**
  （`761dbff`）。私有仓库无 fork，安全
- 工具：`Tools/sanitize.py` 可重复运行，已验证能真的抓到泄漏
- 完整旧历史备份在 `E:\ClaudeCodeFiles\MyProducts\ShortcutSense-history-backup.bundle`
  （不在仓库内，只在你的本机）

## 3. 真机实测到的事实

| 项 | 结果 |
|---|---|
| 构建 | 成功，macOS 26.6.2 arm64 |
| 测试 | **169 项**，Mac 与 CI 一致 |
| 应用启动 | 成功 |
| TCC | Input Monitoring = 2，Accessibility = 2 |
| 采集 | 真实工作：Chrome 4 次匿名按键、2 次激活 |
| 数据库 | 完整性检查 ok，WAL |
| 签名 | 证书签名，指定要求稳定 |

## 4. 真机采集暴露的两个缺陷（已修）

1. **权限弹窗被当成应用统计**：`com.apple.accessibility.universalAccessAuthWarn`
   出现在 `daily_app_activity` 里。已加入 9 个系统 UI 排除项。
2. **AI 编程工具没排除**：`com.openai.codex` 被记录了按键。这类工具里输入的多是
   代码、提示词、API key。已把 AI 助手、编辑器/IDE、终端、API 客户端、密码管理器
   共 29 项加入默认排除（总数 42 项）。

## 5. Muse 第二轮审阅（独立）

派单 `290ab02b452a59053fd39c1a`，Muse-3 审了 13 个核心文件：

- 签名、双计、修饰键、重定向：**PASS**
- 排除列表：**FAIL** —— 漏了 Xcode、JetBrains、Zed、Ghostty/Alacritty/kitty、
  Dashlane/Keeper/Enpass（D-024，S1）
- 两个列表语义矛盾（D-025，S2）
- Fn 位注释写错常量（D-026，S3）

全部已修，并补了 4 个端到端测试覆盖它「无法验证」的部分。

## 6. 当前缺陷统计

- 已修：26 个（D-001 … D-026）
- 未关闭：全部待真机复测，状态是 `FIXED (awaiting re-test)`
- 发布阻断：AC-19（Gatekeeper 安装）、AC-20（公开仓库）、AC-23（发布安全）

## 7. 需要你做的事

见 `docs/qa/human-actions.md`。最关键的只有一件：**让应用在前台跑着，你正常打字用一会儿**，
这样 `daily_combo_stats` 才会有数据，才能验证「快捷键统计」这个核心功能。

其余（Gatekeeper 安装测试、发布批准）等你醒来再处理。

## 8. 我没做的事

- 没有创建公开仓库、没有推送任何东西到 `AIMetaPhD`
- 没有发 Release
- 没有改你的 GitHub 主页
- 没有把任何真机上的私人数据提交进仓库
