"""Dispatches the Ollama fix review to Muse over the local queue."""

import base64
import gzip
import json
import os
import subprocess
import sys

REPO = r'E:\ClaudeCodeFiles\MyProducts\ShortcutSense'
QUEUE = r'F:\Applications\Documents\Workspace\projects\muse-queue'
TMP = os.path.expandvars(r'%LOCALAPPDATA%\Temp')

FILES = [
    'Sources/ShortcutSenseMac/OllamaService.swift',
    'Sources/ShortcutSenseMac/AIAnalysisModel.swift',
    'Sources/ShortcutSenseMac/SettingsDashboard.swift',
    'Sources/ShortcutSenseMac/OpportunitiesDashboard.swift',
    'Sources/ShortcutSenseMac/WeeklyDashboard.swift',
    'Sources/ShortcutSenseMac/AppController.swift',
    'Sources/ShortcutSenseMac/Diagnose.swift',
    'Sources/ShortcutSenseCore/OllamaModel.swift',
    'Sources/ShortcutSenseCore/OptionalAI.swift',
    'docs/qa/ollama-acceptance.md',
    'docs/qa/muse-ollama-dispatch.md',
]

INSTRUCTIONS = (
    "第四轮：独立验证 Ollama 修复（D-035 / D-036）。源码在 inputs.sources_b64"
    "（JSON→gzip→base64，键是路径）。\n\n"
    "背景：这个应用声称「可选本地 AI」。修复前有两个缺陷：AI 开关打开了但界面从不"
    "调用解释功能；模型名硬编码为 qwen2.5:7b 而机器上装的是 qwen3.5:9b。\n\n"
    "请按 docs/qa/muse-ollama-dispatch.md 里的 10 条不变量逐条核对，重点是：\n"
    "1. 打开 AI 后是否真的会发出 /api/generate 请求（而不是只有开关动效）\n"
    "2. 是否还有任何地方硬编码模型名（搜 qwen/llama/mistral，应该只在测试里出现）\n"
    "3. 每次请求前是否检查环回\n"
    "4. 发给模型的字段是否仍是白名单（不得新增自由文本字段）\n"
    "5. 名称带 cloud 标记的模型是否被拒\n"
    "6. 请求是否可取消、视图消失是否取消\n"
    "7. 关闭 AI 后是否还会发请求\n"
    "8. 是否会在未经许可时启动或关闭 Ollama\n"
    "9. 未安装 / 已安装未运行 / 仅云端 / 非环回 四种状态是否可区分\n"
    "10. 是否有日志或错误信息会输出 prompt、模型正文或 token\n\n"
    "**你自己确认过没有 macOS 桌面**，所以 GUI 相关的项必须标 BLOCKED，不要标 PASS。\n"
    "开发侧的真机证据在 docs/qa/ollama-acceptance.md，供你核对，但不能替代你的结论。\n\n"
    "输出：每项 PASS/FAIL/BLOCKED + 文件:行 + 不超过 8 行原文 + 理由。"
    "发现新问题标 S1-S4（S1 = 声称的功能不可达，或数据发到非本机）。不要修改任何东西。"
)


def collect():
    files = {}
    for rel in FILES:
        path = os.path.join(REPO, rel.replace('/', os.sep))
        try:
            with open(path, encoding='utf-8') as handle:
                files[rel] = handle.read()
        except OSError:
            print('missing:', rel)
    return files


def main():
    files = collect()
    raw = json.dumps(files, ensure_ascii=False).encode('utf-8')
    packed = base64.b64encode(gzip.compress(raw, 9)).decode()
    print('files:', len(files), 'packed:', len(packed))

    task = {
        'recipient': 'muse-3',
        'kind': 'shortcutsense_ollama_review',
        'permissions': 'read_only',
        'instructions': INSTRUCTIONS,
        'inputs': {
            'encoding': 'json->gzip->base64',
            'sources_b64': packed,
            'file_count': len(files),
        },
    }
    path = os.path.join(TMP, 'muse-ollama-review.json')
    with open(path, 'w', encoding='utf-8') as handle:
        json.dump(task, handle, ensure_ascii=False)
    print('payload bytes:', os.path.getsize(path))

    with open(path, encoding='utf-8') as handle:
        result = subprocess.run(
            [sys.executable, 'queue_client.py', '--role', 'producer',
             '--producer', 'claude', '--method', 'POST', '--path', '/tasks'],
            stdin=handle, capture_output=True, text=True, cwd=QUEUE)
    out = result.stdout.strip()
    print('OUT:', out[:120])
    if out.startswith('{'):
        try:
            print('TASK:', json.loads(out).get('id'))
        except ValueError:
            pass
    print('ERR:', result.stderr[:200])
    return 0


if __name__ == '__main__':
    sys.exit(main())
