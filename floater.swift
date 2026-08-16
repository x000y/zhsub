// zhsub-floater v4 — 流式双语悬浮字幕窗 + 设置面板(模型管理/下载/渠道) [local-build]
import AppKit
import Foundation

let args = CommandLine.arguments
func arg(_ n: String) -> String? {
    if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }
    return nil
}
func hasFlag(_ n: String) -> Bool {
    return args.contains(n)
}
let lang = arg("--lang") ?? "zh-cn"

let PY = NSHomeDirectory() + "/zh-sub-engine/.venv/bin/python"
let DL = NSHomeDirectory() + "/zh-sub-engine/zhsub-dl.py"
let ENG = NSHomeDirectory() + "/zh-sub-engine/zhsub.py"

func logUI(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let d = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: "/tmp/zhsub-ui.log") {
            fh.seekToEndOfFile()
            fh.write(d)
            try? fh.close()
        } else {
            try? line.write(toFile: "/tmp/zhsub-ui.log", atomically: true, encoding: .utf8)
        }
    }
}

// ---------------- 工具: 跑命令拿输出 ----------------
func runOutput(_ args: [String], timeout: TimeInterval = 15) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: PY)
    p.arguments = [DL] + args
    let out = Pipe(); let err = Pipe()
    p.standardOutput = out; p.standardError = err
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    let d = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: d, encoding: .utf8)
}

// ---------------- 标签/拖动 (v3 方案) ----------------
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class DragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

// ---------------- 设置面板 ----------------
final class SettingsPanel: NSWindow {
    // 模型行缓存: key -> (状态标签, 进度条, 下载按钮)
    var rows: [String: (NSTextField, NSProgressIndicator, NSButton)] = [:]
    var statusLabel: NSTextField!
    var channelPopup: NSPopUpButton!
    var proxyField: NSTextField!
    var delayField: NSTextField!
    var cacheField: NSTextField!
    var gapField: NSTextField!
    var contentBox: NSView!
    weak var owner: Floater?
    var didLoadConfig = false

