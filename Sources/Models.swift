import AppKit

// MARK: - 常量

/// 外部工具与项目相关的固定路径，集中维护，避免散落在各处。
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let adb = home.appendingPathComponent("Library/Android/sdk/platform-tools/adb")
    static let hdc = URL(fileURLWithPath: "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc")
    static let shell = URL(fileURLWithPath: "/bin/sh")
}

enum ToolboxConfig {
    private static let directory = Bundle.main.bundleURL.deletingLastPathComponent()

    static func value(_ key: String) -> String? {
        let url = directory.appendingPathComponent("toolbox.local.plist")
        guard let data = try? Data(contentsOf: url),
              let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let value = values[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    static func package(android: Bool) -> String? {
        value(android ? "AndroidPackage" : "HarmonyPackage")
    }
}

// MARK: - 脚本工具

/// 与目录中 `.command` 脚本一一对应的工具。
enum Tool: String, CaseIterable {
    case android = "Android Debug"
    case harmony = "鸿蒙 Debug"
    case gradleCleanup = "清理 Gradle 缓存"
    case cleanup = "清理项目构建产物"
    case screenshot = "手机截图"
    case uploadSymbol = "upload_symbol"

    var scriptName: String { rawValue }

    var title: String {
        switch self {
        case .android: "Android"
        case .harmony: "鸿蒙"
        case .gradleCleanup: rawValue
        case .cleanup: "清理构建产物"
        case .screenshot: "手机截图"
        case .uploadSymbol: "上传符号表"
        }
    }

    var detail: String {
        switch self {
        case .android: "打包 Android APK"
        case .harmony: "打包鸿蒙 HAP"
        case .gradleCleanup: "预览 Gradle 全局构建缓存，确认后移到废纸篓"
        case .cleanup: "扫描 已配置项目中超过 21 天的可重建目录，确认后移到废纸篓"
        case .screenshot: "截取 Android 或鸿蒙手机的当前屏幕，自动复制到剪贴板"
        case .uploadSymbol: "将指定版本的 mapping 上传到 Bugly"
        }
    }

    var project: String? {
        switch self {
        case .android: ToolboxConfig.value("AndroidProject")
        case .harmony: ToolboxConfig.value("HarmonyProject")
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .android: "hammer.fill"
        case .harmony: "shippingbox.fill"
        case .gradleCleanup: "externaldrive.fill"
        case .cleanup: "trash.fill"
        case .screenshot: "camera.viewfinder"
        case .uploadSymbol: "arrow.up.doc.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .android: .systemGreen
        case .harmony: .systemBlue
        case .gradleCleanup: .systemOrange
        case .cleanup: .systemOrange
        case .screenshot: .systemPurple
        case .uploadSymbol: .systemTeal
        }
    }

    /// Release 运行时在界面上显示的名字。
    func displayName(arguments: [String]) -> String {
        if self == .android, arguments == ["--rebuild-channel"] { return "Android 渠道重打包" }
        if self == .cleanup, arguments == ["--history"] { return "盘点历史构建" }
        if self == .screenshot, arguments == ["--save-last"] { return "保存上次截图到桌面" }
        return arguments.first == "--release" ? rawValue.replacingOccurrences(of: " Debug", with: " Release") : rawValue
    }
}

// MARK: - 页面

enum Page: Int, CaseIterable {
    case build, screenshot, logs, cleanup, upload, settings, localize

    var title: String {
        switch self {
        case .build: "打包"
        case .screenshot: "手机截图"
        case .logs: "设备日志"
        case .cleanup: "清理构建产物"
        case .upload: "上传符号"
        case .settings: "设置"
        case .localize: "Antigravity"
        }
    }

    var subtitle: String {
        switch self {
        case .build: "打包配置中的 Android 与鸿蒙安装包。安装并启动请使用右上角的「运行」。"
        case .screenshot: "截取已连接手机的当前屏幕。"
        case .logs: "实时查看 logcat / hilog，支持组合筛选与收藏。"
        case .cleanup: "释放磁盘空间，移动前会先列出清单等待确认。"
        case .upload: "把混淆 mapping 上传到 Bugly，便于还原崩溃堆栈。"
        case .settings: "开发工具箱的偏好设置。"
        case .localize: "更新客户端版本、应用授权补丁，或安装社区中文补丁。"
        }
    }

    var symbol: String {
        switch self {
        case .build: "hammer.fill"
        case .screenshot: "camera.viewfinder"
        case .logs: "list.bullet.rectangle.fill"
        case .cleanup: "trash.fill"
        case .upload: "arrow.up.doc.fill"
        case .settings: "gearshape.fill"
        case .localize: "character.bubble.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .build: .systemGreen
        case .screenshot: .systemPurple
        case .logs: .systemIndigo
        case .cleanup: .systemOrange
        case .upload: .systemTeal
        case .settings: .systemGray
        case .localize: .systemBlue
        }
    }

    /// 侧栏排列：分组标题与页面。
    static let sidebarLayout: [(section: String, pages: [Page])] = [
        ("构建与发布", [.build, .upload]),
        ("设备", [.screenshot, .logs]),
        ("维护", [.cleanup, .localize, .settings]),
    ]
}

// MARK: - 设备

struct Device: Equatable {
    enum Platform: String {
        case android = "Android"
        case harmony = "鸿蒙"

        var tint: NSColor { self == .android ? .systemGreen : .systemBlue }
    }

    let platform: Platform
    let serial: String
    let label: String

    var isAndroid: Bool { platform == .android }
    var buildTool: Tool { isAndroid ? .android : .harmony }

    init(platform: Platform, serial: String, label: String) {
        self.platform = platform
        self.serial = serial
        self.label = label
    }

    /// 解析 `手机截图.command --list-devices` 的一行：平台\t序列号\t显示名。
    init?(fields: [String]) {
        guard fields.count == 3, let platform = Platform(rawValue: fields[0]) else { return nil }
        self.init(platform: platform, serial: fields[1], label: fields[2])
    }

    func identifies(_ other: Device) -> Bool {
        platform == other.platform && serial == other.serial
    }
}

// MARK: - 进程

enum Shell {
    /// 同步执行并返回标准输出；启动失败或退出码非 0 时返回 nil。请在后台线程调用。
    static func capture(_ url: URL, _ arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = url
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// 解析 `pm list packages -U` 输出：包名 -> UID 集合。
    static func packageUIDs(_ listing: Data) -> [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        for line in String(decoding: listing, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, first.hasPrefix("package:"),
                  let value = fields.first(where: { $0.hasPrefix("uid:") }),
                  let uid = Int(value.dropFirst(4)) else { continue }
            result[String(first.dropFirst(8)), default: []].insert(uid)
        }
        return result
    }
}

// MARK: - 日志筛选

struct LogQuery {
    private static let tokens = try! NSRegularExpression(pattern: #"(?:[^\s"]+|"[^"]*")+"#)
    static let levels = ["verbose": 1, "debug": 2, "info": 3, "warn": 4, "error": 5, "fatal": 6]
    var package = ""
    var tag = ""
    var level = 0
    var words: [String] = []
    var error: String?

    init(_ query: String, android: Bool, configuredPackage: String? = nil) {
        let source = query as NSString
        for match in Self.tokens.matches(in: query, range: NSRange(location: 0, length: source.length)) {
            let token = source.substring(with: match.range).replacingOccurrences(of: "\"", with: "")
            let pair = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                if !token.isEmpty { words.append(token) }
                continue
            }
            let value = String(pair[1])
            switch pair[0].lowercased() {
            case "package":
                if value.lowercased() == "mine" {
                    package = configuredPackage ?? ToolboxConfig.package(android: android) ?? ""
                    if package.isEmpty { error = "请先在 toolbox.local.plist 中填写应用包名。" }
                } else {
                    package = value
                }
            case "tag":
                tag = value
            case "level":
                if let minimum = Self.levels[value.lowercased()] { level = minimum }
                else { error = "级别可用 verbose、debug、info、warn、error 或 fatal。" }
            case "message":
                if !value.isEmpty { words.append(value) }
            default:
                if !token.isEmpty { words.append(token) }
            }
        }
    }
}

struct LogLine {
    private static let header = try! NSRegularExpression(
        pattern: #"^\d{2}-\d{2}\s+\S+\s+(?:(\S+)\s+)?\d+\s+\d+\s+([VDIWEFA])\s+([^:]*):\s?(.*)$"#)
    private static let harmonyHeader = try! NSRegularExpression(
        pattern: #"^\d{2}-\d{2}\s+\S+\s+\d+\s+\d+\s+([DIWEF])\s+[^/\s]+/([^/\s]+)/([^:]*):\s?(.*)$"#)
    private static let priorities = ["V": 1, "D": 2, "I": 3, "W": 4, "E": 5, "F": 6, "A": 6]
    private static let colors: [NSColor] = [.textColor, .secondaryLabelColor, .systemBlue, .systemGreen,
                                            .systemOrange, .systemRed, .systemPurple]

    let raw: String
    var uid: Int?
    var processName = ""
    var level = 0
    var tag = ""
    var message: String
    private var priority = ""

    var color: NSColor { Self.colors[level] }

    init(_ raw: String, android: Bool) {
        self.raw = raw
        message = raw
        let line = raw as NSString
        let header = android ? Self.header : Self.harmonyHeader
        guard let match = header.firstMatch(in: raw, range: NSRange(location: 0, length: line.length)) else { return }
        if android {
            let uidRange = match.range(at: 1)
            if uidRange.location != NSNotFound {
                let token = line.substring(with: uidRange)
                uid = Int(token) ?? ["root": 0, "shell": 2000][token]
            }
        } else {
            processName = line.substring(with: match.range(at: 2))
        }
        priority = line.substring(with: match.range(at: android ? 2 : 1))
        level = Self.priorities[priority] ?? 0
        tag = line.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
        message = line.substring(with: match.range(at: 4))
    }

    func displayText(compact: Bool) -> String {
        guard compact, !priority.isEmpty else { return raw }
        let time = raw.split(maxSplits: 2, whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        return "\(time) \(priority) \(tag): \(message)"
    }

    func matches(level minimum: Int, uids: Set<Int>?, tag exactTag: String, keyword: String,
                 processPackage: String = "") -> Bool {
        level >= minimum
            && (uids == nil || uid.map { uids?.contains($0) == true } == true)
            // HiLog 每行都带进程名，新 PID 无需额外查询。
            && (processPackage.isEmpty || processName == processPackage || processName.hasPrefix(processPackage + ":"))
            && (exactTag.isEmpty || tag == exactTag)
            && (keyword.isEmpty || message.localizedCaseInsensitiveContains(keyword))
    }

    /// 按完整筛选条件匹配。Android 用 UID 过滤包名，鸿蒙用进程名。
    func matches(_ query: LogQuery, android: Bool, uids: Set<Int>?) -> Bool {
        guard query.error == nil else { return false }
        return matches(level: query.level, uids: android && !query.package.isEmpty ? (uids ?? []) : nil,
                       tag: query.tag, keyword: "", processPackage: android ? "" : query.package)
            && query.words.allSatisfy { message.localizedCaseInsensitiveContains($0) }
    }
}

/// 后台线程写入、主线程定时取出的日志缓冲区，超过上限时丢弃较早的数据。
final class LogInbox {
    private let lock = NSLock()
    private var pending = Data()
    private var skipped = false
    private var status: Int32?
    private let limit = 256 * 1024

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(chunk)
        if pending.count > limit {
            skipped = true
            pending = Data(pending.suffix(limit))
        }
    }

    func finish(_ status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
    }

    func drain() -> (Data, Bool, Int32?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (pending, skipped, status)
        pending = Data()
        skipped = false
        return result
    }
}
