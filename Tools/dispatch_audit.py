import json, subprocess, sys, os, gzip, base64

TMP = os.path.expandvars(r"%LOCALAPPDATA%\Temp")
src = json.load(open(os.path.join(TMP, "audit-subset.json"), encoding="utf-8"))
clean = {k.replace("\\", "/").lstrip("./"): v for k, v in src.items()}
raw = json.dumps(clean, ensure_ascii=False).encode("utf-8")
packed = base64.b64encode(gzip.compress(raw, 9)).decode()
print("files:", len(clean), "raw chars:", len(raw), "packed:", len(packed))

instructions = (
    "这是纯静态源码审阅，不需要执行任何命令、不需要网络、不需要文件系统访问。\n\n"
    "源码在 inputs.sources_b64 里：它是 gzip 压缩后再 base64 编码的 JSON 文本，"
    "解压后是一个对象，键是文件路径、值是文件全文。请用你环境里现成的方式解码"
    "（Python 一行即可：json.loads(gzip.decompress(base64.b64decode(s)))）。"
    "如果解码不可行，请直接说不可行，不要猜内容。\n\n"
    "背景：ShortcutSense 是一个 macOS 菜单栏工具，按天聚合按键、推荐全局热键、检查冲突。"
    "硬性约束：绝不保存用户输入的文本/按键序列/窗口标题/URL/剪贴板；"
    "热键注册失败绝不能记成成功；删除数据后系统热键必须释放。\n\n"
    "请按 A-H 逐条给结论（PASS / FAIL / 无法判断 + 定位到 文件:函数 并引用不超过 8 行原文）：\n\n"
    "A. 隐私：普通字符键的 keyCode 是否只进入匿名计数而不写 daily_combo_stats？"
    "Option 单独组合是否被当作文字输入？Secure Input/锁屏/暂停/排除 App 时是否 fail-closed"
    "（未知状态一律不记录）？重点看 PrivacyGate.decide 与 CapturePipeline.handle。\n\n"
    "B. 热键注册：RegisterEventHotKey 的 OSStatus 是否检查并回传？失败时是否回滚、"
    "是否避免写 is_active=1？注销失败时是否保留记录（否则系统捕获成孤儿，无法再撤销）？"
    "apply 的入库与状态更新是否在同一事务？\n\n"
    "C. 修饰键语义：CGEventFlags/NSEvent 与 Carbon 是两套完全不同 bit 布局"
    "（CG command=0x100000，Carbon command=0x100）。边界处是否真正转换，还是直接 reinterpret？"
    "AX 的 AXMenuItemCmdModifiers 里 Command 是隐式存在（除非设 NoCommand），解码是否符合？"
    "这是曾导致所有快捷键统计静默失效的缺陷类型。\n\n"
    "D. 冲突四态：occupied/potential_conflict/no_known_conflict/unknown。"
    "当 symbolichotkeys 或应用菜单读取失败（nil）时，是否降级为 unknown 而不是误判"
    " no_known_conflict？Cmd+Q/W/H/M 是否标为「应用作用域高风险」而非谎称「系统全局占用」？\n\n"
    "E. 推荐阈值：7/14 次、activeDays>=2、已有键盘导航占优时降权、dismiss 冷却 28 天，"
    "是否与约定一致？unknown_origin 是否从不被描述成「鼠标点了 Dock」？\n\n"
    "F. AI 边界：只在用户显式开启时工作、只允许环回（127.0.0.1/::1/localhost）、"
    "拒绝非 loopback、输出 schema 白名单（只允许 reason/explanation/category）、"
    "多余字段/超长/疑似可执行文本是否回退到确定性模板？\n\n"
    "G. 供应链：Package.swift 是否零第三方依赖？有无 Sparkle/sync/遥测代码？"
    "THIRD_PARTY_NOTICES.md 是否如实说明未复制上游源码？\n\n"
    "H. 删除数据：deleteAllData 是否清空所有表、是否在 VACUUM 之后再 checkpoint WAL"
    "（VACUUM 会经 WAL 写入，顺序错会残留）、删除前是否释放系统热键？\n\n"
    "只报告你能从原文确认的。发现问题标 S1-S4（S1=数据泄漏/假成功/无法撤销）。"
    "不要因为看不到 GUI 就把静态项标 BLOCKED；静态项与 GUI 项是分开的。不要修改任何东西。"
)

task = {
    "recipient": "muse-3",
    "kind": "shortcutsense_source_review",
    "permissions": "read_only",
    "instructions": instructions,
    "inputs": {
        "encoding": "json -> gzip -> base64",
        "sources_b64": packed,
        "file_count": len(clean),
        "reference": "07_DATA_CONTRACT.md D 节定义推荐阈值，A 节定义数据分类。",
    },
}

path = os.path.join(TMP, "muse-audit3.json")
json.dump(task, open(path, "w", encoding="utf-8"), ensure_ascii=False)
print("payload bytes:", os.path.getsize(path))

with open(path, encoding="utf-8") as f:
    r = subprocess.run(
        [sys.executable, "queue_client.py", "--role", "producer", "--producer", "claude",
         "--method", "POST", "--path", "/tasks"],
        stdin=f, capture_output=True, text=True)
out = r.stdout.strip()
print("OUT:", out[:200])
if out.startswith("{"):
    try:
        print("TASK:", json.loads(out).get("id"))
    except Exception:
        pass
print("ERR:", r.stderr[:200])
