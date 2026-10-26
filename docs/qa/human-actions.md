# 需要你人工操作的事项

更新：2026-10-27（夜间工作结束后）
开发已完成的部分不需要你再介入；以下是**只有你能做**的。

---

## 只有一件是真正卡住进度的

### 1. 让应用在前台跑着，正常打字用一会儿

**为什么**：`daily_combo_stats`（快捷键统计表）到现在还是 0 行。这不是缺陷——
是因为应用跑起来之后，还没有人真正在它监控下用过键盘。表里已有的数据是
`daily_app_activity`（应用激活和匿名按键数），来自我之前几次会话。

**怎么做**：
1. 确认应用在跑（菜单栏应该有个 ⌘ 图标）。没在跑就双击 `/Applications/ShortcutSense.app`
2. 正常用电脑 10–20 分钟：写点东西、按几次 ⌘C / ⌘V / ⌘Tab、切几个应用
3. 告诉我，我会查库验证

**判断标准**：`daily_combo_stats` 出现 `kc8-m256`（⌘C）这类行，且 `count` 与实际按键次数相符。

权限已经授好了（Input Monitoring = 2、Accessibility = 2），并且**重建不会再生效**，
所以你不需要再动系统设置。

---

## 等你决定的事

### 2. 公开发布批准（G6）

我不会在没有你明确批准的情况下创建公开仓库。批准前你应该看到：
- 全部 23 项验收的真实状态（`docs/release/acceptance-status.md`）
- 已知限制清单
- `AIMetaPhD/AIMetaPhD` 主页要加的那一行 diff

现在**还不该批准**，因为 AC-19（Gatekeeper 安装）、AC-23（发布安全）还没做完。

### 3. Gatekeeper 安装测试（AC-19 / AC-23）

需要一个干净环境验证「仍要打开」流程真的能启动。做法：
1. 把 `/Applications/ShortcutSense.app` 复制到别处（比如桌面新建文件夹）
2. 双击它 —— 系统会拦
3. 系统设置 → 隐私与安全性 → **仍要打开** → 确认
4. 看它是否真的启动

**不要**关 Gatekeeper、不要关 SIP、不要执行 `xattr -dr`。

---

## 可选，不影响进度

### 4. 安装完整 Xcode

你现在只有 Command Line Tools。我写了 shim 让同一批测试源码能在没有 XCTest 的情况下跑
（已验证 169 项全过，与 CI 一致）。装完整 Xcode 后可以直接 `swift test`，多一条验证路径。
不装也不阻塞。

### 5. 清理 Mac 上的临时文件

```bash
rm -rf ~/ShortcutSense ~/ss-cert ~/Desktop/finish-cert.command
```

注意：删 `~/ss-cert` 会删掉自签名证书。删了之后 `build-app.sh` 会退回 ad-hoc 签名，
**权限又会因重建失效**。建议留着，除非你打算改用 Developer ID。

### 6. Apple Developer ID（可选，年费）

有了它才能做公证，用户安装时不必走「仍要打开」。现在的自签名证书解决了权限稳定性，
但 Gatekeeper 那关仍然会拦。

---

## 我判断需要你知道的风险

1. **自签名证书的私钥存在 `~/ss-cert/ss.keychain`，密码是 `shortcutsense`**。
   这是本地开发便利措施，不是发布级安全。正式发布应改用 Developer ID。
2. **公开仓库前必须再跑一次脱敏检查**。虽然现在是干净的，但后续任何提交都可能带进
   新路径或用户名。命令在 `Tools/sanitize-history.md`。
3. **Muse 只能做静态审阅**。三位都是无人值守 Linux worker，没有 macOS 桌面。
   所有 GUI 验收只能你本人或另一个有 Mac 桌面的人做。
