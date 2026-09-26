import AVFoundation
import Foundation

/// Common surface of the internal MIDI sound modules (SC-55, MT-32) used by the UI.
protocol InternalMIDISynthesizer: AnyObject {
    /// Host output gain 0...1, persisted per module.
    var volume: Double { get set }
    func send(_ event: [UInt8], delayMs: Double)
    func reset()
    func stop()
    func setPaused(_ paused: Bool)
    /// Average time from a MIDI event being due to it being heard, excluding the
    /// output device (shared with FM/ADPCM): 2 queued buffers + half a buffer of wait.
    var outputLatency: TimeInterval { get }
}

extension SC55Synthesizer: InternalMIDISynthesizer {}

/// A control + PCM ROM pair identified by content (SHA-1), not by file name.
struct MT32ROMSet {
    let control: Data
    let pcm: Data
    let controlName: String         // Munt short name, e.g. "ctrl_mt32_1_07"
    let controlDescription: String  // e.g. "MT-32 Control v1.07"
    let pcmDescription: String

    /// "MT-32" or "CM-32L" style label for menus.
    var modelName: String {
        controlName.hasPrefix("ctrl_cm32ln") ? "CM-32LN"
            : controlName.hasPrefix("ctrl_cm32l") ? "CM-32L" : "MT-32"
    }
}

