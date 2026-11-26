import AppKit

/// 设备日志页面的控制器：管理设备选择、logcat/hilog 进程、筛选语法、收藏与日志渲染。
final class LogController: NSObject, NSSearchFieldDelegate {
    private let favoritesKey = "savedLogQueries"
    private let pageView = UI.vstack([], spacing: 12)
    private let devicePicker = DevicePicker(allowsEmptySelection: true, maxWidth: 380)
    private let queryField = NSSearchField()
    private let favoriteButton = ActionButton("收藏当前筛选", symbol: "star", style: .icon)
    private let favoritesPicker = NSPopUpButton()
    private let statusPill = StatusPill()
    private let packageStatus = UI.note("")
    private let compactToggle = NSButton(checkboxWithTitle: "简洁显示", target: nil, action: nil)
    private let followToggle = NSButton(checkboxWithTitle: "自动滚动", target: nil, action: nil)
    private let clearButton = ActionButton("清空", symbol: "trash")
    private let findButton = ActionButton("查找", symbol: "magnifyingglass")
    private let stopButton = ActionButton("停止", symbol: "stop.fill", style: .destructive)
    private let logScroll: NSScrollView
    let textView: NSTextView

    private var devices: [Device] = []
    private var currentDevice: Device?
    private var process: Process?
    private var timer: Timer?
    private var lastQuery = ""
    private var onRefreshDevices: (() -> Void)?

    // 日志缓冲状态（仅在主线程访问）
    private var inbox: LogInbox?
    private var history: [LogLine] = []
    private var partial = Data()
    private var discardPartialLine = false

    var view: NSView { pageView }

    private var queryText: String {
        queryField.currentEditor()?.string ?? queryField.stringValue
    }

    var favorites: [String] {
        UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
    }

    init(onRefreshDevices: @escaping () -> Void) {
        self.onRefreshDevices = onRefreshDevices
        let (scroll, text) = UI.monospacedTextView(fontSize: 12)
        text.usesFindBar = true
        self.logScroll = scroll
        self.textView = text
        super.init()
        setupUI()
    }

    private func setupUI() {
        pageView.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 16, right: 24)

        let title = UI.label(Page.logs.title, size: 24, weight: .bold)
        let subtitle = UI.note(Page.logs.subtitle)
        let headerLabels = UI.vstack([title, subtitle], spacing: 3)
        let refresh = ActionButton("刷新设备", symbol: "arrow.clockwise", style: .icon) { [weak self] in
            self?.onRefreshDevices?()
        }
        devicePicker.onChange = { [weak self] device in
            guard let self else { return }
            guard let device else {
                self.stop()
                return
            }
            if self.currentDevice?.identifies(device) == true, self.process?.isRunning == true { return }
            self.start(device: device)
        }
        let topRow = UI.hstack([headerLabels, UI.spacer(), devicePicker, refresh], spacing: 8)
        topRow.alignment = .centerY
        topRow.setContentHuggingPriority(.required, for: .vertical)
        pageView.addFullWidth(topRow)

