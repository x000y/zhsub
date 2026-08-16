// zhsub-app — 实时字幕引擎 v2 [local-build]
// Apple SFSpeechRecognizer 流式语音识别(en-US) + 本地 Hy-MT2 翻译(python 助手 zhsub-mt.py)
// 输出 NDJSON: {"t":"P|F|Z","ms":N,"text":"...","zh":"...","cached":bool}
// 用法: zhsub-app --pid <pid> [--lang zh-cn|zh-tw|ja-jp|ko-kr] [--file xxx.wav] [--audiotee <path>]
import Foundation
import Speech
import AVFoundation

// ---------- 工具 ----------
func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}
func emit(_ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let s = String(data: data, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}
func errlog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// ---------- 翻译桥接(子进程 zhsub-mt.py → Hy-MT2) ----------
final class Translator {
    private let langNames: [String: String] = [
        "zh-cn": "Simplified Chinese", "zh-tw": "Traditional Chinese",
        "ja-jp": "Japanese", "ko-kr": "Korean",
    ]
    private var stdinPipe: Pipe?
    private var pending: [(Int, String)] = []
    private let lock = NSLock()
    private var alive = true

    init(_ lang: String) {
        let langName = langNames[lang] ?? "Simplified Chinese"
        let home = NSHomeDirectory()
        let python = home + "/zh-sub-engine/.venv/bin/python"
        let script = home + "/zh-sub-engine/zhsub-mt.py"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script, langName]
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        do { try p.run() } catch {
            errlog("[zhsub] 翻译助手启动失败: \(error)")
            return
        }
        stdinPipe = inPipe
        // 读取翻译结果
        let fh = outPipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            var buf = Data()
            while self?.alive == true {
                let d = fh.availableData
                if d.isEmpty {
                    if buf.isEmpty { break }
                } else {
                    buf.append(d)
                }
                while let nl = buf.firstIndex(of: 0x0A) {
                    let lineData = buf[..<nl]
                    buf.removeSubrange(...nl)
                    let line = String(data: lineData, encoding: .utf8) ?? ""
                    self?.handleLine(line)
                }
            }
        }
    }
    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zh = obj["zh"] as? String else { return }
        lock.lock()
        let item = pending.isEmpty ? (0, "") : pending.removeFirst()
        lock.unlock()
        emit(["t": "Z", "ms": item.0, "text": item.1, "zh": zh, "cached": false])
    }
    func enqueue(ms: Int, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lock.lock()
        pending.append((ms, clean))
        lock.unlock()
        guard let inPipe = stdinPipe else { return }
        if let data = (clean + "\n").data(using: .utf8) {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }
    func shutdown() {
        alive = false
        try? stdinPipe?.fileHandleForWriting.close()
    }
}

// ---------- 识别器 (Apple SFSpeechRecognizer) ----------
final class RecognizerDriver {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let translator: Translator
    private var ms: Int = 0
    private var lastPartial = ""
    private var lastPartialMs = -9999
    private var lastChangeMs = 0
    private var lastFinalized = ""

    init(lang: String) {
        translator = Translator(lang)
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
    }
    func start() -> Bool {
        guard let recognizer, recognizer.isAvailable else {
            errlog("[zhsub] SFSpeechRecognizer 不可用")
            return false
        }
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        errlog("[zhsub] 请求语音识别授权…")
        SFSpeechRecognizer.requestAuthorization { status in
            errlog("[zhsub] 授权状态: \(status.rawValue)")
            ok = (status == .authorized)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        guard ok else {
            errlog("[zhsub] 语音识别未授权: 请在 系统设置→隐私与安全性→语音识别 中给 World Monitor 授权")
            return false
        }
        errlog("[zhsub] 开始识别任务…")
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                let ms = self.ms
                if result.isFinal {
                    self.emitFinal(text, ms)
                } else if text != self.lastPartial && ms - self.lastPartialMs >= 400 {
                    self.lastPartial = text
                    self.lastPartialMs = ms
                    self.lastChangeMs = ms
                    emit(["t": "P", "ms": ms, "text": text])
                } else if text == self.lastPartial && !text.isEmpty && ms - self.lastChangeMs >= 1500 && text != self.lastFinalized {
                    // 部分结果稳定1.5s → 视为定稿(直播端点判定不可靠的兜底)
                    self.lastFinalized = text
                    self.emitFinal(text, ms)
                    self.lastChangeMs = ms
                }
            }
            if let error {
                errlog("[zhsub] 识别错误: \(error.localizedDescription)")
            }
        }
        return true
    }
    private func emitFinal(_ text: String, _ ms: Int) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        emit(["t": "F", "ms": ms, "text": clean])
        translator.enqueue(ms: ms, text: clean)
    }
    func append(_ buf: AVAudioPCMBuffer) {
        request.append(buf)
        ms += Int(Double(buf.frameLength) / 16000.0 * 1000.0)
    }
    func finish() {
        request.endAudio()
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        emit(["t": "E", "ms": ms])
        translator.shutdown()
    }
}

// ---------- 主流程 ----------
func feedFile(_ path: String, into driver: RecognizerDriver) {
    let url = URL(fileURLWithPath: path)
    let file = try? AVAudioFile(forReading: url)
    guard let file else { errlog("[zhsub] 无法读取音频: \(path)"); return }
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    while let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600) {
        try? file.read(into: buf)
        if buf.frameLength == 0 { break }
        driver.append(buf)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Double(buf.frameLength) / 16000.0))
    }
    driver.finish()
}

func feedAudiotee(pid: String, audioteePath: String, into driver: RecognizerDriver) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: audioteePath)
    proc.arguments = ["--sample-rate", "16000", "--include-processes", pid]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do { try proc.run() } catch { errlog("[zhsub] 启动 audiotee 失败: \(error)"); return }
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let fh = pipe.fileHandleForReading
    var chunk = Data()
    while true {
        let d = fh.readData(ofLength: 3200)
        if d.isEmpty { break }
        chunk.append(d)
        while chunk.count >= 3200 {
            let samples = chunk.prefix(3200).withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
                let ints = raw.bindMemory(to: Int16.self)
                return (0..<1600).map { Float(ints[$0]) / 32768.0 }
            }
            if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600) {
                buf.frameLength = 1600
                for i in 0..<1600 { buf.floatChannelData![0][i] = samples[i] }
                driver.append(buf)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            }
            chunk.removeFirst(3200)
        }
    }
    driver.finish()
}

let pid = arg("--pid") ?? ""
let lang = arg("--lang") ?? "zh-cn"
let filePath = arg("--file")
let audioteePath = arg("--audiotee") ??
    NSString(string: NSHomeDirectory()).appendingPathComponent("livecaption/bin/audiotee")

let driver = RecognizerDriver(lang: lang)
guard driver.start() else { exit(1) }
if let filePath {
    feedFile(filePath, into: driver)
} else if !pid.isEmpty {
    feedAudiotee(pid: pid, audioteePath: audioteePath, into: driver)
} else {
    errlog("[zhsub] 需要 --pid 或 --file")
    exit(1)
}