    init(owner: Floater) {
        self.owner = owner
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "AI 字幕 · 设置"
        level = .floating
        isReleasedWhenClosed = false
        backgroundColor = NSColor.windowBackgroundColor
        buildUI()
        refreshStatus()
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    // ---------- UI 构建 (紧凑单屏, 无滚动) ----------
    func buildUI() {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
        contentBox = box
        let doc = NSView(frame: box.bounds)
        doc.wantsLayer = true
        var y: CGFloat = 500

        func title(_ s: String) {
            let lb = NSTextField(labelWithString: s)
            lb.font = .boldSystemFont(ofSize: 13)
            lb.frame = NSRect(x: 14, y: y - 16, width: 440, height: 18)
            doc.addSubview(lb)
            y -= 22
        }
        func hint(_ s: String) {
            let lb = NSTextField(labelWithString: s)
            lb.font = .systemFont(ofSize: 10.5)
            lb.textColor = .secondaryLabelColor
            lb.frame = NSRect(x: 14, y: y - 14, width: 440, height: 14)
            doc.addSubview(lb)
            y -= 18
        }

        // === 字幕显示 ===
        title("字幕显示")
        delayField = NSTextField(labelWithString: "滚轮=缩放字号  Option+滚轮=缓冲延迟 (当前 \(owner?.delayMs ?? 0)ms)")
        delayField.font = .systemFont(ofSize: 11)
        delayField.frame = NSRect(x: 14, y: y - 15, width: 440, height: 16)
        doc.addSubview(delayField)
        y -= 22

        // 翻译缓存上限
        let cacheLb = NSTextField(labelWithString: "翻译缓存上限:")
        cacheLb.font = .systemFont(ofSize: 11)
        cacheLb.frame = NSRect(x: 14, y: y - 16, width: 110, height: 16)
        doc.addSubview(cacheLb)
        cacheField = NSTextField(frame: NSRect(x: 124, y: y - 22, width: 60, height: 22))
        cacheField.font = .systemFont(ofSize: 11)
        cacheField.placeholderString = "512"
        doc.addSubview(cacheField)
        let cacheUnit = NSTextField(labelWithString: "条")
        cacheUnit.font = .systemFont(ofSize: 10)
        cacheUnit.textColor = .secondaryLabelColor
        cacheUnit.frame = NSRect(x: 186, y: y - 15, width: 18, height: 14)
        doc.addSubview(cacheUnit)
        // 字幕更新间隔
        let gapLb = NSTextField(labelWithString: "字幕更新间隔:")
        gapLb.font = .systemFont(ofSize: 11)
        gapLb.frame = NSRect(x: 210, y: y - 16, width: 100, height: 16)
        doc.addSubview(gapLb)
        gapField = NSTextField(frame: NSRect(x: 310, y: y - 22, width: 56, height: 22))
        gapField.font = .systemFont(ofSize: 11)
        gapField.placeholderString = "1200"
        doc.addSubview(gapField)
        let gapUnit = NSTextField(labelWithString: "毫秒(400-5000)")
        gapUnit.font = .systemFont(ofSize: 9.5)
        gapUnit.textColor = .tertiaryLabelColor
        gapUnit.frame = NSRect(x: 368, y: y - 15, width: 100, height: 14)
        doc.addSubview(gapUnit)
        let cacheHint = NSTextField(labelWithString: "越小字幕越跟嘴(跳动多), 越大越平稳; 保存后重启引擎生效")
        cacheHint.font = .systemFont(ofSize: 9.5)
        cacheHint.textColor = .tertiaryLabelColor
        cacheHint.frame = NSRect(x: 14, y: y - 30, width: 440, height: 14)
        doc.addSubview(cacheHint)
        y -= 40

        // === ASR 识别模型 ===
        title("识别模型 (ASR)")
        let asrModels = ["en-0626", "multi-zh-hans", "multi-8lang", "multilingual-2025"]
        for key in asrModels {
            y = buildModelRow(doc, y: y, key: key)
            y -= 5
        }
        y -= 4

        // === 翻译模型 ===
        title("翻译模型")
        y = buildModelRow(doc, y: y, key: "Hy-MT2-1.8B-8bit")
        y -= 5
        y = buildModelRow(doc, y: y, key: "Hy-MT2-1.8B-4bit")
        y -= 5

        // === 下载设置 ===
        title("下载设置")
        let chLb = NSTextField(labelWithString: "渠道:")
        chLb.font = .systemFont(ofSize: 11.5)
        chLb.frame = NSRect(x: 14, y: y - 16, width: 56, height: 16)
        doc.addSubview(chLb)
        channelPopup = NSPopUpButton(frame: NSRect(x: 72, y: y - 22, width: 210, height: 24))
        channelPopup.addItems(withTitles: ["hf-mirror (国内镜像)", "hf-official (官方,需代理)", "modelscope (阿里,免代理)", "custom (自定义)"])
        channelPopup.target = self
        channelPopup.action = #selector(onChannelChanged)
        doc.addSubview(channelPopup)
        y -= 30

        let prLb = NSTextField(labelWithString: "代理:")
        prLb.font = .systemFont(ofSize: 11.5)
        prLb.frame = NSRect(x: 14, y: y - 16, width: 56, height: 16)
        doc.addSubview(prLb)
        proxyField = NSTextField(frame: NSRect(x: 72, y: y - 22, width: 210, height: 22))
        proxyField.placeholderString = "留空=直连, 如 http://127.0.0.1:1088"
        proxyField.font = .systemFont(ofSize: 11)
        doc.addSubview(proxyField)
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(onSaveSettings))
        saveBtn.bezelStyle = .rounded
        saveBtn.frame = NSRect(x: 300, y: y - 24, width: 60, height: 24)
        doc.addSubview(saveBtn)
        let restartBtn = NSButton(title: "重启引擎", target: self, action: #selector(onRestart))
        restartBtn.bezelStyle = .rounded
        restartBtn.frame = NSRect(x: 372, y: y - 24, width: 92, height: 24)
        doc.addSubview(restartBtn)
        y -= 32

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .systemGreen
        statusLabel.frame = NSRect(x: 14, y: y - 14, width: 452, height: 14)
        doc.addSubview(statusLabel)
        y -= 22

        // GitHub 链接 + 作者 (带 Octocat 小猫图标)
        let ghBtn = NSButton(title: "易", target: self, action: #selector(openGitHub))
        ghBtn.bezelStyle = .inline
        ghBtn.font = .systemFont(ofSize: 11)
        ghBtn.frame = NSRect(x: 14, y: y - 20, width: 100, height: 20)
        ghBtn.toolTip = "https://github.com/x000y/zhsub"
        if let ghImg = NSImage(contentsOfFile: NSHomeDirectory() + "/zh-sub-engine/assets/github-mark.png") {
            ghImg.size = NSSize(width: 16, height: 16)
            ghBtn.image = ghImg
            ghBtn.imagePosition = .imageLeading
            ghBtn.imageScaling = .scaleProportionallyDown
        }
        ghBtn.target = self
        ghBtn.action = #selector(openGitHub)
        doc.addSubview(ghBtn)
        let ghUrl = NSTextField(labelWithString: "github.com/x000y/zhsub")
        ghUrl.font = .systemFont(ofSize: 10)
        ghUrl.textColor = .tertiaryLabelColor
        ghUrl.frame = NSRect(x: 120, y: y - 17, width: 200, height: 14)
        doc.addSubview(ghUrl)
        let credit = NSTextField(labelWithString: "DeepSeek Harness v4 Flash 作品")
        credit.font = .systemFont(ofSize: 10)
        credit.textColor = .tertiaryLabelColor
        credit.alignment = .right
        credit.frame = NSRect(x: 300, y: y - 17, width: 166, height: 14)
        doc.addSubview(credit)

        box.addSubview(doc)
        contentView = box
        setContentSize(NSSize(width: 480, height: 520))
        center()
    }

    @objc func openGitHub() {
        if let url = URL(string: "https://github.com/x000y/zhsub") {
            NSWorkspace.shared.open(url)
        }
    }

    // 一行模型: 名字 + 状态 + 进度条 + 按钮(下载/使用) — 紧凑版
    func buildModelRow(_ doc: NSView, y: CGFloat, key: String) -> CGFloat {
        let nameLb = NSTextField(labelWithString: key)
        nameLb.font = .systemFont(ofSize: 11.5, weight: .medium)
        nameLb.frame = NSRect(x: 14, y: y - 16, width: 200, height: 16)
        doc.addSubview(nameLb)

        let stLb = NSTextField(labelWithString: "…")
        stLb.font = .systemFont(ofSize: 10.5)
        stLb.textColor = .secondaryLabelColor
        stLb.frame = NSRect(x: 218, y: y - 16, width: 100, height: 16)
        doc.addSubview(stLb)

        let bar = NSProgressIndicator(frame: NSRect(x: 14, y: y - 34, width: 230, height: 8))
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 100; bar.doubleValue = 0
        bar.isHidden = true
        doc.addSubview(bar)

        let btn = NSButton(title: "…", target: self, action: #selector(onModelButton(_:)))
        btn.bezelStyle = .rounded
        btn.tag = 0
        btn.font = .systemFont(ofSize: 11)
        btn.frame = NSRect(x: 320, y: y - 22, width: 146, height: 22)
        doc.addSubview(btn)

        rows[key] = (stLb, bar, btn)
        return y - 40
    }

    // ---------- 数据刷新 ----------
    func refreshStatus() {
        guard let s = runOutput(["status", "--json"]) else { return }
        guard let data = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cfg = o["config"] as? [String: Any],
              let models = o["models"] as? [[String: Any]] else { return }
        // 渠道/代理/缓存回填(仅首次加载配置)
        if !didLoadConfig {
            didLoadConfig = true
            let ch = cfg["channel"] as? String ?? "hf-mirror"
            let idx = ["hf-mirror", "hf-official", "modelscope", "custom"].firstIndex(of: ch) ?? 0
            channelPopup.selectItem(at: idx)
            proxyField.stringValue = cfg["proxy"] as? String ?? ""
            cacheField.stringValue = "\(cfg["cache_size"] as? Int ?? 512)"
            gapField.stringValue = "\(cfg["sub_gap"] as? Int ?? 1200)"
        }
        for m in models {
            guard let key = m["key"] as? String, let tup = rows[key] else { continue }
            let (stLb, bar, btn) = tup
            let state = m["state"] as? String ?? "missing"
            let active = m["active"] as? Bool ?? false
            let size = m["size_mb"] as? Int ?? 0
            let onMS = m["on_modelscope"] as? Bool ?? false
            let kind = m["kind"] as? String ?? "asr"
            switch state {
            case "builtin":
                stLb.stringValue = "已内置 \(size)MB"
                btn.title = active ? "使用中 ✓" : (kind == "asr" ? "切换" : "—")
                btn.isEnabled = (kind == "asr" && !active)
            case "ready":
                stLb.stringValue = "已下载 \(size)MB"
                btn.title = active ? "使用中 ✓" : "切换"
                btn.isEnabled = !active
            case "partial":
                stLb.stringValue = "不完整 \(size)MB"
                btn.title = "续传"
                btn.isEnabled = true
            default:
                stLb.stringValue = "未下载 \(size)MB"
                btn.title = "下载" + (onMS ? " (阿里直连)" : "")
                btn.isEnabled = true
            }
            if active { stLb.textColor = .systemGreen } else { stLb.textColor = .secondaryLabelColor }
            bar.isHidden = true
        }
    }

    // ---------- 下载 ----------
    func startDownload(_ key: String) {
        guard let tup = rows[key] else { return }
        let (_, bar, btn) = tup
        btn.isEnabled = false
        btn.title = "下载中…"
        bar.doubleValue = 0
        bar.isHidden = false
        statusLabel.stringValue = "正在下载 \(key) …"
        statusLabel.textColor = .systemOrange
        // 后台进程 + 读 NDJSON 进度
        DispatchQueue.global().async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: PY)
            p.arguments = [DL, "download", "--model", key]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.standardError
            do { try p.run() } catch { return }
            let fh = out.fileHandleForReading
            var buf = Data()
            while true {
                let d = fh.availableData
                if d.isEmpty { break }
                buf.append(d)
                while let nl = buf.firstIndex(of: 0x0A) {
                    let lineData = buf[..<nl]; buf.removeSubrange(...nl)
                    if let s = String(data: lineData, encoding: .utf8) {
                        self?.onDownloadLine(s, key: key)
                    }
                }
            }
            p.waitUntilExit()
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = (p.terminationStatus == 0) ? "✓ \(key) 下载完成" : "✗ \(key) 下载失败"
                self?.statusLabel.textColor = (p.terminationStatus == 0) ? .systemGreen : .systemRed
                self?.refreshStatus()
            }
        }
    }