/// One Munt mt32emu instance; all core and audio scheduling work is serialized.
final class MT32Synthesizer: InternalMIDISynthesizer {
    static let shared = MT32Synthesizer()
    private let worker = DispatchQueue(label: "MPX68K.MT32", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    // AnalogOutputMode_ACCURATE renders at 48 kHz (X68MT32_SampleRate).
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var generation = 0
    private var running = false
    private var pendingMIDI = SC55MIDIEventQueue()
    // 384 frames = 8 ms, the same period as the SC-55 (512 frames at 64 kHz).
    private let framesPerBuffer: AVAudioFrameCount = 384
    private var audioBuffers: [AVAudioPCMBuffer] = []
    var onFailure: ((String) -> Void)? // Installed and called on the main queue.

    var outputLatency: TimeInterval { 2.5 * Double(framesPerBuffer) / format.sampleRate }

    /// Description of the ROM set currently loaded (main thread).
    private(set) var loadedROMDescription: String?

    var volume: Double {
        get {
            let saved = UserDefaults.standard.object(forKey: "MT32OutputVolume") as? NSNumber
            let value = saved?.doubleValue ?? 1.0
            return value.isFinite ? min(1.0, max(0.0, value)) : 1.0
        }
        set {
            guard newValue.isFinite else { return }
            let value = min(1.0, max(0.0, newValue))
            UserDefaults.standard.set(value, forKey: "MT32OutputVolume")
            worker.async { self.engine.mainMixerNode.outputVolume = Float(value) }
        }
    }

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(volume)
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.worker.async { self?.restartOutputOnWorker(reason: "configuration change") }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.worker.async { self?.restartOutputOnWorker(reason: "interruption ended") }
        }
        #endif
    }

    #if os(iOS)
    private func restartOutputOnWorker(reason: String) {
        guard running else { return }
        do {
            if !engine.isRunning { try engine.start() }
            generation += 1
            player.stop()
            for buffer in audioBuffers { scheduleBuffer(buffer, generation: generation) }
            player.play()
            warningLog("MT-32 output restarted (\(reason))", category: .audio)
        } catch {
            fail("MT-32の音声出力を再開できませんでした: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: - ROM discovery

    private enum Kind { case control, pcm }
    private struct Identified {
        let kind: Kind
        let name: String
        let description: String
    }
    private struct CacheKey: Hashable {
        let path: String
        let size: Int
        let modified: Date?
    }
    private static let cacheLock = NSLock()
    private static var identifyCache: [CacheKey: Identified?] = [:]

    /// Full control ROMs are 32–128 KiB, PCM ROMs 512 KiB or 1 MiB.
    private static let plausibleSizes: Set<Int> = [0x8000, 0x10000, 0x20000, 0x80000, 0x100000]

    private static func identify(_ data: Data) -> Identified? {
        var name = [CChar](repeating: 0, count: 64)
        var description = [CChar](repeating: 0, count: 128)
        let kind = data.withUnsafeBytes { raw -> Int32 in
            X68MT32_IdentifyROM(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                                &name, 64, &description, 128)
        }
        let decode: ([CChar]) -> String = { chars in
            String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        switch kind {
        case Int32(X68MT32_ROM_CONTROL): return Identified(kind: .control, name: decode(name), description: decode(description))
        case Int32(X68MT32_ROM_PCM): return Identified(kind: .pcm, name: decode(name), description: decode(description))
        default: return nil
        }
    }

    /// Genuine MT-32 v1.07 first, other MT-32 firmware next, patched BlueRidge and CM-32L last.
    /// Keep in sync with tests/mt32/test_rom.cpp.
    static func preference(_ controlName: String) -> Int {
        if controlName == "ctrl_mt32_1_07" { return 3 }
        if controlName == "ctrl_mt32_bluer" { return 1 }
        if controlName.hasPrefix("ctrl_mt32_") { return 2 }
        return 0
    }

    /// Scans `folder` (not recursively) for any control/PCM ROM pair that Munt recognizes.
    /// File names do not matter. Results per file are cached by size and modification date.
    static func findROMs(in folder: URL) throws -> MT32ROMSet {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var controls: [(Identified, URL)] = []
        var pcms: [(Identified, URL)] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let size = values.fileSize,
                  plausibleSizes.contains(size) else { continue }
            let key = CacheKey(path: url.path, size: size, modified: values.contentModificationDate)
            cacheLock.lock()
            let cached = identifyCache[key]
            cacheLock.unlock()
            let identified: Identified?
            if let cached {
                identified = cached
            } else {
                identified = (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(identify)
                cacheLock.lock()
                identifyCache[key] = .some(identified)
                cacheLock.unlock()
            }
            guard let identified else { continue }
            if identified.kind == .control { controls.append((identified, url)) } else { pcms.append((identified, url)) }
        }
        let pairs: [((Identified, URL), (Identified, URL))] = controls.flatMap { control in
            pcms.filter { X68MT32_ROMsCompatible(control.0.name, $0.0.name) }.map { (control, $0) }
        }
        guard let best = pairs.max(by: { a, b in
            let pa = preference(a.0.0.name), pb = preference(b.0.0.name)
            return pa != pb ? pa < pb : a.0.0.name < b.0.0.name
        }) else {
            if controls.isEmpty && pcms.isEmpty {
                throw failure("MT-32 / CM-32L の ROM が見つかりません（コントロール ROM と PCM ROM が必要です）。")
            }
            if controls.isEmpty { throw failure("MT-32 のコントロール ROM が見つかりません。") }
            if pcms.isEmpty { throw failure("MT-32 の PCM ROM が見つかりません。") }
            throw failure("コントロール ROM と PCM ROM の組み合わせが合いません（MT-32 には MT-32 用 PCM、CM-32L には CM-32L 用 PCM が必要です）。")
        }
        let control = try Data(contentsOf: best.0.1)
        let pcm = try Data(contentsOf: best.1.1)
        // Re-identify what was actually read, in case a file changed after scanning.
        guard identify(control)?.name == best.0.0.name, identify(pcm)?.name == best.1.0.name else {
            throw failure("MT-32 ROM の読み込み中にファイルが変更されました。")
        }
        return MT32ROMSet(control: control, pcm: pcm, controlName: best.0.0.name,
                          controlDescription: best.0.0.description, pcmDescription: best.1.0.description)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MPX68K.MT32", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Lifecycle

    func start(roms: MT32ROMSet, completion: @escaping (Error?) -> Void) {
        worker.async {
            self.stopOnWorker()
            let loaded = roms.control.withUnsafeBytes { c in
                roms.pcm.withUnsafeBytes { p in
                    X68MT32_Load(c.bindMemory(to: UInt8.self).baseAddress, c.count,
                                 p.bindMemory(to: UInt8.self).baseAddress, p.count)
                }
            }
            do {
                guard loaded else { throw Self.failure("MT-32 ROMの読み込みに失敗しました。") }
                guard Double(X68MT32_SampleRate()) == self.format.sampleRate else {
                    throw Self.failure("MT-32の出力サンプリングレートが想定と異なります。")
                }
                if self.audioBuffers.isEmpty {
                    var buffers: [AVAudioPCMBuffer] = []
                    for _ in 0..<3 {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: self.framesPerBuffer) else {
                            throw Self.failure("MT-32音声バッファを確保できませんでした。")
                        }
                        buffers.append(buffer)
                    }
                    self.audioBuffers = buffers
                }
                try self.engine.start()
                self.running = true
                for buffer in self.audioBuffers { self.scheduleBuffer(buffer, generation: self.generation) }
                guard self.running else { throw Self.failure("MT-32の初期化に失敗しました。") }
                self.player.play()
                let description = "\(roms.controlDescription) + \(roms.pcmDescription)"
                DispatchQueue.main.async {
                    self.loadedROMDescription = description
                    completion(nil)
                }
            } catch {
                self.stopOnWorker()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func stop() { worker.async { self.stopOnWorker() } }

    private func stopOnWorker() {
        generation += 1
        let wasLoaded = running || X68MT32_SampleRate() != 0
        running = false
        player.stop()
        engine.stop()
        pendingMIDI = SC55MIDIEventQueue()
        if wasLoaded {
            X68MT32_Unload()
            DispatchQueue.main.async { self.loadedROMDescription = nil }
        }
    }

    func reset() {
        worker.async {
            guard self.running else { return }
            self.generation += 1
            self.player.stop()
            self.pendingMIDI = SC55MIDIEventQueue()
            guard X68MT32_Reset() else {
                self.fail("MT-32のリセットに失敗しました。")
                return
            }
            for buffer in self.audioBuffers { self.scheduleBuffer(buffer, generation: self.generation) }
            self.player.play()
        }
    }

    func setPaused(_ paused: Bool) {
        worker.async {
            guard self.running else { return }
            if paused { self.player.pause() } else { self.player.play() }
        }
    }

    func send(_ event: [UInt8], delayMs: Double = 0) {
        guard delayMs.isFinite else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, delayMs) / 1000
        worker.async {
            guard self.running else { return }
            guard self.pendingMIDI.enqueue(event, deadline: deadline) else {
                self.fail("MT-32のMIDI入力が処理上限を超えました。音源を再選択してください。")
                return
            }
        }
    }

    private func fail(_ message: String) {
        stopOnWorker()
        DispatchQueue.main.async { self.onFailure?(message) }
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer, generation: Int) {
        guard running, self.generation == generation,
              let channels = buffer.floatChannelData else { return }
        // Munt parses a byte stream, so SysEx split into chunks is reassembled. Its event
        // queue is sized so that one period's input cannot overflow; never resend a chunk.
        pendingMIDI.flush(dueBy: ProcessInfo.processInfo.systemUptime) { chunk in
            if !X68MT32_Send(chunk, chunk.count) {
                warningLog("MT-32 MIDI queue overflow; events dropped", category: .audio)
            }
            return true
        }
        guard X68MT32_Render(channels[0], channels[1], Int(framesPerBuffer)) else {
            fail("MT-32音源の処理が停止しました。ROMセットを確認してください。")
            return
        }
        buffer.frameLength = framesPerBuffer
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.worker.async { self.scheduleBuffer(buffer, generation: generation) }
        }
    }
}