        // 工具栏卡片：筛选 + 收藏 + 状态与控制
        let toolbarCard = Card(spacing: 10, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        queryField.placeholderString = "package:mine tag:ExampleTag level:warn 关键词"
        queryField.toolTip = "package:mine 代表配置中的应用包名。可组合 package:、tag:、level:、message: 和关键词，带空格的词组用双引号。"
        queryField.setAccessibilityLabel("日志筛选")
        queryField.delegate = self
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        favoriteButton.handler = { [weak self] in self?.toggleFavorite() }

        favoritesPicker.target = self
        favoritesPicker.action = #selector(selectFavorite(_:))
        favoritesPicker.widthAnchor.constraint(equalToConstant: 112).isActive = true
        refreshFavorites()

        let filterRow = UI.hstack([queryField, favoriteButton, favoritesPicker], spacing: 8)
        toolbarCard.addFullWidth(filterRow)

        compactToggle.toolTip = "仅显示时间、等级、Tag 和正文"
        followToggle.state = .off
        clearButton.toolTip = "清空工具箱中的日志，继续接收新日志"
        clearButton.handler = { [weak self] in self?.clearLogs() }
        findButton.handler = { [weak self] in self?.showFindBar() }
        stopButton.isEnabled = false
        stopButton.handler = { [weak self] in self?.stopStreaming() }

        let controlsRow = UI.hstack([
            statusPill,
            UI.spacer(),
            compactToggle,
            followToggle,
            findButton,
            clearButton,
            stopButton,
        ], spacing: 10)
        toolbarCard.addFullWidth(controlsRow)

        packageStatus.isHidden = true
        packageStatus.textColor = .systemOrange
        toolbarCard.addFullWidth(packageStatus)
        toolbarCard.setContentHuggingPriority(.required, for: .vertical)

        pageView.addFullWidth(toolbarCard)

        // 日志正文卡片容器
        let logCard = Card(spacing: 0, insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        logScroll.setContentHuggingPriority(.init(1), for: .vertical)
        logCard.setContentHuggingPriority(.init(1), for: .vertical)
        logCard.addFullWidth(logScroll)
        logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        pageView.addFullWidth(logCard)

        textView.string = "请在右上角选择一台设备以开始实时采集日志。"
        textView.textColor = .secondaryLabelColor
    }

    // MARK: - 设备列表与筛选收藏

    func updateDevices(_ newDevices: [Device], emptyTitle: String) {
        devices = newDevices
        var displayDevices = newDevices
        if let current = currentDevice, !displayDevices.contains(where: { $0.identifies(current) }) {
            displayDevices.insert(current, at: 0)
        }
        devicePicker.reload(displayDevices, selected: currentDevice, emptyTitle: emptyTitle)
    }

    func refreshFavorites() {
        favoritesPicker.removeAllItems()
        favoritesPicker.addItem(withTitle: "筛选收藏")
        for query in favorites {
            let item = NSMenuItem(title: query, action: nil, keyEquivalent: "")
            item.representedObject = query
            favoritesPicker.menu?.addItem(item)
        }
        favoritesPicker.isEnabled = !favorites.isEmpty
        updateFavoriteButton()
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSSearchField) === queryField {
            updateFavoriteButton()
        }
    }

    private func updateFavoriteButton() {
        let current = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = favorites.contains(current)
        favoriteButton.image = NSImage(systemSymbolName: saved ? "star.fill" : "star",
                                       accessibilityDescription: saved ? "取消收藏当前筛选" : "收藏当前筛选")
        favoriteButton.contentTintColor = saved ? .systemYellow : .secondaryLabelColor
        favoriteButton.isEnabled = !current.isEmpty
        favoriteButton.toolTip = saved ? "取消收藏当前筛选" : "收藏当前筛选"
        favoriteButton.setAccessibilityLabel(favoriteButton.toolTip)
    }

    @objc private func selectFavorite(_ sender: NSPopUpButton) {
        guard let query = sender.selectedItem?.representedObject as? String else { return }
        pageView.window?.endEditing(for: nil)
        queryField.stringValue = query
        sender.selectItem(at: 0)
        updateFavoriteButton()
    }

    private func toggleFavorite() {
        let query = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        var list = favorites
        if let index = list.firstIndex(of: query) {
            list.remove(at: index)
        } else {
            list.insert(query, at: 0)
        }
        UserDefaults.standard.set(list, forKey: favoritesKey)
        refreshFavorites()
    }

    // MARK: - 采集控制

    func start(device: Device) {
        let tool = device.isAndroid ? Paths.adb : Paths.hdc
        let arguments = device.isAndroid
            ? ["-s", device.serial, "logcat", "-v", "threadtime", "-v", "uid"]
            : ["-t", device.serial, "hilog"]
        startStream(tool: tool, arguments: arguments, device: device)
    }

