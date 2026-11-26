import AppKit
import CoreServices
import ServiceManagement

final class Toolbox: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation,
                       NSTableViewDataSource, NSTableViewDelegate {
    private enum SidebarRow {
        case section(String)
        case page(Page)
    }

    private let sidebarRows: [SidebarRow] = Page.sidebarLayout.flatMap { group in
        [.section(group.section)] + group.pages.map { .page($0) }
    }

    private let scriptsDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
    private let loginService = SMAppService.mainApp
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private var window: NSWindow?
    private let sidebar = NSTableView()
    private let tabs = NSTabView()

    // 顶部运行栏
    private let runDevicePicker = DevicePicker(allowsEmptySelection: false, maxWidth: 340)
    private let runBuildPicker = NSSegmentedControl(labels: ["Debug", "Release"], trackingMode: .selectOne,
                                                    target: nil, action: nil)
    private var refreshButton: ActionButton?
    private var runButton: ActionButton?
    private var isRefreshingDevices = false

    // 子模块
    private let runner = ProcessRunner()
    private lazy var logController = LogController { [weak self] in self?.refreshDevices() }

    // 截图与设置控件
    private var screenshotDevicePicker: DevicePicker?
    private var screenshotCaptureButton: ActionButton?
    private var loginButton: NSButton?
    private var loginStatusLabel: NSTextField?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        statusItem.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "开发工具箱")
        statusItem.button?.toolTip = "开发工具箱"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showWindow)

        runner.onStateChange = { [weak self] in
            self?.updateRunButton()
            self?.updateRunnerVisibility()
        }
        runner.onAlert = { [weak self] title, detail in self?.showAlert(title, detail) }

        if CommandLine.arguments.contains("--check-login") {
            runLoginCheck()
            return
        }
        if CommandLine.arguments.contains("--check") {
            runSelfCheck()
            return
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"),
           idx + 1 < CommandLine.arguments.count {
            runSnapshot(to: URL(fileURLWithPath: CommandLine.arguments[idx + 1]))
            return
        }

        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) == nil {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) { updateLoginControls() }

    func applicationWillTerminate(_ notification: Notification) {
        logController.stop()
        runner.terminate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        logController.stop()
    }

    // MARK: - 菜单与快捷键

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let hide = appMenu.addItem(withTitle: "隐藏开发工具箱", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出开发工具箱", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "关闭窗口", action: #selector(closeMainWindow), keyEquivalent: "w").target = self
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        edit.addItem(.separator())
        edit.addItem(withTitle: "查找日志…", action: #selector(findInLogs), keyEquivalent: "f").target = self
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeMainWindow): return window?.isVisible == true
        case #selector(findInLogs): return canFindInLogs
        default: return true
        }
    }

    @objc private func closeMainWindow() { window?.performClose(nil) }

    private var canFindInLogs: Bool {
        tabs.selectedTabViewItem?.identifier as? Int == Page.logs.rawValue
    }

    @objc private func findInLogs() {
        guard canFindInLogs else { return }
        logController.showFindBar()
    }

    // MARK: - 主窗口与侧栏

    @objc private func showWindow() {
        let shouldRefresh = window?.isVisible != true
        if window == nil { buildWindow() }
        updateLoginControls()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        if shouldRefresh && !CommandLine.arguments.contains("--check") { refreshDevices() }
    }

    private func buildWindow() {
        let height = min(740, (NSScreen.main?.visibleFrame.height ?? 800) - 48)
        let width = min(1040, (NSScreen.main?.visibleFrame.width ?? 1140) - 36)
        let panel = ToolboxWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = "开发工具箱"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 880, height: 480)
        panel.delegate = self
        window = panel

        tabs.tabViewType = .noTabsNoBorder
        for page in Page.allCases {
            let item = NSTabViewItem(identifier: page.rawValue)
            item.view = makePageView(page)
            tabs.addTabViewItem(item)
        }

        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.headerView = nil
        sidebar.style = .inset
        sidebar.floatsGroupRows = false
        sidebar.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sidebar.allowsEmptySelection = false
        sidebar.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.width = 186
        sidebar.addTableColumn(column)
        sidebar.setAccessibilityLabel("工具导航")
        sidebar.reloadData()

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        let brand = UI.hstack([
            IconBadge(symbol: "wrench.and.screwdriver.fill", tint: .controlAccentColor, size: 26, solid: true),
            UI.label("开发工具箱", size: 14, weight: .semibold),
        ], spacing: 8)
        brand.translatesAutoresizingMaskIntoConstraints = false

        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.addSubview(brand)
        material.addSubview(sidebarScroll)

        let divider = UI.separator()
        let body = makeContentBody()
        let root = NSView(frame: panel.contentLayoutRect)
        root.wantsLayer = true
        panel.contentView = root

        for columnView in [material, divider, body] {
            columnView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(columnView)
            columnView.topAnchor.constraint(equalTo: root.topAnchor).isActive = true
            columnView.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            material.widthAnchor.constraint(equalToConstant: 204),
            divider.leadingAnchor.constraint(equalTo: material.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            body.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            brand.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 16),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: material.trailingAnchor, constant: -12),
            brand.topAnchor.constraint(equalTo: material.topAnchor, constant: 34),

            sidebarScroll.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 6),
            sidebarScroll.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -6),
            sidebarScroll.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 10),
            sidebarScroll.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -8),
        ])

        selectPage(.build)
        panel.center()
    }

    private func makeContentBody() -> NSView {
        tabs.setContentHuggingPriority(.init(1), for: .vertical)
        let container = UI.vstack([], spacing: 0)
        container.addFullWidth(makeRunBar())
        container.addFullWidth(UI.separator())
        container.addFullWidth(tabs)
        container.addFullWidth(runner.container)
        return container
    }

    private func makeRunBar() -> NSStackView {
        runDevicePicker.onChange = { [weak self] _ in self?.updateRunButton() }
        runBuildPicker.selectedSegment = 0
        runBuildPicker.segmentStyle = .rounded
        runBuildPicker.setAccessibilityLabel("运行包型")

        let refresh = ActionButton("刷新设备", symbol: "arrow.clockwise", style: .icon) { [weak self] in
            self?.refreshDevices()
        }
        refreshButton = refresh

        let run = ActionButton("运行", symbol: "play.fill", style: .prominent) { [weak self] in
            guard let self, let command = self.runCommand else { return }
            self.run(command.tool, command.arguments)
        }
        runButton = run
        updateRunButton()

        let bar = UI.hstack([
            UI.spacer(),
            UI.label("设备", size: 12, weight: .medium, color: .secondaryLabelColor),
            runDevicePicker,
            runBuildPicker,
            refresh,
            run,
        ], spacing: 8)
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
        return bar
    }

    // MARK: - 侧栏数据源与代理

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarRows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = sidebarRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .page = sidebarRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = sidebarRows[row] { return 24 }
        return 34
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch sidebarRows[row] {
        case .section(let title):
            let cell = NSTableCellView()
            let label = UI.label(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
            ])
            return cell
        case .page(let page):
            let cell = NSTableCellView()
            let badge = IconBadge(symbol: page.symbol, tint: page.tint, size: 22, solid: true)
            let label = UI.label(page.title, size: 13, weight: .medium)
            let rowView = UI.hstack([badge, label], spacing: 9)
            cell.addSubview(rowView)
            rowView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                rowView.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    private var currentPage: Page? {
        guard let id = tabs.selectedTabViewItem?.identifier as? Int else { return nil }
        return Page(rawValue: id)
    }

    private func updateRunnerVisibility() {
        guard let page = currentPage else { return }
        runner.isHidden = page == .logs || (!runner.isRunning && page == .settings)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, row < sidebarRows.count, case .page(let page) = sidebarRows[row] else { return }
        tabs.selectTabViewItem(at: page.rawValue)
        updateRunnerVisibility()
        if page == .settings { updateLoginControls() }
    }

    private func selectPage(_ page: Page) {
        guard let row = sidebarRows.firstIndex(where: {
            if case .page(let candidate) = $0 { return candidate == page }
            return false
        }) else { return }
        sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - 页面构建

    private func makePageView(_ page: Page) -> NSView {
        if page == .logs { return logController.view }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let document = FlippedView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false

        let stack = UI.vstack([], spacing: 14)
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
        ])

        let header = UI.vstack([
            UI.label(page.title, size: 24, weight: .bold),
            UI.note(page.subtitle),
        ], spacing: 3)
        stack.addFullWidth(header)

        switch page {
        case .build:
            stack.addFullWidth(makeBuildCard(.android))
            stack.addFullWidth(makeBuildCard(.harmony))
        case .screenshot:
            stack.addFullWidth(makeScreenshotCard())
        case .cleanup:
            stack.addFullWidth(makeBuildHistoryCard())
            stack.addFullWidth(makeCleanupCard())
            stack.addFullWidth(makeCleanupCard(.gradleCleanup))
        case .upload:
            stack.addFullWidth(makeUploadCard())
        case .localize:
            stack.addFullWidth(makeAntigravityUpdateCard())
            stack.addFullWidth(makeLocalizationCard())
        case .settings:
            stack.addFullWidth(makeSettingsLoginCard())
            stack.addFullWidth(makeSettingsInfoCard())
        case .logs:
            break
        }
        return scroll
    }

    private func makeBuildCard(_ tool: Tool) -> Card {
        let card = Card()
        card.addFullWidth(UI.cardHeader(symbol: tool.symbol, tint: tool.tint, title: tool.title, detail: tool.detail))
        let debug = ActionButton("打包 Debug", symbol: "hammer") { [weak self] in self?.run(tool, ["1"]) }
        let release = ActionButton("打包 Release", symbol: "shippingbox") { [weak self] in
            self?.run(tool, ["--release", "1"])
        }
        var buildButtons: [NSView] = [debug, release]
        if tool == .android, ToolboxConfig.value("AndroidChannelTask") != nil {
            buildButtons.append(ActionButton("重打渠道包", symbol: "shippingbox") { [weak self] in
                self?.run(.android, ["--rebuild-channel"])
            })
        }
        let pathLabel = UI.label(tool.project ?? "", size: 11, weight: .regular, color: .tertiaryLabelColor)
        card.addFullWidth(UI.hstack(buildButtons + [UI.spacer(), pathLabel], spacing: 10))

        let folders: [(String, String, Bool)]
        if tool == .android {
            folders = [
                ("打开 Mapping", "AndroidMappingDirectory", false),
                ("打开 Debug", "AndroidDebugMetadata", true),
                ("打开 Release", "AndroidReleaseMetadata", true),
                ("打开渠道包", "AndroidChannelDirectory", false),
            ]
        } else {
            folders = [
                ("打开 Debug", "HarmonyDebugHap", true),
                ("打开 Release", "HarmonyReleaseHap", true),
            ]
        }
        let folderButtons = folders.compactMap { title, key, isFile -> NSView? in
            guard let path = ToolboxConfig.value(key) else { return nil }
            return ActionButton(title, symbol: "folder") { [weak self] in
                guard let self, let project = tool.project else { return }
                let root = (project as NSString).expandingTildeInPath
                let configuredURL = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
                let folder = isFile ? configuredURL.deletingLastPathComponent() : configuredURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    self.showAlert("打包目录尚未生成", folder.path)
                    return
                }
                if !NSWorkspace.shared.open(folder) {
                    self.showAlert("无法打开打包目录", folder.path)
                }
            }
        }
        card.addFullWidth(UI.hstack(folderButtons + [UI.spacer()], spacing: 10))
        return card
    }

    private func makeScreenshotCard() -> Card {
        let card = Card()
        let tool = Tool.screenshot
        card.addFullWidth(UI.cardHeader(symbol: tool.symbol, tint: tool.tint, title: tool.title, detail: tool.detail))

        let picker = DevicePicker(allowsEmptySelection: false, maxWidth: 420)
        let refresh = ActionButton("刷新设备", symbol: "arrow.clockwise", style: .icon) { [weak self] in
            self?.refreshDevices()
        }
        let capture = ActionButton("截取屏幕", symbol: "camera.fill", style: .prominent) { [weak self] in
            guard let self, let device = picker.selectedDevice else { return }
            self.run(.screenshot, [device.platform.rawValue, device.serial])
        }
        let save = ActionButton("保存上次截图到桌面", symbol: "square.and.arrow.down") { [weak self] in
            self?.run(.screenshot, ["--save-last"])
        }
        capture.isEnabled = false
        screenshotDevicePicker = picker
        screenshotCaptureButton = capture

        let row = UI.hstack([
            UI.label("目标设备", size: 12, weight: .medium, color: .secondaryLabelColor),
            picker,
            refresh,
            UI.spacer(),
            capture,
            save,
        ], spacing: 8)
        card.addFullWidth(row)
        return card
    }

    private func makeBuildHistoryCard() -> Card {
        let card = Card()
        card.addFullWidth(UI.cardHeader(
            symbol: "archivebox", tint: .systemBlue, title: "历史构建产物",
            detail: "查看已配置项目的安装包、符号表和验收批次"
        ))
        let preview = ActionButton("盘点历史构建", symbol: "eye") { [weak self] in
            self?.run(.cleanup, ["--history"])
        }
        card.addFullWidth(UI.hstack([preview, UI.spacer()], spacing: 10))
        return card
    }

    private func makeCleanupCard(_ tool: Tool = .cleanup) -> Card {
        let card = Card()
        card.addFullWidth(UI.cardHeader(symbol: tool.symbol, tint: tool.tint, title: tool.title, detail: tool.detail))

        let preview = ActionButton("仅预览", symbol: "eye") { [weak self] in self?.run(tool, ["--preview"]) }
        let clean = ActionButton("开始清理", symbol: "trash", style: .destructive) { [weak self] in
            self?.run(tool, ["--confirm-stdin"])
        }
        card.addFullWidth(UI.hstack([preview, clean], spacing: 10))
        card.addFullWidth(UI.note("点击「开始清理」后，请在下方输出框核对目录并输入 CLEAN 确认。"))
        return card
    }

    private func makeUploadCard() -> Card {
        let card = Card()
        let tool = Tool.uploadSymbol
        card.addFullWidth(UI.cardHeader(symbol: tool.symbol, tint: tool.tint, title: tool.title, detail: tool.detail))

        let version = NSTextField()
        version.placeholderString = "例如 3.30.41"
        version.setAccessibilityLabel("版本号")
        version.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let versionRow = UI.hstack([
            UI.label("版本号", size: 12, weight: .medium, color: .secondaryLabelColor),
            version,
        ], spacing: 10)
        card.addFullWidth(versionRow)

        let mapping = UI.label("默认 mapping（Release 输出目录）", size: 12, color: .secondaryLabelColor)
        mapping.lineBreakMode = .byTruncatingMiddle
        mapping.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var mappingURL: URL?

        let pickerButton = ActionButton("选择文件或文件夹…", symbol: "folder") { [weak self] in
            guard let window = self?.window else { return }
            let picker = NSOpenPanel()
            picker.canChooseDirectories = true
            picker.canChooseFiles = true
            picker.prompt = "选择"
            picker.beginSheetModal(for: window) { response in
                guard response == .OK, let url = picker.url else { return }
                mappingURL = url
                mapping.stringValue = url.lastPathComponent
                mapping.textColor = .labelColor
                mapping.toolTip = url.path
            }
        }
        let resetButton = ActionButton("使用默认") {
            mappingURL = nil
            mapping.stringValue = "默认 mapping（Release 输出目录）"
            mapping.textColor = .secondaryLabelColor
            mapping.toolTip = nil
        }
        card.addFullWidth(UI.hstack([pickerButton, resetButton, mapping], spacing: 8))

        let upload = ActionButton("上传到 Bugly", symbol: "arrow.up.circle.fill", style: .prominent) { [weak self] in
            let value = version.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                self?.window?.makeFirstResponder(version)
                self?.showAlert("请输入版本号", "版本号不能为空。")
                return
            }
            let arguments = [value] + (mappingURL.map { [$0.path] } ?? [])
            self?.run(.uploadSymbol, arguments)
        }
        card.addArrangedSubview(upload)
        return card
    }

    private func makeAntigravityUpdateCard() -> Card {
        let card = Card()
        card.addFullWidth(UI.cardHeader(
            symbol: "arrow.triangle.2.circlepath", tint: .systemPurple, title: "版本更新",
            detail: "更新到官方最新版并重新应用授权补丁。"
        ))
        let check = ActionButton("检查更新", symbol: "magnifyingglass") { [weak self] in
            self?.runAntigravityUpdate("--check", name: "检查 Antigravity 更新")
        }
        let update = ActionButton("更新并打补丁", symbol: "arrow.down.circle.fill", style: .prominent) { [weak self] in
            self?.runAntigravityUpdate("--update", name: "更新 Antigravity 并打补丁")
        }
        card.addFullWidth(UI.hstack([check, update], spacing: 8))
        card.addFullWidth(UI.note("替换后客户端签名为 ad-hoc，内置自动更新将不可用；后续升级请继续使用本功能。"))
        return card
    }

    private func runAntigravityUpdate(_ argument: String, name: String) {
        let script = scriptsDirectory.appendingPathComponent("Antigravity 更新.command")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            showAlert("无法运行 Antigravity 更新", "请确认脚本存在且可执行。\n\(script.path)")
            return
        }
        let isUpdate = argument == "--update"
        runner.run(script, arguments: [argument], name: name, workingDirectory: scriptsDirectory,
                   needsConfirmation: isUpdate, confirmsLocalization: isUpdate)
    }

    private func makeLocalizationCard() -> Card {
        let card = Card()
        card.addFullWidth(UI.cardHeader(
            symbol: "character.book.closed", tint: .systemTeal, title: "中文补丁",
            detail: "按本机版本下载并安装社区汉化补丁。"
        ))
        let download = ActionButton("下载或更新补丁", symbol: "arrow.down.circle") { [weak self] in
            self?.runLocalization("--download", name: "下载或更新汉化补丁")
        }
        let install = ActionButton("应用到 Antigravity", symbol: "arrow.trianglehead.clockwise") { [weak self] in
            self?.runLocalization("--install", name: "应用 Antigravity 汉化补丁")
        }
        card.addArrangedSubview(UI.hstack([download, install], spacing: 8))
        return card
    }

    private func runLocalization(_ argument: String, name: String) {
        let script = scriptsDirectory.appendingPathComponent("一键汉化.command")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            showAlert("无法运行一键汉化", "请确认脚本存在且可执行。\n\(script.path)")
            return
        }
        let isInstall = argument == "--install"
        runner.run(script, arguments: [argument], name: name, workingDirectory: scriptsDirectory,
                   needsConfirmation: isInstall, confirmsLocalization: isInstall)
    }

    private func makeSettingsLoginCard() -> Card {
        let card = Card()
        card.addFullWidth(UI.cardHeader(symbol: "power", tint: .systemBlue,
                                        title: "启动项", detail: "登录 macOS 时自动在菜单栏启动开发工具箱。"))
        let login = NSButton(checkboxWithTitle: "登录时启动", target: self, action: #selector(toggleLogin))
        loginButton = login
        let status = UI.note("")
        loginStatusLabel = status
        card.addFullWidth(UI.hstack([login, UI.spacer(), status], spacing: 10))
        return card
    }

    private func makeSettingsInfoCard() -> Card {
        let card = Card()
        card.addFullWidth(UI.cardHeader(symbol: "folder.badge.gearshape", tint: .systemGray,
                                        title: "脚本目录与版本", detail: "工具箱直接调用同级目录下的 .command 脚本。"))
        let pathLabel = UI.label(scriptsDirectory.path, size: 12, color: .secondaryLabelColor)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let reveal = ActionButton("在 Finder 中打开", symbol: "folder") { [weak self] in
            guard let dir = self?.scriptsDirectory else { return }
            NSWorkspace.shared.open(dir)
        }
        card.addFullWidth(UI.hstack([pathLabel, UI.spacer(), reveal], spacing: 8))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        card.addFullWidth(UI.note("版本 \(version) · Bundle ID: \(Bundle.main.bundleIdentifier ?? "local.foru.toolbox")"))
        return card
    }

    // MARK: - 设备刷新与运行控制

    private var runCommand: (tool: Tool, arguments: [String])? {
        guard let device = runDevicePicker.selectedDevice else { return nil }
        let release = runBuildPicker.selectedSegment == 1
        return (device.buildTool, (release ? ["--release"] : []) + ["2", device.serial])
    }

    private func updateRunButton() {
        runButton?.isEnabled = !isRefreshingDevices && !runner.isRunning && runCommand != nil
    }

    private func scriptURL(_ tool: Tool) -> URL {
        scriptsDirectory.appendingPathComponent(tool.scriptName).appendingPathExtension("command")
    }

    private func run(_ tool: Tool, _ arguments: [String]) {
        let url = scriptURL(tool)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            showAlert("无法运行 \(tool.scriptName)", "请确认脚本存在且可执行。\n\(url.path)")
            return
        }
        runner.run(url, arguments: arguments, name: tool.displayName(arguments: arguments),
                   workingDirectory: scriptsDirectory,
                   needsConfirmation: arguments == ["--confirm-stdin"])
    }

    private func refreshDevices() {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        refreshButton?.isEnabled = false
        screenshotCaptureButton?.isEnabled = false
        updateRunButton()

        let url = scriptURL(.screenshot)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: [Device]? = Shell.capture(url, ["--list-devices"]).map { data in
                String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .compactMap { Device(fields: $0.split(separator: "\t").map(String.init)) }
            }
            DispatchQueue.main.async {
                self.isRefreshingDevices = false
                self.refreshButton?.isEnabled = true
                self.setDevices(result)
            }
        }
    }

    private func setDevices(_ devices: [Device]?) {
        let list = devices ?? []
        let emptyTitle = devices == nil ? "读取设备失败" : "未发现已授权设备"
        logController.updateDevices(list, emptyTitle: emptyTitle)

        runDevicePicker.reload(list, selected: runDevicePicker.selectedDevice, emptyTitle: emptyTitle)
        updateRunButton()

        screenshotDevicePicker?.reload(list, selected: screenshotDevicePicker?.selectedDevice, emptyTitle: emptyTitle)
        screenshotCaptureButton?.isEnabled = !list.isEmpty
    }

    // MARK: - 登录项与弹窗

    private func updateLoginControls() {
        let status = loginService.status
        loginButton?.state = status == .enabled ? .on : .off
        switch status {
        case .enabled:
            loginButton?.title = "登录时启动"
            loginStatusLabel?.stringValue = "已启用"
            loginStatusLabel?.textColor = .systemGreen
        case .requiresApproval:
            loginButton?.title = "登录时启动（待系统允许）"
            loginStatusLabel?.stringValue = "需要在系统设置中允许"
            loginStatusLabel?.textColor = .systemOrange
        default:
            loginButton?.title = "登录时启动"
            loginStatusLabel?.stringValue = "未启用"
            loginStatusLabel?.textColor = .secondaryLabelColor
        }
    }

    @objc private func toggleLogin() {
        defer { updateLoginControls() }
        do {
            switch loginService.status {
            case .enabled:
                try loginService.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
                return
            default:
                try loginService.register()
            }
            if loginService.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            let failure = error as NSError
            let alert = NSAlert()
            alert.messageText = "macOS 未能更改登录自启"
            alert.informativeText = "可以在系统设置的「登录项与扩展」中检查开发工具箱。\n\n错误：\(failure.domain) \(failure.code)"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "关闭")
            if alert.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    private func showAlert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 自检

    private func runLoginCheck() {
        do {
            if loginService.status != .enabled { try loginService.register() }
            print("登录项状态：\(loginService.status.rawValue)；\(Bundle.main.bundlePath)")
            exit(loginService.status == .enabled ? 0 : 1)
        } catch {
            let failure = error as NSError
            print("登录项注册失败：\(failure.domain) \(failure.code) \(failure.localizedDescription)")
            exit(1)
        }
    }

    private func checkShortcut(_ key: String, keyCode: UInt16) -> Bool {
        guard let window, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
        ) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
    }

    private func runSelfCheck() {
        guard let statusButton = statusItem.button, statusItem.menu == nil,
              statusButton.image != nil, statusButton.action == #selector(showWindow) else { exit(1) }
        statusButton.performClick(nil)
        guard Tool.allCases.map(scriptURL).allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }),
              NSApp.activationPolicy() == .regular,
              window?.isVisible == true,
              screenshotCaptureButton?.isEnabled == false,
              runButton?.isEnabled == false,
              loginButton != nil else { exit(1) }
        guard tabs.numberOfTabViewItems == Page.allCases.count,
              sidebar.numberOfRows == sidebarRows.count else { exit(1) }

        for page in Page.allCases {
            selectPage(page)
            window?.contentView?.layoutSubtreeIfNeeded()
            guard tabs.selectedTabViewItem?.identifier as? Int == page.rawValue,
                  tabs.selectedTabViewItem?.view?.frame.width ?? 0 > 600,
                  runDevicePicker.window === window, runButton?.window === window,
                  let header = runDevicePicker.superview, header.superview === tabs.superview,
                  header.frame.minY >= tabs.frame.maxY else {
                print("侧栏页面布局失败", page, tabs.selectedTabViewItem?.identifier as Any,
                      tabs.frame, tabs.selectedTabViewItem?.view?.frame as Any)
                exit(1)
            }
        }

        selectPage(.build)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let build = tabs.selectedTabViewItem?.view as? NSScrollView,
              let stack = build.documentView?.subviews.first as? NSStackView,
              stack.arrangedSubviews.compactMap({ $0 as? Card }).count == 2,
              stack.arrangedSubviews.compactMap({ $0 as? Card }).allSatisfy({ $0.frame.height > 90 }),
              !runner.isHidden else {
            print("打包页面卡片布局失败", tabs.selectedTabViewItem?.view?.frame as Any)
            exit(1)
        }

        let devices = [
            Device(platform: .android, serial: "A", label: "Android 测试设备"),
            Device(platform: .harmony, serial: "B", label: "鸿蒙 测试设备"),
        ]
        setDevices(devices)
        window?.contentView?.layoutSubtreeIfNeeded()
        runBuildPicker.selectedSegment = 0
        updateRunButton()
        guard screenshotCaptureButton?.isEnabled == true,
              screenshotDevicePicker?.devices.count == 2,
              runDevicePicker.selectedDevice == devices[0],
              let secondFrame = runDevicePicker.buttonFrameForSelfTest(at: 1),
              let secondButton = runDevicePicker.radioButtonForSelfTest(at: 1),
              window?.contentView?.hitTest(NSPoint(x: secondFrame.midX, y: secondFrame.midY)) === secondButton,
              runButton?.isEnabled == true,
              runCommand?.tool == .android,
              runCommand?.arguments == ["2", "A"] else { exit(1) }

        secondButton.performClick(nil)
        guard runDevicePicker.selectedDevice == devices[1] else { exit(1) }

        runDevicePicker.select(devices[1])
        runBuildPicker.selectedSegment = 1
        selectPage(.logs)
        setDevices(Array(devices.reversed()))
        guard runButton?.isEnabled == true,
              runCommand?.tool == .harmony,
              runCommand?.arguments == ["--release", "2", "B"],
              runDevicePicker.selectedDevice == devices[1] else { exit(1) }

        let extraDevices = devices + (0..<4).map { Device(platform: .android, serial: "多设备-\($0)", label: "测试设备 \($0)") }
        setDevices(extraDevices)
        guard runDevicePicker.devices.count == 6,
              runCommand?.arguments.last == "B" else { exit(1) }

        setDevices([devices[0]])
        guard runDevicePicker.selectedDevice == devices[0],
              runButton?.isEnabled == true,
              runCommand?.tool == .android else { exit(1) }

        setDevices([])
        guard runDevicePicker.selectedDevice == nil,
              runButton?.isEnabled == false,
              runCommand == nil else { exit(1) }

        setDevices(devices)
        selectPage(.build)
        guard checkShortcut("w", keyCode: 13), window?.isVisible == false else {
            print("关闭窗口快捷键检查失败")
            exit(1)
        }
        statusButton.performClick(nil)
        guard window?.isVisible == true else { exit(1) }

        // 日志解析与过滤校验
        let sample = LogLine("11-24 10:00:00.123 10234 123 456 E ExampleTag : Request Failed", android: true)
        guard sample.uid == 10234, sample.level == 5, sample.tag == "ExampleTag",
              sample.displayText(compact: true) == "11-24 10:00:00.123 E ExampleTag: Request Failed",
              sample.displayText(compact: false) == sample.raw,
              sample.matches(level: 4, uids: [10234], tag: "ExampleTag", keyword: "request"),
              !sample.matches(level: 6, uids: [10234], tag: "ExampleTag", keyword: ""),
              !sample.matches(level: 0, uids: [10000], tag: "", keyword: ""),
              !sample.matches(level: 0, uids: nil, tag: "Other", keyword: ""),
              !sample.matches(level: 0, uids: nil, tag: "", keyword: "success") else { exit(1) }

        let query = LogQuery(#"package:mine tag:ExampleTag level:warn "Request Failed""#, android: true, configuredPackage: "org.example.android")
        guard query.package == "org.example.android", query.tag == "ExampleTag",
              query.level == 4, query.words == ["Request Failed"], query.error == nil,
              LogQuery("level:unknown", android: true).error != nil,
              LogQuery("level:warn", android: false).level == 4 else { exit(1) }

        let harmonyQuery = LogQuery("package:mine tag:Http_Request level:verbose", android: false, configuredPackage: "org.example.harmony")
        let harmonyLines = [
            "11-24 10:00:00.123 4321 123 D A00001/org.example.harmony/Http_Request: Request started",
            "11-24 10:00:01.123 5678 124 W A00001/org.example.harmony:worker/Http_Request: Request failed",
            "11-24 10:00:02.123 6789 125 E A00001/org.example.harmony.other/Http_Request: Wrong package",
            "11-24 10:00:03.123 4321 123 E A00001/org.example.harmony/Other: Wrong tag",
        ].map { LogLine($0, android: false) }
        let harmonyMatches = harmonyLines.filter {
            $0.matches(level: harmonyQuery.level, uids: nil, tag: harmonyQuery.tag,
                       keyword: "request", processPackage: harmonyQuery.package)
        }
        guard harmonyQuery.package == "org.example.harmony",
              harmonyMatches.map(\.level) == [2, 4],
              harmonyMatches.last?.message == "Request failed",
              harmonyLines[0].displayText(compact: true) == "11-24 10:00:00.123 D Http_Request: Request started",
              LogLine("日志已停止", android: false).displayText(compact: true) == "日志已停止",
              !harmonyLines[0].matches(level: 4, uids: nil, tag: "", keyword: "") else { exit(1) }

        let inbox = LogInbox()
        inbox.append(Data(repeating: 65, count: 300 * 1024))
        let (stored, skipped, _) = inbox.drain()
        guard skipped, stored.count == 256 * 1024 else { exit(1) }

        selectPage(.logs)
        logController.startStream(
            tool: Paths.shell,
            arguments: ["-c", #"printf '11-24 10:00:00.123 123 456 W A00001/org.example.harmony/Test: 模拟设备日志\n'"#],
            device: devices[0]
        )
        logController.selectDeviceForSelfTest(devices[1])
        guard logController.selectedDeviceForSelfTest == devices[1] else { exit(1) }

        let favoritesKey = "savedLogQueries"
        let savedFavorites = UserDefaults.standard.object(forKey: favoritesKey)
        let sampleFavorite = "message:toolbox-test-\(UUID())"
        logController.configureForSelfTest(query: sampleFavorite)
        logController.toggleFavoriteForSelfTest()
        let storedFavorite = logController.favorites.first == sampleFavorite
        logController.configureForSelfTest(query: "")
        logController.selectFavoriteForSelfTest(at: 1)
        let appliedFavorite = logController.currentQueryForSelfTest == sampleFavorite
        logController.configureForSelfTest(query: "")
        UserDefaults.standard.set(savedFavorites, forKey: favoritesKey)
        logController.refreshFavorites()
        guard storedFavorite, appliedFavorite else { exit(1) }

        runner.onSelfTestCheck = { [weak self] in
            self?.window?.contentView?.layoutSubtreeIfNeeded()
            guard let self,
                  let toolboxWindow = self.window as? ToolboxWindow,
                  toolboxWindow.shouldZoomOnDoubleClick(at: NSPoint(x: 300, y: toolboxWindow.frame.height - 24)),
                  !toolboxWindow.shouldZoomOnDoubleClick(at: NSPoint(x: 400, y: 120)),
                  self.runButton.map({ button in
                      let pt = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                      return !toolboxWindow.shouldZoomOnDoubleClick(at: pt)
                  }) ?? false,
                  self.tabs.selectedTabViewItem?.identifier as? Int == Page.logs.rawValue,
                  self.runner.isHidden == true,
                  self.logController.logScrollHeightForSelfTest > 360,
                  self.logController.textView.string.hasSuffix("模拟设备日志\n"),
                  self.logController.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemOrange,
                  !self.logController.isFollowOnForSelfTest,
                  self.runner.outputString.contains("标准输出"),
                  self.runner.outputString.contains("错误输出"),
                  self.runner.outputString.contains("确认收到 CLEAN"),
                  self.runner.outputString.contains("退出码 7"),
                  self.runner.hasErrorsForSelfTest,
                  self.runner.isErrorBannerVisibleForSelfTest,
                  self.runner.isStderrHighlightedForSelfTest,
                  self.runner.formattedErrorReportForAI().contains("退出码：7"),
                  self.runner.formattedErrorReportForAI().contains("错误输出"),
                  ProcessRunner.isLikelyErrorLine("ERROR: Build failed"),
                  !ProcessRunner.isLikelyErrorLine("Build succeeded with 0 errors"),
                  !ProcessRunner.isLikelyErrorLine("0 failed, build succeeded"),
                  !ProcessRunner.isLikelyErrorLine("Handling exception fallback safely") else {
                print("内嵌日志或输出布局失败", self?.runner.isHidden as Any)
                exit(1)
            }
            guard self.logController.focusQueryFieldForSelfTest(),
                  self.checkShortcut("f", keyCode: 3),
                  self.logController.isFindBarVisibleForSelfTest else {
                print("日志查找快捷键检查失败")
                exit(1)
            }
            self.logController.hideFindBarForSelfTest()
            guard self.logController.focusQueryFieldForSelfTest(),
                  let editor = self.logController.queryFieldEditorForSelfTest(),
                  NSApp.target(forAction: #selector(NSText.paste(_:))) as AnyObject? === editor,
                  NSApp.mainMenu?.items.last?.submenu?.items.contains(where: {
                      $0.action == #selector(NSText.paste(_:)) && $0.keyEquivalent == "v"
                          && $0.keyEquivalentModifierMask == .command
                  }) == true else {
                print("日志筛选框粘贴快捷键检查失败")
                exit(1)
            }
            self.logController.clearLogs()
            guard self.logController.textView.string.isEmpty else { exit(1) }
            editor.string = "模拟设备日志"
            self.runner.onSelfTestCheck = { [weak self] in
                guard let self,
                      self.runner.outputString.contains("正常进度"),
                      !self.runner.hasErrorsForSelfTest,
                      !self.runner.isErrorBannerVisibleForSelfTest else {
                    print("成功任务误报错误检查失败")
                    exit(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard self.logController.textView.string.isEmpty else { exit(1) }
                    print("侧栏、日志筛选、清空日志、输出和关闭／查找／粘贴快捷键自检通过")
                    exit(0)
                }
            }
            self.runner.run(
                Paths.shell,
                arguments: ["-c", #"printf '正常进度\n' >&2; exit 0"#],
                name: "成功自检",
                workingDirectory: self.scriptsDirectory,
                needsConfirmation: false
            )
        }

        runner.run(
            Paths.shell,
            arguments: ["-c", #"printf '标准输出\n输入 CLEAN 移到废纸篓\n'; printf '错误输出\n' >&2; read -r token; printf '确认收到 %s\n' "$token"; exit 7"#],
            name: "自检",
            workingDirectory: scriptsDirectory,
            needsConfirmation: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !self.runner.isConfirmationHidden else { exit(1) }
            self.runner.finishConfirmation("CLEAN")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(1) }
    }

    private func runSnapshot(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        showWindow()
        setDevices([
            Device(platform: .android, serial: "emulator-5554", label: "Android Pixel 8 (emulator-5554)"),
            Device(platform: .harmony, serial: "demo-harmony", label: "鸿蒙演示设备"),
        ])
        for page in Page.allCases {
            selectPage(page)
            window?.contentView?.layoutSubtreeIfNeeded()
            guard let target = window?.contentView?.superview ?? window?.contentView,
                  let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { continue }
            target.cacheDisplay(in: target.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("page-\(page.rawValue)-\(page).png"))
            }
        }
        exit(0)
    }
}

private final class ToolboxWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           event.clickCount == 2,
           shouldZoomOnDoubleClick(at: event.locationInWindow) {
            performZoom(nil)
            return
        }
        super.sendEvent(event)
    }

    func shouldZoomOnDoubleClick(at point: NSPoint) -> Bool {
        let titlebarHeight: CGFloat = 52
        guard point.y >= frame.height - titlebarHeight, point.y <= frame.height else {
            return false
        }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            if let button = standardWindowButton(type) {
                let rect = button.convert(button.bounds, to: nil)
                if rect.contains(point) { return false }
            }
        }
        guard let hit = contentView?.hitTest(point) else { return true }
        var current: NSView? = hit
        while let view = current, view !== contentView {
            if let textField = view as? NSTextField, !textField.isEditable, !textField.isSelectable {
                current = view.superview
                continue
            }
            if view is NSControl || view is NSTextView {
                return false
            }
            current = view.superview
        }
        return true
    }
}

private final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        path.fill()
    }
}
