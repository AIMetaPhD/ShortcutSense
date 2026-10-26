# 在你 Mac 上要做的事（逐条）

应用已经在你 Mac 上**真实运行**了：进程存活，数据库与 WAL 正确创建，9 张表齐全，
13 项敏感应用默认排除，Carbon 注册探针返回 `noErr`。

但采集还没开始，因为两项系统权限都没授予。下面是需要你在 Mac 上亲手完成的部分。
每一步都写清楚"怎么判断成功"，以及结果应该贴回什么。

---

## 第 0 步：现状（已替你确认）

```
macOS            26.6.2 (25G83), arm64
input_monitoring denied
accessibility    denied
tap_creation     failed
carbon           install=0, register=0 (noErr), unregister=0
symbolic_hotkeys readable
database         9 tables, 13 excluded apps, WAL
```

应用当前正在运行（`open ~/ShortcutSense/build/ShortcutSense.app`）。

---

## 第 1 步：授予输入监控

1. 打开 **系统设置 → 隐私与安全性 → 输入监控**。
2. 找到 **ShortcutSense**，打开开关。
3. 如果列表里没有它：先把应用退出再重新打开一次，让它再请求一次。
4. **必须退出并重新打开应用**——macOS 只在进程启动时读取这个权限。

**判断成功：**

```bash
cd ~/ShortcutSense && ./build/ShortcutSense.app/Contents/MacOS/ShortcutSense --diagnose | grep -E "input_monitoring|tap_creation"
```

要看到 `"input_monitoring" : "granted"` 和 `"tap_creation" : "created"`。
只看到 granted、但 tap_creation 仍是 failed，说明权限没真正生效，需要重启应用。

---

## 第 2 步：授予辅助功能（可选，但菜单冲突检查需要）

**系统设置 → 隐私与安全性 → 辅助功能** → 打开 ShortcutSense。

**判断成功：** `--diagnose` 里 `"accessibility" : "granted"`，且 `"menu_readable" : true`。

不做这一步也能用：热键功能正常，只是冲突检查会诚实地显示 `unknown` 而不是
`no_known_conflict`。

---

## 第 3 步：验证采集（真实按键）

授权后：

1. 打开 **TextEdit**，随便打一段字，按几次 **⌘C**、**⌘V**。
2. 打开 **终端**，敲几条命令（终端默认被排除，不应该有任何记录）。
3. 等 10 秒，然后检查数据库：

```bash
DB=~/Library/Application\ Support/ShortcutSense/ShortcutSense.sqlite
sqlite3 "$DB" "select bundle_id, total_anonymous_keystrokes, unknown_origin_activations from daily_app_activity;"
sqlite3 "$DB" "select bundle_id, combo_id, count from daily_combo_stats;"
sqlite3 "$DB" "select count(*) from daily_combo_stats where bundle_id like '%Terminal%';"
```

**期望：**

- TextEdit 出现在 `daily_app_activity`，匿名按键数 > 0
- `daily_combo_stats` 里有 `kc8-m256`（⌘C）和 `kc9-m256`（⌘V）
- **终端那一行必须是 0**

**最关键的一条**：确认没有存任何文字。先通过界面打一个独特的字符串（比如
`ZebraQuokka7731`），然后：

```bash
for f in "$DB" "$DB-wal" "$DB-shm"; do grep -a -c "ZebraQuokka" "$f" 2>/dev/null; done
```

三个都必须输出 `0` 或什么都不输出。

---

## 第 4 步：验证真实按键驱动热键（核心闭环）

这一步只能用真键盘，我无法代做。

1. 用鼠标点 Dock 在几个 App 之间切换 **至少 7 次**（找 Finder、Safari、Chrome 之类）。
2. 同时用 **⌘Tab** 切换几次（这会让系统判定你已有键盘路径，从而**降低**推荐优先级——
   这是设计正确的行为）。
3. 打开 ShortcutSense 窗口 → **Opportunities**。

