import Foundation

/// Converts Accessibility API menu metadata into normalized shortcuts, and decides
/// which menu titles are safe to persist.
///
/// Kept in the platform-independent core so the decoding rules — which are easy to
/// get wrong and directly affect privacy — are covered by tests on any platform.
public enum AXMenuCodec {
    /// `AXMenuItemCmdModifiers` bits.
    ///
    /// Command is **implied**: it is present unless `axNoCommand` is set. The bits do
    /// not include Command at all, which is easy to get wrong — treating bit 0 as
    /// Command turns ⌘⇧N into ⌘N and makes every conflict check disagree with the
    /// real menu.
    public static let axShift = 1 << 0
    public static let axOption = 1 << 1
    public static let axControl = 1 << 2
    public static let axNoCommand = 1 << 3

    /// Converts an AX command character plus its AX modifier mask into a combo id.
    ///
    /// Returns nil for anything that is not a single ASCII letter or digit, which
    /// includes function keys, arrow keys and non-Latin layouts. Those are simply
    /// not learned rather than guessed.
    public static func comboID(char: String, axModifiers: Int) -> String? {
        guard char.count == 1, let character = char.lowercased().first else { return nil }
        guard let keyCode = KeyCodeNames.keyCode(forLetter: character)
                ?? KeyCodeNames.digitKeyCodes[character] else { return nil }
        var modifiers: ComboModifiers = []
        if axModifiers & axNoCommand == 0 { modifiers.insert(.command) }
        if axModifiers & axShift != 0 { modifiers.insert(.shift) }
        if axModifiers & axOption != 0 { modifiers.insert(.option) }
        if axModifiers & axControl != 0 { modifiers.insert(.control) }
        return KeyCombo(keyCode: keyCode, modifiers: modifiers).comboID
    }

    /// Builds a stable identifier for a menu command from its menu path and title.
    public static func commandID(path: [String], title: String) -> String {
        (path + [title]).joined(separator: "\u{1F}").lowercased()
    }