    func startStream(tool: URL, arguments: [String], device: Device?) {
        stop()
        currentDevice = device
        devicePicker.select(device)
        if !lastQuery.isEmpty && queryField.stringValue.isEmpty {
            queryField.stringValue = lastQuery
        }
        updateFavoriteButton()

        textView.string = ""
        textView.textColor = .textColor
        packageStatus.isHidden = true
        statusPill.set(.running, "正在读取 · \(device?.label ?? "日志")")
        stopButton.isEnabled = true

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = tool
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            textView.string = error.localizedDescription
            statusPill.set(.failure, "启动失败")
            stopButton.isEnabled = false
            return
        }

        self.process = proc
        let logInbox = LogInbox()
        self.inbox = logInbox
        history.removeAll()
        partial = Data()
        discardPartialLine = false

        DispatchQueue.global(qos: .userInitiated).async {
            let reader = pipe.fileHandleForReading
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                logInbox.append(chunk)
            }
            proc.waitUntilExit()
            logInbox.finish(proc.terminationStatus)
        }

        let isAndroid = device?.isAndroid ?? false
        var packageUIDs: [String: Set<Int>]?
        if let androidSerial = (isAndroid ? device?.serial : nil) {
            DispatchQueue.global(qos: .utility).async {
                let listing = Shell.capture(tool, ["-s", androidSerial, "shell", "pm", "list", "packages", "-U"])
                let resolved = listing.map(Shell.packageUIDs) ?? [:]
                DispatchQueue.main.async { packageUIDs = resolved }
            }
        }

        let historyLimit = 8_000
        let retainedHistory = 6_000
        var lastFilters: String?
        var parsed = LogQuery("", android: isAndroid)
        var lastUIDs: Set<Int>?
        var didFinish = false
        var wasFollowing = false
        var wasCompact = false
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let pollTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.inbox === logInbox else { return }
            let (chunk, skipped, exitCode) = logInbox.drain()
            if skipped || self.discardPartialLine {
                if let end = chunk.firstIndex(of: 10) {
                    self.partial = Data(chunk.suffix(from: end + 1))
                    self.discardPartialLine = false
                } else {
                    self.partial = Data()
                    self.discardPartialLine = true
                }
            } else {
                self.partial.append(chunk)
            }

            let complete: Data
            if exitCode != nil {
                complete = self.partial
                self.partial = Data()
            } else if let end = self.partial.lastIndex(of: 10) {
                complete = Data(self.partial[...end])
                self.partial = Data(self.partial.suffix(from: end + 1))
            } else {
                complete = Data()
                if self.partial.count > 256 * 1024 { self.partial = Data() }
            }

            var newLines: [LogLine] = []
            if skipped { newLines.append(LogLine("日志量过大，已跳过部分较早输出。", android: false)) }
            for line in String(decoding: complete, as: UTF8.self).split(separator: "\n").suffix(3_000) {
                newLines.append(LogLine(String(line.prefix(2_048)), android: isAndroid))
            }
            self.history.append(contentsOf: newLines)
            let trimmed = self.history.count > historyLimit
            if trimmed { self.history.removeFirst(self.history.count - retainedHistory) }

            let filterState = self.queryText
            let queryChanged = filterState != lastFilters
            if queryChanged {
                parsed = LogQuery(filterState, android: isAndroid)
                self.updateFavoriteButton()
            }

            let uids = packageUIDs?[parsed.package]
            if let error = parsed.error {
                self.packageStatus.stringValue = error
                self.packageStatus.isHidden = false
            } else if isAndroid && !parsed.package.isEmpty && uids == nil {
                self.packageStatus.stringValue = packageUIDs == nil ? "正在读取设备包名…"
                    : (packageUIDs?.isEmpty == true ? "无法读取设备包名。" : "设备上未找到这个包名。")
                self.packageStatus.isHidden = false
            } else {
                self.packageStatus.isHidden = true
            }

            let compact = self.compactToggle.state == .on
            let rebuild = trimmed || queryChanged || uids != lastUIDs || compact != wasCompact
            wasCompact = compact
            if rebuild {
                lastFilters = filterState
                lastUIDs = uids
            }

            let matched = (rebuild ? self.history : newLines).lazy.filter {
                $0.matches(parsed, android: isAndroid, uids: uids)
            }
            let following = self.followToggle.state == .on
            if let storage = self.textView.textStorage {
                if rebuild || !newLines.isEmpty {
                    let output = NSMutableAttributedString()
                    for line in matched {
                        output.append(NSAttributedString(string: line.displayText(compact: compact) + "\n", attributes: [
                            .font: font, .foregroundColor: line.color,
                        ]))
                    }
                    if rebuild || output.length > 0 {
                        let clip = self.logScroll.contentView
                        let position = clip.bounds.origin
                        storage.beginEditing()
                        if rebuild { storage.setAttributedString(output) }
                        else { storage.append(output) }
                        storage.endEditing()
                        if following {
                            self.textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
                        } else if clip.bounds.origin != position {
                            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: position, size: clip.bounds.size)).origin)
                            self.logScroll.reflectScrolledClipView(clip)
                        }
                    }
                }
                if following && !wasFollowing {
                    self.textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
                }
            }
            wasFollowing = following

            if let exitCode, !didFinish {
                didFinish = true
                let stoppedByUser = self.statusPill.text.hasPrefix("正在停止") || exitCode == 0
                self.statusPill.set(stoppedByUser ? .idle : .failure,
                                    stoppedByUser ? "采集已停止" : "采集结束（退出码 \(exitCode)）")
                self.stopButton.isEnabled = false
                self.process = nil
            }
        }
        timer = pollTimer
        RunLoop.main.add(pollTimer, forMode: .common)
    }

    func stopStreaming() {
        guard let process, process.isRunning else { return }
        statusPill.set(.running, "正在停止")
        process.terminate()
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        lastQuery = queryText
        timer?.invalidate()
        timer = nil
        process = nil
        inbox = nil
        currentDevice = nil
        stopButton.isEnabled = false
        statusPill.set(.idle, "空闲")
    }

    func clearLogs() {
        if let inbox {
            let (pending, _, _) = inbox.drain()
            if let lastByte = pending.last {
                discardPartialLine = lastByte != 10
            } else if !partial.isEmpty {
                discardPartialLine = true
            }
        }
        partial = Data()
        history.removeAll()
        textView.string = ""
    }

    func showFindBar() {
        pageView.window?.makeFirstResponder(textView)
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(action)
    }

    // MARK: - 测试辅助（仅供 --check 使用）

    func configureForSelfTest(query: String? = nil) {
        if let query { queryField.stringValue = query }
        updateFavoriteButton()
    }

    var currentQueryForSelfTest: String { queryText }
    var logScrollHeightForSelfTest: CGFloat { logScroll.frame.height }
    var isFindBarVisibleForSelfTest: Bool { logScroll.isFindBarVisible }
    func hideFindBarForSelfTest() { logScroll.isFindBarVisible = false }
    func focusQueryFieldForSelfTest() -> Bool { pageView.window?.makeFirstResponder(queryField) == true }
    func queryFieldEditorForSelfTest() -> NSText? { queryField.currentEditor() }
    func selectFavoriteForSelfTest(at index: Int) {
        favoritesPicker.selectItem(at: index)
        selectFavorite(favoritesPicker)
    }
    func toggleFavoriteForSelfTest() { toggleFavorite() }
    var isFollowOnForSelfTest: Bool { followToggle.state == .on }
    var selectedDeviceForSelfTest: Device? { devicePicker.selectedDevice }
    func selectDeviceForSelfTest(_ device: Device) {
        devicePicker.select(device)
    }
}