    func onDownloadLine(_ s: String, key: String) {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["t"] as? String, t == "DL" else { return }
        let pct = o["pct"] as? Double ?? 0
        let msg = o["msg"] as? String ?? ""
        DispatchQueue.main.async { [weak self] in
            if let tup = self?.rows[key] {
                let (stLb, bar, _) = tup
                bar.doubleValue = pct
                if pct >= 0 {
                    stLb.stringValue = "\(Int(pct))% \(msg)"
                }
            }
        }
    }

    // ---------- 动作 ----------
    @objc func onModelButton(_ sender: NSButton) {
        guard let key = rows.first(where: { $0.value.2 === sender })?.key else { return }
        let title = sender.title
        if title.contains("下载") || title == "续传" {
            startDownload(key)
        } else if title == "切换" {
            switchTo(key)
        }
    }

    func switchTo(_ key: String) {
        let kind = (key.hasPrefix("Hy-MT2")) ? "--mt" : "--asr"
        let s = runOutput(["set", kind, key]) ?? ""
        guard s.contains("✓") else {
            statusLabel.stringValue = "✗ 切换失败: \(s)"
            statusLabel.textColor = .systemRed
            return
        }
        statusLabel.stringValue = "✓ 已切换: \(key) → 重启引擎生效"
        statusLabel.textColor = .systemGreen
        refreshStatus()
    }

