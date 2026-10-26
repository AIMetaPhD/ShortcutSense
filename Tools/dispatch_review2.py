"""Dispatches the second independent review to Muse-3 over the local queue."""

import base64
import gzip
import json
import os
import subprocess
import sys

REPO = r'E:\ClaudeCodeFiles\MyProducts\ShortcutSense'
QUEUE = r'F:\Applications\Documents\Workspace\projects\muse-queue'
TMP = os.path.expandvars(r'%LOCALAPPDATA%\Temp')

INSTRUCTIONS = (
    "第二轮独立静态审阅。源码在 inputs.sources_b64：JSON 经 gzip 压缩再 base64 编码，"
    "解压后键是路径、值是全文。若解码不可行请直说，不要猜内容。\n\n"
    "背景：ShortcutSense 是 macOS 菜单栏工具。硬性约束：绝不保存用户输入文本/按键序列/"
    "窗口标题/URL/剪贴板；热键注册失败绝不能记成成功；删除数据后系统热键必须释放。"
    "第一轮你审过 A-H 并全部 PASS。本轮请重点复查下面 5 项新改动，以及它们是否破坏了第一轮已 PASS 的项。\n\n"
    "本轮改动：\n"
    "1. 签名：改用自签名证书（ad-hoc 时指定要求是 CDHash，每次重建都变，导致 TCC 授权失效）。"
    "请确认代码里没有假设任何签名状态。\n"
    "2. SensitiveApps 现在把系统 UI 和 AI 编程工具也默认排除（com.openai.codex、VSCode、Postman 等）。"
    "请检查这份列表：有没有漏掉的高风险应用？有没有错杀正常应用？"
    "判断标准是「用户在这里输入的内容是否可能含密钥」。\n"
    "3. 修了一个双计缺陷：热键 handler 和激活通知曾重复计数。请独立核对 handleTrigger 与"
    " handleAppActivation，确认 trigger_count 与 successful_target_activation_count 现在不可能双计。\n"
    "4. 修了修饰键转换：CGEventFlags 与 Carbon 位完全不同。请核对 "
    "ComboModifiers(appleEventFlagsRawValue:) 是否每一位都映射正确、有无遗漏。\n"
    "5. AI 层加了禁止重定向（之前本地服务可 302 把数据转发到外网）。请确认 "
    "OllamaTransport 的 redirect delegate 真的生效，且 parse 对 reason 字段也做了可执行文本检查。\n\n"
    "输出：每项 PASS/FAIL/无法判断 + 文件:函数 + 不超过 8 行原文 + 理由。"
    "发现新问题标 S1-S4。不要修改任何东西。"
)


# The queue body is capped at 64 KiB. Only the files this review actually asks
# about are sent; a review that cannot see a file must say so rather than guess.
KEY_FILES = [
    'Sources/ShortcutSenseCore/PrivacyGate.swift',
    'Sources/ShortcutSenseCore/CapturePipeline.swift',
    'Sources/ShortcutSenseCore/KeyCombo.swift',
    'Sources/ShortcutSenseCore/AXMenuCodec.swift',
    'Sources/ShortcutSenseCore/ConflictResolver.swift',
    'Sources/ShortcutSenseCore/RecommendationEngine.swift',
    'Sources/ShortcutSenseCore/OptionalAI.swift',
    'Sources/ShortcutSenseCore/ShortcutActionManager.swift',
    'Sources/ShortcutSenseCore/Attribution.swift',
    'Sources/ShortcutSenseMac/CarbonHotkeyBackend.swift',
    'Sources/ShortcutSenseMac/OllamaTransport.swift',
    'Sources/ShortcutSenseMac/EventTapSource.swift',
    'Package.swift',
]


def collect_sources():
    files = {}
    for rel in KEY_FILES:
        path = os.path.join(REPO, rel.replace('/', os.sep))
        try:
            with open(path, encoding='utf-8') as handle:
                files[rel] = handle.read()
        except OSError:
            continue
    return files


def main():
    files = collect_sources()
    raw = json.dumps(files, ensure_ascii=False).encode('utf-8')
    packed = base64.b64encode(gzip.compress(raw, 9)).decode()
    print('files:', len(files), 'packed:', len(packed))

    task = {
        'recipient': 'muse-3',
        'kind': 'shortcutsense_review_v2',
        'permissions': 'read_only',
        'instructions': INSTRUCTIONS,
        'inputs': {
            'encoding': 'json->gzip->base64',
            'sources_b64': packed,
            'file_count': len(files),
        },
    }
    path = os.path.join(TMP, 'muse-review2.json')
    with open(path, 'w', encoding='utf-8') as handle:
        json.dump(task, handle, ensure_ascii=False)
    print('payload bytes:', os.path.getsize(path))

    with open(path, encoding='utf-8') as handle:
        result = subprocess.run(
            [sys.executable, 'queue_client.py', '--role', 'producer',
             '--producer', 'claude', '--method', 'POST', '--path', '/tasks'],
            stdin=handle, capture_output=True, text=True, cwd=QUEUE)
    out = result.stdout.strip()
    print('OUT:', out[:160])
    if out.startswith('{'):
        try:
            print('TASK:', json.loads(out).get('id'))
        except ValueError:
            pass
    print('ERR:', result.stderr[:200])
    return 0


if __name__ == '__main__':
    sys.exit(main())
