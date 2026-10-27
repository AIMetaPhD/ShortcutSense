# ShortcutSense

[English](#english) · [简体中文](#简体中文)

---

## English

A privacy-first macOS menu-bar app that notices repeated app switching, suggests a
global hotkey, checks for known conflicts, and tracks whether the shortcut actually
gets used.

**Status: pre-release.** The core logic is implemented and tested (130 tests, green
on Linux and on arm64 macOS 14/15 runners). macOS runtime behaviour — permissions,
Accessibility menus, physical hotkey delivery, Gatekeeper install — has **not** been
verified on a real desktop yet, and is not claimed. See
[`docs/release/acceptance-status.md`](docs/release/acceptance-status.md).

### What it does

- Counts, per application and per day, how many times an app came to the front and
  how you got there — *as far as it can honestly tell*.
- Suggests a `Control+Option+Shift+<letter>` shortcut once an app has been activated
  at least 7 times on at least 2 different days.
- Checks the combination against system hotkeys, enabled symbolic hotkeys, readable
  application menus and its own registrations before offering *Apply*.
- Registers the shortcut with Carbon, verifies the `OSStatus`, and counts real
  presses inside its own handler.
- One click to undo. Restores registrations on relaunch and shows any failure.

### What it does not do

- It does not record what you type. No text, no key sequence, no window titles, no
  URLs, no clipboard, no passwords.
- It does not modify other applications' shortcuts. macOS does not allow that, and
  the app says so instead of pretending.
- It does not claim to know you clicked the Dock. Activations without a keyboard
  predecessor are labelled `unknown_origin`.
- It does not promise a combination is free. The best state is *no known conflict*
  among the sources it can read.
- It does not sync, phone home, or require an account.

### Privacy model

| Data | Stored? |
|---|---|
| Daily count of anonymous keystrokes per app | yes |
| Daily count of `Command`/`Control` combinations per app | yes |
| App activations by origin class (`unknown_origin`, `observed_keyboard_navigation`, `managed_hotkey`) | yes |
| Your registered hotkeys and how often they fired | yes |
| Typed text, key sequences, timestamps per keystroke | **never** |
| Window titles, URLs, clipboard, document content | **never** |
| Passwords, Secure Input content | **never** |

Collection stops entirely when: you pause it, the screen is locked, Secure Input is
active, the frontmost app is excluded, or the permission is not granted. The gate
fails closed — if the state is unknown, nothing is recorded.

Default exclusions include Keychain Access, 1Password, Bitwarden, LastPass, the
login window, System Settings, and terminal-class apps (Terminal, iTerm2, Warp,
VS Code). Terminal-class apps can be re-included knowingly in Settings.

### Optional local AI

Off by default. When you turn it on, only a fixed aggregate JSON is sent to a
**loopback** address (`http://127.0.0.1` or `http://[::1]`) running Ollama. The model
may return only `{reason, explanation, category}`; anything else — extra fields,
oversized output, executable-looking text, a timeout — falls back to a deterministic
template. The model can never change a setting. With AI off, no product network
request is made at all.

**What this does not prove.** The app can verify three things: it only dials literal
loopback (`127.0.0.1`, `::1`), it refuses HTTP redirects, and the model name carries
no Ollama Cloud marker. It cannot verify that the Ollama server you are running is
not itself proxying to a remote model — the client has no way to read that server's
configuration. If your threat model requires proof of on-machine execution, run
Ollama with `OLLAMA_NO_CLOUD=1` yourself; this app will not set it for you. Only
aggregate fields are ever sent, never text you typed.

### Build

Requirements: macOS 14+, Xcode 16 (Swift 6), Apple Silicon or Intel.

```bash
swift build
swift test
./Scripts/build-app.sh          # produces build/ShortcutSense.app, signed with your local identity
open build/ShortcutSense.app
```

`build-app.sh` uses a Developer ID if `DEVELOPER_ID` is set in the environment, and
otherwise ad-hoc signs. It never produces a completely unsigned bundle.

### Install

This build is **signed with a self-signed certificate and is not notarized**, so
macOS will block the first launch. Use Apple's own flow:

1. Try to open the app.
2. System Settings → Privacy & Security → **Open Anyway**.
3. Confirm, then launch again.

Do not disable Gatekeeper or SIP, and do not bulk-remove quarantine attributes.

### Why the signature matters for permissions

macOS records privacy grants (Input Monitoring, Accessibility) against a code
identity. With an **ad-hoc** signature that identity is the binary's hash, so every
rebuild looks like a different app and silently loses the grants you gave it. That
is why this project signs with a certificate:

```
ad-hoc:  designated => cdhash H"4cb8c3f7…"
cert:    designated => identifier "com.aimetaphd.shortcutsense" and certificate root = H"340125…"
```

Releases are signed with one fixed certificate so a grant survives upgrades. If you
build from source yourself, create a local identity once
(`Scripts/make-cert.sh`) so your own grants stay valid across rebuilds.

### Permissions

- **Input Monitoring** — required for keystroke aggregation.
- **Accessibility** — required only for reading menus and checking conflicts.
  Shortcuts work without it.

The two are shown separately and can be revoked at any time. If you revoke a
permission, collection stops and your history stays readable.

### Removing your data

Settings → *Delete all local data* removes every row, checkpoints the SQLite WAL and
vacuums the database. Files you exported yourself are not touched. The database lives
at `~/Library/Application Support/ShortcutSense/`.

### Licence

MIT. No third-party code is vendored; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

---

## 简体中文

隐私优先的 macOS 菜单栏应用：发现你反复切换的应用，建议一个全局热键，检查已知
冲突，并追踪这个热键是否真的被用起来。

**状态：预发布。** 核心逻辑已实现并有 130 项测试（在 Linux 与 arm64 的 macOS 14/15
上通过）。但 macOS 的运行时行为——权限、辅助功能菜单、真实按键投递、Gatekeeper
安装——**尚未**在真实桌面上验证，也没有声称已验证。详见
[`docs/release/acceptance-status.md`](docs/release/acceptance-status.md)。

### 它做什么

- 按应用、按天统计应用被切换到前台的次数，以及**在能诚实判断的范围内**你是如何切过去的。
- 当某应用在至少 2 个不同日期累计激活 ≥ 7 次时，建议 `Control+Option+Shift+<字母>`。
- 在提供「应用」之前，检查系统热键、已启用的符号热键、可读取的应用菜单和本应用
  已注册的组合。
- 通过 Carbon 注册，校验 `OSStatus`，并在自己的 handler 内统计真实按键次数。
- 一键撤销；重启后恢复注册并显示失败明细。

### 它不做什么

- 不记录你输入的内容。没有文本、没有按键序列、没有窗口标题、没有网址、没有剪贴板、没有密码。
- 不修改其他应用的快捷键。macOS 不允许，应用会直接说明，而不是假装做到了。
- 不声称知道你是点了 Dock。没有键盘前驱的激活标记为 `unknown_origin`。
- 不承诺某个组合一定空闲。最好的状态是「在可读取的来源中未发现已知冲突」。
- 不联网同步、不要求账号。

### 隐私模型

| 数据 | 是否保存 |
|---|---|
| 每应用每日匿名按键总数 | 是 |
| 每应用每日 `Command`/`Control` 组合键次数 | 是 |
| 按来源分类的应用激活次数 | 是 |
| 你注册的热键及其触发次数 | 是 |
| 输入的文字、按键序列、逐键时间戳 | **从不** |
| 窗口标题、网址、剪贴板、文档内容 | **从不** |
| 密码、安全输入内容 | **从不** |

以下情况完全停止采集：你暂停、锁屏、安全输入开启、前台应用被排除、权限未授予。
闸门采用「失败即关闭」：状态不明时一律不记录。

默认排除 Keychain Access、1Password、Bitwarden、LastPass、登录窗口、系统设置，
以及终端类应用（Terminal、iTerm2、Warp、VS Code）。终端类可在设置中知情后重新纳入。

### 可选本地 AI

默认关闭。开启后只向**环回地址**（`http://127.0.0.1` 或 `http://[::1]`）的 Ollama
发送固定的聚合 JSON。模型只能返回 `{reason, explanation, category}`；多余字段、
超长输出、看起来可执行的文本、超时，一律回退到确定性模板。模型无法修改任何设置。
AI 关闭时，产品不发出任何网络请求。

**这不能证明什么。** 应用能验证三件事：只连字面量环回地址（`127.0.0.1`、`::1`）、
拒绝 HTTP 重定向、模型名不带 Ollama 云端标记。它**无法**验证你运行的 Ollama 服务端
是否在代理到远端模型——客户端读不到服务端的配置。如果你的威胁模型要求「证明在本机
执行」，请自行以 `OLLAMA_NO_CLOUD=1` 启动 Ollama；本应用不会替你设置。发送的始终只有
聚合字段，不包含你输入的文字。

### 构建

要求：macOS 14+、Xcode 16（Swift 6）。

```bash
swift build
swift test
./Scripts/build-app.sh
open build/ShortcutSense.app
```

### 安装

本构建使用**自签名证书签名、未经公证**，首次启动会被系统阻止。请使用 Apple 官方流程：

1. 尝试打开应用。
2. 系统设置 → 隐私与安全性 → **仍要打开**。
3. 确认后再次启动。

不要关闭 Gatekeeper 或 SIP，也不要批量清除 quarantine 属性。

### 为什么签名方式会影响权限

macOS 把隐私授权（输入监控、辅助功能）记在代码身份上。**ad-hoc** 签名没有证书可锚定，
身份就是二进制的哈希，所以每次重新构建看起来都像另一个应用，你给的授权会静默失效。
因此本项目使用证书签名：

```
ad-hoc:  designated => cdhash H"4cb8c3f7…"
证书:     designated => identifier "com.aimetaphd.shortcutsense" and certificate root = H"340125…"
```

正式发布用一个固定证书签名，授权可以跨升级保留。如果你自己从源码构建，请先创建一次本地
签名身份（`Scripts/make-cert.sh`），否则每次重建都要重新授权。

### 权限

- **输入监控** — 统计按键所必需。
- **辅助功能** — 仅用于读取菜单和检查冲突；不授权也能使用热键功能。

两者分别显示，可随时撤销。撤销后采集停止，历史仍可查看。

### 删除数据

设置 →「删除全部本地数据」会清空所有行、检查点 SQLite WAL 并整理数据库。你自行
导出的文件不会被删除。数据库位于 `~/Library/Application Support/ShortcutSense/`。

### 许可

MIT。未内嵌任何第三方代码，详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
