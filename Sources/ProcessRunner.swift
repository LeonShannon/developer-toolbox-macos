import AppKit

/// 底部执行输出面板与子进程调度器：支持流式输出、停止任务、清空输出与清理确认。
final class ProcessRunner {
    let container = UI.vstack([], spacing: 0)
    private let card = Card(spacing: 10, insets: NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
    private let statusPill = StatusPill()
    private let stopButton = ActionButton("停止", symbol: "stop.fill", style: .destructive)
    private let copyErrorsButton = ActionButton("复制报错", symbol: "ladybug.fill", style: .destructive)
    private let copyOutputButton = ActionButton("复制输出", symbol: "doc.on.doc", style: .icon)
    private let clearButton = ActionButton("清空输出", symbol: "eraser", style: .icon)
    private let errorBanner = ErrorBanner()
    private let outputScroll: NSScrollView
    private let outputView: NSTextView
    private let confirmationRow = UI.hstack([], spacing: 8)
    private let confirmationField = NSTextField()

    private var activeProcess: Process?
    private var confirmationInput: FileHandle?
    private var matchedErrorLines: [String] = []
    private var stderrLines: [String] = []
    private var stderrTextRanges: [NSRange] = []
    private var hasRealOutput = false
    private var copyErrorsGeneration = 0
    private var copyOutputGeneration = 0
    private var lastTaskName = ""
    private var lastCommandLine = ""
    private var lastWorkingDirectory = ""
    private var lastExitCode: Int32?
    private var didFail = false
    var onStateChange: (() -> Void)?
    var onAlert: ((String, String) -> Void)?
    var onSelfTestCheck: (() -> Void)?

    var isRunning: Bool { activeProcess != nil }
    var isHidden: Bool {
        get { container.isHidden }
        set { container.isHidden = newValue }
    }
    var outputString: String { outputView.string }
    var isConfirmationHidden: Bool { confirmationRow.isHidden }
    var hasErrorsForSelfTest: Bool { didFail }
    var isErrorBannerVisibleForSelfTest: Bool { !errorBanner.isHidden }
    var isStderrHighlightedForSelfTest: Bool {
        let ns = outputView.string as NSString
        let range = ns.range(of: "错误输出")
        guard range.location != NSNotFound,
              let storage = outputView.textStorage else { return false }
        return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == .systemRed
    }

    init() {
        let (scroll, text) = UI.monospacedTextView(fontSize: 12)
        self.outputScroll = scroll
        self.outputView = text
        setupUI()
    }

    private func setupUI() {
        container.edgeInsets = NSEdgeInsets(top: 6, left: 24, bottom: 14, right: 24)

        let title = UI.label("执行输出", size: 13, weight: .semibold)
        stopButton.isHidden = true
        stopButton.handler = { [weak self] in self?.terminate() }
        copyErrorsButton.isHidden = true
        copyErrorsButton.toolTip = "复制报错信息（含上下文，可直接粘贴给 AI 修复）"
        copyErrorsButton.handler = { [weak self] in self?.copyErrorsToPasteboard() }
        copyOutputButton.isEnabled = false
        copyOutputButton.handler = { [weak self] in self?.copyAllOutputToPasteboard() }
        clearButton.handler = { [weak self] in self?.clearOutput() }
        let header = UI.hstack([title, statusPill, UI.spacer(), stopButton, copyErrorsButton, copyOutputButton, clearButton], spacing: 8)
        card.addFullWidth(header)

        errorBanner.isHidden = true
        errorBanner.onCopy = { [weak self] in self?.copyErrorsToPasteboard() }
        card.addFullWidth(errorBanner)

        outputView.string = "运行任务后，输出会显示在这里。"
        outputView.textColor = .secondaryLabelColor
        outputScroll.heightAnchor.constraint(equalToConstant: 138).isActive = true
        card.addFullWidth(outputScroll)

        confirmationField.placeholderString = "输入 CLEAN"
        confirmationField.setAccessibilityLabel("清理确认")
        confirmationField.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let warningIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        warningIcon.contentTintColor = .systemOrange
        let confirmButton = ActionButton("确认清理", style: .destructive) { [weak self] in
            guard let self else { return }
            guard self.confirmationField.stringValue == "CLEAN" else {
                self.onAlert?("请输入 CLEAN", "核对输出中的清理目录后再确认。")
                return
            }
            self.finishConfirmation("CLEAN")
        }
        let cancelButton = ActionButton("取消") { [weak self] in
            self?.finishConfirmation("")
        }
        confirmationRow.addArrangedSubview(warningIcon)
        confirmationRow.addArrangedSubview(UI.label("确认将以上目录移至废纸篓：", size: 12, weight: .medium))
        confirmationRow.addArrangedSubview(confirmationField)
        confirmationRow.addArrangedSubview(confirmButton)
        confirmationRow.addArrangedSubview(cancelButton)
        confirmationRow.isHidden = true
        card.addFullWidth(confirmationRow)

        container.addFullWidth(card)
    }

    func run(_ url: URL, arguments: [String], name: String, workingDirectory: URL, needsConfirmation: Bool,
             confirmsLocalization: Bool = false) {
        guard activeProcess == nil else {
            onAlert?("仍有任务在运行", "请等待当前任务结束或先停止它。")
            return
        }
        container.isHidden = false

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let input = needsConfirmation ? Pipe() : nil
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.executableURL = url
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = input ?? FileHandle.nullDevice

        resetErrorState()
        hasRealOutput = true
        copyOutputButton.isEnabled = true
        lastTaskName = name
        lastCommandLine = ([url.path] + arguments).joined(separator: " ")
        lastWorkingDirectory = workingDirectory.path
        outputView.string = ""
        outputView.textColor = .textColor
        statusPill.set(.running, "执行中 · \(name)")
        stopButton.isHidden = confirmsLocalization

        do {
            try process.run()
        } catch {
            didFail = true
            let message = "无法启动：\(error.localizedDescription)"
            matchedErrorLines.append(message)
            appendOutput(message + "\n", isError: true)
            updateErrorIndicators()
            statusPill.set(.failure, "启动失败 · \(name)")
            stopButton.isHidden = true
            onSelfTestCheck?()
            return
        }

        activeProcess = process
        confirmationInput = input?.fileHandleForWriting
        onStateChange?()

        let readGroup = DispatchGroup()
        let startReader: (FileHandle, Bool) -> Void = { [weak self] reader, isErrorStream in
            readGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readGroup.leave() }
                var pending = Data()
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    guard let lastLine = pending.lastIndex(of: 10) else { continue }
                    let text = String(decoding: pending[...lastLine], as: UTF8.self)
                    pending = Data(pending.suffix(from: lastLine + 1))
                    DispatchQueue.main.async {
                        self?.handleOutputChunk(text, isErrorStream: isErrorStream,
                                                needsConfirmation: needsConfirmation, confirmsLocalization: confirmsLocalization)
                    }
                }
                let tail = String(decoding: pending, as: UTF8.self)
                if !tail.isEmpty {
                    DispatchQueue.main.async {
                        self?.handleOutputChunk(tail, isErrorStream: isErrorStream,
                                                needsConfirmation: needsConfirmation, confirmsLocalization: confirmsLocalization)
                    }
                }
            }
        }

        startReader(stdoutPipe.fileHandleForReading, false)
        startReader(stderrPipe.fileHandleForReading, true)

        readGroup.notify(queue: DispatchQueue.global(qos: .userInitiated)) { [weak self] in
            process.waitUntilExit()
            DispatchQueue.main.async {
                guard let self else { return }
                self.finishConfirmation(nil)
                let success = process.terminationReason == .exit && process.terminationStatus == 0
                self.lastExitCode = process.terminationStatus
                self.didFail = !success
                if !success {
                    self.highlightStderrRanges()
                }
                let summary = success ? "\n执行结束。\n" : "\n执行失败，退出码 \(process.terminationStatus)。\n"
                self.appendOutput(summary, color: success ? .systemGreen : .systemRed, isError: !success)
                self.updateErrorIndicators()
                self.statusPill.set(success ? .success : .failure, "\(success ? "已完成" : "执行失败") · \(name)")
                self.stopButton.isHidden = true
                self.activeProcess = nil
                self.onStateChange?()
                self.onSelfTestCheck?()
            }
        }
    }

    func terminate() {
        guard let activeProcess, activeProcess.isRunning else { return }
        statusPill.set(.running, "正在停止…")
        activeProcess.terminate()
    }

    func finishConfirmation(_ response: String?) {
        confirmationRow.isHidden = true
        confirmationField.stringValue = ""
        guard let handle = confirmationInput else { return }
        confirmationInput = nil
        defer { try? handle.close() }
        if let response {
            do {
                try handle.write(contentsOf: Data((response + "\n").utf8))
            } catch {
                appendOutput("无法发送确认：\(error.localizedDescription)\n", color: .systemRed)
            }
        }
    }

    private func handleOutputChunk(_ text: String, isErrorStream: Bool, needsConfirmation: Bool,
                                   confirmsLocalization: Bool) {
        if !hasRealOutput {
            hasRealOutput = true
            copyOutputButton.isEnabled = true
        }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let suffix = index < lines.count - 1 ? "\n" : ""
            if line.isEmpty && suffix.isEmpty { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let isMatchedError = !trimmed.isEmpty && Self.isLikelyErrorLine(trimmed)
            if isMatchedError {
                matchedErrorLines.append(line)
            } else if isErrorStream && !trimmed.isEmpty {
                stderrLines.append(line)
            }
            let range = appendOutput(line + suffix, isError: isMatchedError)
            if isErrorStream && !isMatchedError && !trimmed.isEmpty {
                stderrTextRanges.append(range)
            }
        }
        if confirmsLocalization, !isErrorStream, confirmationInput != nil,
           let prompt = lines.first(where: { $0 == "等待确认安装汉化补丁" || $0 == "等待确认更新客户端" }) {
            let isUpdate = prompt == "等待确认更新客户端"
            let alert = NSAlert()
            alert.alertStyle = .warning
            if isUpdate {
                alert.messageText = "更新 Antigravity 并重新打补丁？"
                alert.informativeText = "将把 /Applications/Antigravity.app 替换为官方最新版，并重新应用授权补丁。补丁会使客户端签名变为 ad-hoc，内置自动更新从此不可用，后续升级请继续使用本功能。旧版本会保留在应用支持目录，便于回滚。请先保存工作，确认后会关闭 Antigravity。"
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "确认更新")
                finishConfirmation(alert.runModal() == .alertSecondButtonReturn ? "确认更新" : nil)
            } else {
                alert.messageText = "安装 Antigravity 汉化补丁？"
                alert.informativeText = "替换 app.asar 会使 Google 原始代码签名校验失败，macOS 可能阻止启动。可用工具箱保存的原版备份或 Google 官方完整安装包恢复。请先保存工作，确认后会关闭并重启 Antigravity。"
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "确认安装")
                finishConfirmation(alert.runModal() == .alertSecondButtonReturn ? "确认安装" : nil)
            }
        } else if needsConfirmation, text.contains("输入 CLEAN 移到废纸篓") {
            confirmationRow.isHidden = false
            confirmationField.window?.makeFirstResponder(confirmationField)
        }
    }

    @discardableResult
    private func appendOutput(_ text: String, color: NSColor? = nil, isError: Bool = false) -> NSRange {
        let storage = outputView.textStorage
        let location = storage?.length ?? (outputView.string as NSString).length
        let length = (text as NSString).length
        let foreground = color ?? (isError ? .systemRed : .textColor)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: isError ? .semibold : .regular),
            .foregroundColor: foreground,
        ]
        if isError {
            attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.11)
        }
        storage?.append(NSAttributedString(string: text, attributes: attributes))
        outputView.scrollRangeToVisible(NSRange(location: location + length, length: 0))
        return NSRange(location: location, length: length)
    }

    private func highlightStderrRanges() {
        guard let storage = outputView.textStorage, !stderrTextRanges.isEmpty else { return }
        let totalLength = storage.length
        let errorAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
            .backgroundColor: NSColor.systemRed.withAlphaComponent(0.11),
        ]
        storage.beginEditing()
        for range in stderrTextRanges where range.location >= 0 && NSMaxRange(range) <= totalLength {
            storage.addAttributes(errorAttributes, range: range)
        }
        storage.endEditing()
    }

    private func clearOutput() {
        outputView.string = ""
        hasRealOutput = false
        copyOutputButton.isEnabled = false
        resetErrorState()
        if activeProcess == nil {
            statusPill.set(.idle, "空闲")
        }
    }

    private func resetErrorState() {
        matchedErrorLines.removeAll()
        stderrLines.removeAll()
        stderrTextRanges.removeAll()
        lastExitCode = nil
        didFail = false
        updateErrorIndicators()
    }

    private func updateErrorIndicators() {
        let showErrorUI = didFail
        copyErrorsButton.isHidden = !showErrorUI
        errorBanner.isHidden = !showErrorUI
        card.borderTint = showErrorUI ? NSColor.systemRed.withAlphaComponent(0.45) : nil
        if showErrorUI {
            let highlightedErrors = reportedErrorLines()
            let exitText = lastExitCode.map { "（退出码 \($0)）" } ?? ""
            let headline = !highlightedErrors.isEmpty
                ? "执行失败\(exitText)，已提取 \(highlightedErrors.count) 行报错，可复制给 AI 修复"
                : "任务执行失败\(exitText)，可复制日志给 AI 排查"
            errorBanner.setText(headline)
        }
    }

    private func reportedErrorLines() -> [String] {
        !matchedErrorLines.isEmpty ? matchedErrorLines : stderrLines
    }

    func formattedErrorReportForAI() -> String {
        var sections: [String] = []
        var meta: [String] = []
        if !lastTaskName.isEmpty { meta.append("任务：\(lastTaskName)") }
        if !lastCommandLine.isEmpty { meta.append("命令：\(lastCommandLine)") }
        if !lastWorkingDirectory.isEmpty { meta.append("目录：\(lastWorkingDirectory)") }
        if let lastExitCode { meta.append("退出码：\(lastExitCode)") }
        if !meta.isEmpty { sections.append(meta.joined(separator: "\n")) }

        let errors = reportedErrorLines()
        if !errors.isEmpty {
            let excerpt = errors.prefix(120).joined(separator: "\n")
            let truncated = errors.count > 120 ? "\n…（共 \(errors.count) 行报错，已截取前 120 行）" : ""
            sections.append("报错摘要：\n```text\n\(excerpt)\(truncated)\n```")
        }

        let allLines = outputView.string
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        let tail = allLines.suffix(60).joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !tail.isEmpty {
            sections.append("完整输出末尾（最近 60 行）：\n```text\n\(tail)\n```")
        }
        return sections.joined(separator: "\n\n")
    }

    private func copyErrorsToPasteboard() {
        let report = formattedErrorReportForAI()
        guard !report.isEmpty else { return }
        writeToPasteboard(report)
        copyErrorsGeneration += 1
        let generation = copyErrorsGeneration
        copyErrorsButton.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copyErrorsGeneration == generation else { return }
            self.copyErrorsButton.title = "复制报错"
        }
        errorBanner.flashCopied()
    }

    private func copyAllOutputToPasteboard() {
        guard hasRealOutput else { return }
        let text = outputView.string.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        writeToPasteboard(text)
        copyOutputGeneration += 1
        let generation = copyOutputGeneration
        copyOutputButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.copyOutputGeneration == generation else { return }
            self.copyOutputButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制输出")
        }
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func isLikelyErrorLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let benign = ["0 errors", "0 error", "0 failed", "no error", "without error", "succeeded"]
        if benign.contains(where: { lower.contains($0) }) {
            return false
        }
        let markers = [
            "error:", "error[", "[error]", "> error:", "fatal:", "fatal error",
            "exception:", "traceback (most recent call last)", "panic:",
            "build failed", "task failed", "execution failed", "command failed",
            "failure:", "segmentation fault", "command not found",
            "❌", "报错：", "报错:", "失败：", "失败:",
        ]
        return markers.contains { lower.contains($0) }
    }
}

/// 检测到报错时在输出面板顶部展示的醒目提示条。
private final class ErrorBanner: NSView {
    private let label = UI.label("", size: 12, weight: .semibold, color: .systemRed)
    private let copyButton = ActionButton("复制给 AI", symbol: "doc.on.doc", style: .destructive)
    private var flashGeneration = 0
    var onCopy: (() -> Void)?
    override var wantsUpdateLayer: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemRed
        label.lineBreakMode = .byTruncatingTail
        copyButton.controlSize = .small
        copyButton.handler = { [weak self] in self?.onCopy?() }

        let row = UI.hstack([icon, label, UI.spacer(), copyButton], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.10).cgColor
        layer.borderColor = NSColor.systemRed.withAlphaComponent(0.32).cgColor
    }

    func setText(_ text: String) {
        label.stringValue = text
    }

    func flashCopied() {
        flashGeneration += 1
        let generation = flashGeneration
        copyButton.title = "已复制 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.copyButton.title = "复制给 AI"
        }
    }
}