**期望看到：** 一张推荐卡，写着类似
「7 天内激活 12 次，分布在 3 天。来源未知（不一定是 Dock 或鼠标）」，
建议组合键 `Control+Option+Shift+<字母>`，冲突状态 `no_known_conflict`。

4. 点 **Apply**。
5. 切到别的 App，按那个组合键。
6. **期望：** 目标 App 被切到前台。

然后检查计数：

```bash
DB=~/Library/Application\ Support/ShortcutSense/ShortcutSense.sqlite
sqlite3 "$DB" "select shortcut_id, date_bucket, trigger_count, successful_target_activation_count from applied_shortcut_usage_daily;"
sqlite3 "$DB" "select display_combo, target_bundle_id, is_active, last_error_code from registered_shortcuts;"
```

**期望：** 按 5 次就应当是 `trigger_count = 5`，`successful_target_activation_count`
≤ 5（不是 10）。两者不相等是正常的——目标是本来就前台的 App 时不会产生激活通知。

7. 退出应用（菜单栏 ⌘ → Quit），重新打开。**期望：** 热键仍然有效，数据库里
   `registered_shortcuts` 仍然只有 1 行，没有重复。
8. 点 **Undo**。**期望：** 再按那个组合键不再切换 App。

---

## 第 5 步：敏感场景负面测试

1. 在浏览器打开任何有密码框的页面，点进输入框，打 `ZebraQuokka7731`。
2. 重复第 3 步的 grep 检查。**必须仍然是 0。**
3. 锁屏 30 秒再解锁。**期望：** 锁屏期间的按键不产生记录。
4. 合盖休眠，唤醒。**期望：** 采集恢复，无崩溃。

---

## 第 6 步：暂停与删除

1. 菜单栏图标 → **Pause Collection**，打字 20 秒，确认 Today 数字不变。
2. **Resume**，确认恢复。
3. 设置 → **Delete all local data** → 确认。
4. **期望：** 所有标签页清空，且：

```bash
DB=~/Library/Application\ Support/ShortcutSense/ShortcutSense.sqlite
sqlite3 "$DB" "select (select count(*) from daily_combo_stats),(select count(*) from daily_app_activity),(select count(*) from registered_shortcuts);"
ls -la ~/Library/Application\ Support/ShortcutSense/
```

计数必须全为 0。**以及**：删完数据后，之前 Apply 过的热键必须已经失效——这一步
修过一个真实缺陷（删除数据但没释放系统热键捕获）。

---

## 第 7 步：Gatekeeper 安装（AC-19 / AC-23）

1. 把 `ShortcutSense.app` 拷到 `/Applications`。
2. 双击打开。**期望：** macOS 拒绝，提示无法验证开发者。
3. **系统设置 → 隐私与安全性**，滚到底部，点 **仍要打开** / **Open Anyway**。
4. 确认，再启动一次。

**判断成功：** 应用真的启动了，菜单栏出现图标。

```bash
codesign --verify --deep --strict --verbose=2 /Applications/ShortcutSense.app
spctl -a -vv /Applications/ShortcutSense.app
```

把这两条的输出贴回来。`spctl` 预期是 rejected（未公证），这是正常的，重要的是
"仍要打开"这条官方路径真的能启动。

**不要**关闭 Gatekeeper 或 SIP，也不要执行 `xattr -dr`。

---

## 需要贴回给我的

最少这几项，我就能把这些 AC 从 BLOCKED 改成 PASS：

1. 第 1、2 步之后的 `--diagnose` 完整输出
2. 第 3 步三条 sqlite 查询结果 + 那条 grep 结果
3. 第 4 步的 `applied_shortcut_usage_daily` 与 `registered_shortcuts` 查询结果
4. 第 5、6 步是否如预期
5. 第 7 步的 `codesign` / `spctl` 输出

哪一步做不到就写"做不到"和原因，我会记成 BLOCKED，不会记成通过。
