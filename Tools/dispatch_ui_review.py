"""Dispatches the UI review to Muse over the local queue."""

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
    'Sources/ShortcutSenseMac/Theme.swift',
    'Sources/ShortcutSenseMac/Components.swift',
    'Sources/ShortcutSenseMac/TodayDashboard.swift',
    'Sources/ShortcutSenseMac/ShortcutsDashboard.swift',
    'Sources/ShortcutSenseMac/ConflictDashboard.swift',
    'Sources/ShortcutSenseMac/SettingsDashboard.swift',
    'Sources/ShortcutSenseMac/WeeklyDashboard.swift',
    'Sources/ShortcutSenseMac/OpportunitiesDashboard.swift',
    'Sources/ShortcutSenseMac/RecommendationCardModel.swift',
    'Sources/ShortcutSenseMac/MenuBarPanel.swift',
    'Sources/ShortcutSenseMac/RootView.swift',
    'Sources/ShortcutSenseMac/AppDelegate.swift',
    'Sources/ShortcutSenseCore/TodayMetrics.swift',
]

INSTRUCTIONS = (
    "第三轮审阅：这一轮是全新写的 SwiftUI 前端，请重点看「会不会骗用户」。"
    "源码在 inputs.sources_b64（JSON→gzip→base64，键是路径）。\n\n"
    "背景：这个 App 的硬性要求是不得编造数据。具体包括：\n"
    "1. 不得声称未知来源的切换是「点击 Dock 或鼠标」。\n"
    "2. 不得显示未测量的使用时长，Top Apps 必须按按键数而不是时间排序。\n"
    "3. 不得画按字母的按键热力图——按设计根本不采集单字母频率。\n"
    "4. 不足 7 天真实数据时，周报必须显示 Preview，不能声称是一周结果。\n"
    "5. 热键 Apply 只有在系统真的接受注册后才能显示成功。\n"
    "6. AI 估计效果必须标注 estimated，不能用实测语气。\n"
    "7. 冲突状态「未发现已知冲突」不能说成「该组合空闲」。\n\n"
    "请逐条核对下列 UI 文件是否违反了上述任一条，并指出具体行：\n\n"
    "A. 数据真实性：Today/Shortcuts/Weekly 里每个数字是否都来自 DashboardService 或 store 查询？"
    "有没有任何硬编码的示例数字、假进度条、假图表？\n\n"
    "B. 热力图：Components.swift 的 ShortcutHeatmap 是否只按组合键着色？"
    "它有没有任何路径能表现出单字母频率？空态处理是否正确？\n\n"
    "C. 语义诚实：搜索所有面向用户的文案，有没有把 unknown_origin 暗示成鼠标/Dock？"
    "有没有把 estimated 写成实测？有没有承诺组合键一定空闲？\n\n"
    "D. Apply 流程：OpportunitiesDashboard 的 apply 是否走 ShortcutActionManager 并检查结果？"
    "失败时用户看到的是真实错误还是仍显示已启用？\n\n"
    "E. 空态：每个页面在数据库为空时会不会崩溃或显示空白？"
    "有没有页面会显示「0」却让人以为是真实测量（而不是无数据）？\n\n"
    "F. 隐私：UI 层有没有直接读 CGEvent、AX 标题或新增高频日志？"
    "Settings 里的权限说明是否准确？\n\n"
    "G. 可访问性：有没有 VoiceOver 标签、键盘可达性、色彩之外的第二信号？\n\n"
    "H. 本地化：有没有硬编码的英文字符串漏在视图里（应全部走 L.t）？\n\n"
    "输出：每项 PASS/FAIL/无法判断 + 文件:行 + 不超过 8 行原文 + 理由。"
    "发现新问题标 S1-S4，S1 定义为「向用户展示不真实的信息」。不要修改任何东西。"
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
        'kind': 'shortcutsense_ui_review',
        'permissions': 'read_only',
        'instructions': INSTRUCTIONS,
        'inputs': {
            'encoding': 'json->gzip->base64',
            'sources_b64': packed,
            'file_count': len(files),
        },
    }
    path = os.path.join(TMP, 'muse-ui-review.json')
    with open(path, 'w', encoding='utf-8') as handle:
        json.dump(task, handle, ensure_ascii=False)
    print('payload bytes:', os.path.getsize(path))

    with open(path, encoding='utf-8') as handle:
        result = subprocess.run(
            [sys.executable, 'queue_client.py', '--role', 'producer',
             '--producer', 'claude', '--method', 'POST', '--path', '/tasks'],
            stdin=handle, capture_output=True, text=True, cwd=QUEUE)
    out = result.stdout.strip()
    print('OUT:', out[:140])
    if out.startswith('{'):
        try:
            print('TASK:', json.loads(out).get('id'))
        except ValueError:
            pass
    print('ERR:', result.stderr[:200])
    return 0


if __name__ == '__main__':
    sys.exit(main())
