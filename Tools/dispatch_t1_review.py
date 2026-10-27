"""Dispatches the T1 / Learn review to Muse over the local queue."""

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
    'Sources/ShortcutSenseCore/PatternDiscovery.swift',
    'Sources/ShortcutSenseCore/Store.swift',
    'Sources/ShortcutSenseCore/PrivacyGate.swift',
    'Sources/ShortcutSenseCore/AXMenuCodec.swift',
    'Sources/ShortcutSenseCore/ShortcutActionManager.swift',
    'Sources/ShortcutSenseMac/AppController.swift',
    'Sources/ShortcutSenseMac/PatternModels.swift',
    'Sources/ShortcutSenseMac/LearnView.swift',
    'Sources/ShortcutSenseMac/MenuObserver.swift',
    'Sources/ShortcutSenseMac/AXSpike.swift',
]

INSTRUCTIONS = (
    "第五轮：审阅新加的「受控 T1 行为记录 + 自动 Learn + 工作区建议」。"
    "源码在 inputs.sources_b64（JSON→gzip→base64）。\n\n"
    "背景：产品负责人批准了 T1 分层。T1 必须默认关闭、用户显式开启、只记录受控事件、"
    "原始行 14 天后清理。Learn 必须来自经验证的点击（7 次 / 2 天），手动标记绝不能"
    "被当成点击次数。工作区只能启动 2–3 个已安装应用，不能执行脚本或 URL。\n\n"
    "请逐条核对：\n"
    "1. T1 默认是否关闭？是否只有用户显式开启后 menu observation 才运行？"
    "关闭后是否立即停止？\n"
    "2. T1 表里有没有任何字段可能存窗口标题、URL、文件名、按键或亚小时时间？"
    "`safe_static_label` 的过滤链是否足够（AXMenuCodec.isSafeStaticTitle 是否覆盖所有写入点）？\n"
    "3. 原始 T1 行是否 14 天清理？清理后日报聚合是否保留？\n"
    "4. Learn 阈值是否为 7 次 + 2 天？手动标记是否 observedCount = nil（绝不被当成 7 次）？\n"
    "5. 工作区组是否限制 2–3 个应用？是否只允许已安装？是否存在执行脚本/URL 的路径？\n"
    "6. 工作区 Apply 是否走 ShortcutActionManager 的冲突检查与白名单？\n"
    "7. 关闭 T1 后是否还有任何代码路径在写 t1_sessions 或 menu_action_stats？\n"
    "8. deleteAllData 是否清空 t1_sessions？clearT1 是否保留手动标记？\n"
    "9. 是否有任何日志输出用户数据？\n"
    "10. AXSpike 的合成点击是否会意外触发真实菜单动作（副作用）？它只用于测量还是"
    "会被产品路径调用？\n\n"
    "输出：每项 PASS/FAIL/无法判断 + 文件:行 + 不超过 8 行原文 + 理由。"
    "新问题标 S1-S4（S1 = 隐私泄漏或伪造证据）。不要修改任何东西。"
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
        'recipient': 'muse-2',
        'kind': 'shortcutsense_t1_review',
        'permissions': 'read_only',
        'instructions': INSTRUCTIONS,
        'inputs': {
            'encoding': 'json->gzip->base64',
            'sources_b64': packed,
            'file_count': len(files),
        },
    }
    path = os.path.join(TMP, 'muse-t1-review.json')
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
