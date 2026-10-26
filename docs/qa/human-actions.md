# 需要人工操作的事项（集中处理）

整理日期：2026-10-27
所有开发工作由 Claude 完成；需要你本人在 Mac 前操作的集中在此。按优先级排列。

---

## P0 — 阻塞发布，必须做

### 1. 授权 ShortcutSense 的两项权限（一次性，签名已稳定）

应用装在 `/Applications/ShortcutSense.app`。现在 TCC 里两条记录都是 0（未授权）。
因为已经改用自签名证书，指定要求跨重建稳定，**这次授权不会再失效**。

操作：
1. 双击 `/Applications/ShortcutSense.app`
2. 系统设置 → 隐私与安全性 → **输入监控** → 打开 ShortcutSense
3. 系统设置 → 隐私与安全性 → **辅助功能** → 打开 ShortcutSense
4. 退出应用（菜单栏 ⌘ → Quit）再重新打开一次，让权限生效

完成后告诉我，我会验证并继续。

### 2. 批准公开发布（G6）

在 G5 真机验收通过前，我不会创建公开仓库。需要你批准的是：
- 创建 `AIMetaPhD/ShortcutSense` 公开仓库
- 推送代码、打 `v0.1.0` tag、上传 Release
- 在 `AIMetaPhD/AIMetaPhD` 的 `for builders` 加一行

**这个批准要等真机验收做完再给**，否则等于在未验证状态下发布。

---

## P1 — 强烈建议，能省掉反复打扰你

### 3. 安装完整 Xcode（可选）

你的 Mac 现在只有 Command Line Tools，没有 XCTest，所以我写了个 shim 跑同一批测试源码。
装了 Xcode 后可以直接 `swift test`，也能用 `xcodebuild` 做更完整的构建验证。
从 App Store 装，或者：
```
xcode-select --install   # 这个你已经有了
```
完整 Xcode 大约 10GB，装不装都不阻塞，只是验证手段少一条。

### 4. 清理 Mac 上的临时文件

我为了排查签名问题，在 Mac 上留了些东西，都是可删的：

```bash
rm -rf ~/ss-cert ~/Desktop/finish-cert.command ~/ShortcutSense/build
```

`~/ss-cert/` 里有自签名证书和私钥，密码是 `shortcutsense`。**如果你不希望这台 Mac 上长期留着一个代码签名身份**，可以删掉，但删掉后构建会退回 ad-hoc 签名，权限又会因重建失效。所以我建议留着，直到你决定用正式 Developer ID 或者干脆结束这个项目。

### 5. Tailscale 上的 Muse 节点

三位 Muse 都是无人值守的云端/Linux worker，没有 macOS 桌面，所以 GUI 验收它们做不了，
只能做静态审阅。如果你希望 GUI 验收也由 Muse 分担，需要给其中一位配上能访问这台 Mac 的方式（
或者接受 GUI 验收由你本人做）。目前它们已经做完能做的部分（Muse-3 审了 13 个核心文件）。

---

## P2 — 有空再说

### 6. 申请 Apple Developer ID（可选，需要年费）

有了它就能做真正的 Developer ID 签名 + notarization，用户安装时不需要走「仍要打开」。
现在的自签名证书能让权限稳定，但 Gatekeeper 那关仍然会拦，必须走 Apple 的 Open Anyway 流程。

---

## 我现在在做什么（你醒来后会看到）

按你的指示自主推进，不拿非关键问题打扰你。接下来我会：

1. 完成 git 历史脱敏（这个必须做，否则公开仓库会泄漏你的用户名、Mac IP、主机名）
2. 把 GUI 验收里**不需要 GUI** 的部分尽量验证掉（用 `--diagnose`、数据库检查、进程状态）
3. 完善 README 和安装文档，把「自签名 vs Developer ID」的区别写清楚
4. 等你在第 1 项授权后，跑完剩余的验收并汇总

如果遇到真正无法自己解决的技术问题，我会记录下来放在这份文档末尾，而不是中途打扰你。