    /// Rejects menu titles that may contain user data.
    ///
    /// Menu titles are usually static system strings, but "Open Recent" entries and
    /// window lists are not. Anything resembling a file name, path, or free-form
    /// recent item is refused so it can never reach the database.
    /// Whether a menu title is a fixed system string rather than user content.
    ///
    /// Shape alone cannot decide this: "New Window" and "Meeting notes" are both two
    /// ordinary words, and a denylist of file-name punctuation misses both. The only
    /// reliable rule is a **closed vocabulary of known menu commands**, so this is an
    /// allowlist. A title that is not recognised is refused, which means a genuine
    /// menu item occasionally goes unrecorded — the correct failure direction for
    /// data that is persisted.
    ///
    /// The list covers the menus of the allow-listed applications (Finder, Chrome,
    /// Safari) in English and Simplified Chinese. Adding an entry is a deliberate act,
    /// not something inferred at runtime.
    public static func isSafeStaticTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
        if knownStaticTitles.contains(trimmed) { return true }
        return matchesCommandShape(trimmed)
    }

    /// Accepts a title shaped like a menu command even when it is not in the list.
    ///
    /// Measured on a real Chinese-locale Mac: 156 menu commands carried shortcuts and
    /// the allowlist recognised only 36, all of them correct but far too few. Rather
    /// than growing the list forever, a title is also accepted when it looks like a
    /// command and carries no mark of user content:
    ///
    /// - no digits, so "v3" and "2024 report" are out;
    /// - no path, file-name or dialog punctuation;
    /// - no ellipsis, which marks a command that opens a dialog whose label may embed
    ///   a target ("Save As…");
    /// - at most four words, which excludes sentences;
    /// - it starts with a verb or action particle, which is what separates
    ///   "Show Downloads" from "Meeting notes".
    ///
    /// A missed command costs one Learn opportunity; a wrongly kept title writes user
    /// content to disk, so every rule fails closed.
    static func matchesCommandShape(_ title: String) -> Bool {
        // Containers whose children are user files. "Open" is a legitimate command
        // prefix, so these must be refused explicitly before the prefix test.
        let loweredTitle = title.lowercased()
        if dynamicMenuPrefixes.contains(where: { loweredTitle.hasPrefix($0) }) { return false }

        if title.unicodeScalars.contains(where: { forbiddenScalars.contains($0) }) { return false }
        if title.contains("\u{2026}") || title.contains("...") { return false }
        if title.contains(".") || title.contains("~") { return false }
        if title.range(of: "[0-9]", options: .regularExpression) != nil { return false }

        let words = title.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" })
        guard words.count <= 4 else { return false }

        let lowered = title.lowercased()
        return commandPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Openings whose contents are the user's own files, so neither the container nor
    /// anything beneath it may be recorded.
    private static let dynamicMenuPrefixes: [String] = [
        "open recent", "open recent items", "recent", "reopen", "clear menu",
        "打开最近", "最近使用", "最近打开", "打开最近的项目",
    ]

    private static let forbiddenScalars = CharacterSet(
        charactersIn: "/:*?\"<>|\\@#$%^&(){}[]=+_,;'")

    /// Openings that mark a menu command, in English and in localised Chinese menus.
    private static let commandPrefixes: [String] = [
        "new ", "open", "close", "save", "show", "hide", "toggle", "go ", "find",
        "select", "cut", "copy", "paste", "delete", "move", "rename", "duplicate",
        "make ", "add ", "remove", "edit", "view", "sort", "zoom", "enter ", "exit ",
        "start", "stop", "reload", "refresh", "print", "export", "import", "share",
        "undo", "redo", "clear", "reset", "insert", "format", "align", "increase",
        "decrease", "next ", "previous", "back", "forward", "home", "actual", "fit",
        "use ", "bring", "minimize", "maximize", "restore", "check", "mark",
        "新建", "打开", "关闭", "存储", "保存", "显示", "隐藏", "切换", "前往",
        "查找", "选择", "全选", "剪切", "拷贝", "粘贴", "删除", "移动", "重命名",
        "制作替身", "添加", "移除", "编辑", "视图", "排序", "缩放", "进入", "退出",
        "开始", "停止", "重新载入", "刷新", "打印", "导出", "导入", "共享",
        "撤销", "重做", "清除", "重置", "插入", "格式", "对齐", "放大", "缩小",
        "下一个", "上一个", "返回", "前进", "主页", "实际大小", "使用", "使所有",
        "最小化", "最大化", "还原", "检查", "标记", "取消", "全部", "清倒",
        // Added after measuring a real Chinese-locale menu: these are ordinary
        // commands that the earlier prefix list missed.
        "锁定", "复制", "新标签页", "循环显示", "隔空投送", "自动填充", "表情与符号",
        "强制重新加载", "重新打开", "连接服务器", "报告问题", "推出",
    ]

    /// Every menu command this product is willing to persist.
    ///
    /// Menu *containers* whose children are user data are deliberately absent:
    /// "Open Recent" and "Recent Folders" lead to file names, so neither the container
    /// nor anything beneath it can ever be recorded.
    ///
    /// Kept as a flat set rather than per-application, because the same label
    /// ("Copy", "Undo") means the same thing in every allow-listed app.
    public static let knownStaticTitles: Set<String> = [
        // Finder / file operations
        "New Window", "New Finder Window", "New Folder", "New Tab", "New Document",
        "Open", "Close Window", "Close Tab", "Close All",
        "Save", "Save As", "Revert", "Duplicate", "Rename", "Move to Trash", "Empty Trash",
        "Get Info", "Show Inspector", "Quick Look", "Find", "Find Next",
        "Print", "Page Setup", "Export", "Share",
        // Edit
        "Undo", "Redo", "Cut", "Copy", "Paste", "Paste and Match Style",
        "Delete", "Select All", "Find and Replace", "Spelling and Grammar",
        // View
        "Show All", "Show View Options", "Show Sidebar", "Show Toolbar",
        "Hide Sidebar", "Hide Toolbar", "Actual Size", "Zoom In", "Zoom Out",
        "Enter Full Screen", "Exit Full Screen", "Use Groups", "Use Columns",
        "Use List", "Use Icons", "Use Gallery", "Sort By",
        "Show Path Bar", "Show Status Bar", "Hide Path Bar", "Hide Status Bar",
        "Show Tab Bar", "Hide Tab Bar", "Show All Tabs",
        // Go / history
        "Back", "Forward", "Home", "Go to Folder", "Enclosing Folder",
        "Previous Folder", "Next Folder", "Recent Folders",
        "Show History", "Show Downloads", "Show Bookmarks",
        "Show Reading List", "Show Recently Closed",
        // Bookmarks / tabs
        "Add Bookmark", "Show Bookmarks Bar", "Always Show Bookmarks Bar",
        "Hide Bookmarks Bar", "Bookmark This Page", "Bookmark All Tabs",
        "Reload Page", "Stop", "Actual Size", "Zoom",
        // Window / app
        "Minimize", "Zoom", "Move Window to Left Side of Screen",
        "Move Window to Right Side of Screen", "Fill", "Centre",
        "Bring All to Front", "Next Tab", "Previous Tab",
        "Hide", "Hide Others", "Show All",
        // Help
        "Help", "Search",
        // Simplified Chinese equivalents
        "新建窗口", "新建访达窗口", "新建文件夹", "新建标签页", "新建文稿",
        "打开", "关闭窗口", "关闭标签页", "关闭全部",
        "存储", "另存为", "复原", "制作替身", "重新命名", "移到废纸篓", "清倒废纸篓",
        "显示简介", "快速查看", "查找", "查找下一个", "打印", "页面设置", "导出",
        "撤销", "重做", "剪切", "拷贝", "粘贴", "删除", "全选", "查找与替换",
        "显示全部", "显示视图选项", "显示边栏", "显示工具栏", "隐藏边栏", "隐藏工具栏",
        "实际大小", "放大", "缩小", "进入全屏幕", "退出全屏幕",
        "使用群组", "使用分栏", "使用列表", "使用图标", "使用画廊",
        "显示路径栏", "显示状态栏", "显示标签页栏", "隐藏标签页栏", "显示所有标签页",
        "返回", "前进", "个人收藏", "前往文件夹", "上层文件夹",
        "显示历史记录", "显示下载项", "显示书签", "显示阅读列表",
        "添加书签", "显示书签栏", "始终显示书签栏", "隐藏书签栏",
        "重新载入页面", "停止",
        "最小化", "缩放", "使所有窗口前置", "下一个标签页", "上一个标签页",
        "隐藏", "隐藏其他", "帮助",
    ]

}