    @objc func onSaveSettings() {
        var a: [String] = ["set"]
        let chMap = ["hf-mirror", "hf-official", "modelscope", "custom"]
        let idx = channelPopup.indexOfSelectedItem
        if idx >= 0 { a += ["--channel", chMap[idx]] }
        a += ["--proxy", proxyField.stringValue]
        let cs = Int(cacheField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        if cs > 0 { a += ["--cache-size", "\(cs)"] }
        let gp = Int(gapField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        if gp > 0 { a += ["--sub-gap", "\(gp)"] }
        _ = runOutput(a)
        statusLabel.stringValue = "✓ 设置已保存 (缓存改后需重启引擎生效)"
        statusLabel.textColor = .systemGreen
    }

    @objc func onChannelChanged() {
        let chMap = ["hf-mirror", "hf-official", "modelscope", "custom"]
        let idx = channelPopup.indexOfSelectedItem
        if idx == 3 {
            statusLabel.stringValue = "自定义渠道: 请在下个版本填写 custom_url (目前用默认)"
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = "渠道: \(chMap[idx])"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc func onRestart() {
        statusLabel.stringValue = "正在重启引擎…"
        statusLabel.textColor = .systemOrange
        owner?.restartEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.statusLabel.stringValue = "✓ 引擎已重启"
            self?.statusLabel.textColor = .systemGreen
        }
    }

    func showPanel() {
        logUI("showPanel 调用")
        refreshStatus()
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        logUI("showPanel 完成, isVisible=\(isVisible)")
    }
}

// ---------------- 主悬浮窗 ----------------
final class Floater: NSWindow, NSWindowDelegate {
    let zhLabel: NSTextField
    let enLabel: NSTextField
    var fontSize: CGFloat = 20
    var enFontSize: CGFloat = 13
    var enText = ""
    var zhText = ""
    var delayMs: Int
    var engineProc: Process?
    var settingsBtn: NSButton!
    var settingsPanel: SettingsPanel!
    var barView: NSView!   // 字幕容器: 一条统一底色, 齿轮与文字都在其上

    struct SubEntry { let at: Date; let zh: String; let en: String }
    var entries: [SubEntry] = []

    init() {
        delayMs = Int(arg("--delay") ?? "0") ?? 0
        zhLabel = PassthroughLabel(wrappingLabelWithString: "…")
        enLabel = PassthroughLabel(wrappingLabelWithString: "")
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 130),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        delegate = self

        // 文字标签: 无自身背景(透明), 底色由 barView 统一提供
        for (lb, sz, bold) in [(zhLabel, fontSize, true), (enLabel, enFontSize, false)] as [(NSTextField, CGFloat, Bool)] {
            lb.font = .systemFont(ofSize: sz, weight: bold ? .semibold : .regular)
            lb.textColor = .white
            lb.alignment = .center
            lb.maximumNumberOfLines = 0
            lb.lineBreakMode = .byWordWrapping
            lb.drawsBackground = false
        }
        enLabel.maximumNumberOfLines = 2

        let host = DragView()
        host.wantsLayer = true

        // 字幕容器: 一条圆角黑底, 齿轮与文字都在其内 → 齿轮天然与条同色
        barView = NSView()
        barView.wantsLayer = true
        barView.layer?.cornerRadius = 9
        barView.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.6).cgColor
        barView.layer?.masksToBounds = true
        barView.addSubview(zhLabel)
        barView.addSubview(enLabel)

        // 设置齿轮: 无边框按钮(彻底无背景色) + 模板图浅色着色, 印在字幕条内
        settingsBtn = NSButton(title: "", target: self, action: #selector(openSettings))
        settingsBtn.isBordered = false            // 关键: 去掉系统按钮背景(白色)
        settingsBtn.frame = NSRect(x: 0, y: 0, width: 44, height: 38)
        settingsBtn.toolTip = "设置: 模型管理 / 下载 / 渠道"
        if let img = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "设置") {
            img.isTemplate = true
            settingsBtn.image = img
            settingsBtn.imagePosition = .imageOnly
            settingsBtn.imageScaling = .scaleProportionallyUpOrDown
            settingsBtn.contentTintColor = NSColor(white: 0.85, alpha: 1.0)
        }
        barView.addSubview(settingsBtn)

        host.addSubview(barView)
        contentView = host
        logUI("init: 设置按钮已创建")

        if let screen = NSScreen.main {
            let f = screen.frame
            setFrameOrigin(NSPoint(x: f.midX - 380, y: f.minY + 80))
        }
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        settingsPanel = SettingsPanel(owner: self)
        if hasFlag("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.settingsPanel.showPanel()
            }
        }
        startEngine()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    @objc func openSettings() {
        logUI("openSettings 被点击")
        settingsPanel.showPanel()
    }

    func stopEngine() {
        engineProc?.terminate()
        engineProc = nil
    }

    func startEngine() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: PY)
        p.arguments = [ENG, "--live", "--pid", "0", "--lang", lang]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.standardError
        do { try p.run() } catch { zhLabel.stringValue = "引擎启动失败: \(error)"; return }
        engineProc = p
        let fh = out.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            var buf = Data()
            while true {
                let d = fh.availableData
                if d.isEmpty { break }
                buf.append(d)
                while let nl = buf.firstIndex(of: 0x0A) {
                    let lineData = buf[..<nl]; buf.removeSubrange(...nl)
                    if let s = String(data: lineData, encoding: .utf8) { self?.onLine(s) }
                }
            }
        }
    }

    func restartEngine() {
        stopEngine()
        // 等旧进程退出
        Thread.sleep(forTimeInterval: 0.8)
        enText = ""; zhText = ""
        DispatchQueue.main.async { self.startEngine() }
    }

    func onLine(_ s: String) {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["t"] as? String else { return }
        let text = (o["text"] as? String) ?? ""
        let zh = (o["zh"] as? String) ?? ""
        if t == "P" || t == "F" { enText = text }
        if t == "Z" && !zh.isEmpty { zhText = zh; enText = text }
        entries.append(SubEntry(at: Date(), zh: zhText, en: enText))
        if entries.count > 600 { entries.removeFirst(entries.count - 600) }
    }

    func tick() {
        // 引擎看护: 进程意外退出则自动重启
        if let p = engineProc, !p.isRunning {
            enText = ""; zhText = ""
            startEngine()
        }
        let cutoff = Date().addingTimeInterval(-Double(delayMs) / 1000.0)
        var shown: SubEntry? = nil
        while let e = entries.first, e.at <= cutoff { shown = e; entries.removeFirst() }
        if let s = shown { zhText = s.zh; enText = s.en }

        zhLabel.stringValue = zhText.isEmpty ? "…" : zhText
        let trimmedEn = enText.count > 100 ? "…" + String(enText.suffix(100)) : enText
        enLabel.stringValue = trimmedEn
        zhLabel.font = .systemFont(ofSize: fontSize, weight: .semibold)
        enLabel.font = .systemFont(ofSize: enFontSize, weight: .regular)
        layout()
    }

    func layout() {
        let maxW: CGFloat = 860
        let pad: CGFloat = 12       // 容器左右内边距(文字区)
        let gearSize: CGFloat = 18  // 齿轮固定尺寸(不随缩放放大)
        let gearGap: CGFloat = 6    // 齿轮与文字间距
        func size(_ s: String, _ f: NSFont) -> NSSize {
            (s as NSString).boundingRect(with: NSSize(width: maxW - 100, height: 400),
                options: [.usesLineFragmentOrigin], attributes: [.font: f]).size
        }
        let zhFont = zhLabel.font ?? NSFont.systemFont(ofSize: fontSize)
        let enFont = enLabel.font ?? NSFont.systemFont(ofSize: enFontSize)
        let zhS = size(zhLabel.stringValue, zhFont)
        let enS = size(enLabel.stringValue, enFont)
        let enLineH = enFont.ascender + abs(enFont.descender) + enFont.leading
        let enH = enText.isEmpty ? 0 : min(enS.height + 4, enLineH * 2 + 4)
        let zhH = zhS.height + 4
        let barH = zhH + enH + 8

        // 齿轮固定 18x18; 垂直居中于字幕条, 左=上=下 三边距相等
        let margin = max(2, (barH - gearSize) / 2)
        let gearW = gearSize + margin + gearGap   // 文字起点 = 齿轮左缘 + 左边距 + 齿轮 + 间距
        let textW = max(zhS.width, enS.width, 150)
        let w = min(maxW, textW + gearW + pad)
        let h = barH + 8           // 窗口 = 容器 + 上下小余量
        let origin = frame.origin
        setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: h), display: true)

        barView.frame = NSRect(x: 0, y: 4, width: w, height: barH)
        // 齿轮: 固定大小, 左/上/下边距均 = margin
        settingsBtn.frame = NSRect(x: margin, y: margin, width: gearSize, height: gearSize)
        // 文字从齿轮右侧开始, 在剩余区域内居中
        let txtX = gearW
        let txtW = w - txtX - pad
        enLabel.frame = NSRect(x: txtX, y: 4, width: txtW, height: enH)
        zhLabel.frame = NSRect(x: txtX, y: 4 + enH, width: txtW, height: zhH)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            delayMs = max(0, delayMs + (event.scrollingDeltaY > 0 ? 200 : -200))
        } else {
            fontSize = max(12, min(44, fontSize + (event.scrollingDeltaY > 0 ? 2 : -2)))
            enFontSize = max(10, min(22, enFontSize + (event.scrollingDeltaY > 0 ? 1 : -1)))
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === self {
            // 主窗口关闭时结束
            settingsPanel.close()
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let f = Floater()
app.run()
