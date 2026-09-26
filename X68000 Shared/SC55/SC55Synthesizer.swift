import AVFoundation
import Foundation

/// Monotonic deadlines and FIFO byte order, including SysEx across UART backpressure.
struct SC55MIDIEventQueue {
    private struct Event {
        let bytes: [UInt8]
        let deadline: TimeInterval
    }
    private var events: [Event] = []
    private var head = 0
    private var byteOffset = 0
    private(set) var pendingBytes = 0

    mutating func enqueue(_ bytes: [UInt8], deadline: TimeInterval) -> Bool {
        guard deadline.isFinite, bytes.count <= 65536 - pendingBytes else { return false }
        guard !bytes.isEmpty else { return true }
        // A delay reduction must not send a later note-off ahead of its note-on.
        let orderedDeadline = max(deadline, events.last?.deadline ?? deadline)
        events.append(Event(bytes: bytes, deadline: orderedDeadline))
        pendingBytes += bytes.count
        return true
    }

    mutating func flush(dueBy now: TimeInterval, send: ([UInt8]) -> Bool) {
        while head < events.count, events[head].deadline <= now {
            let event = events[head]
            let end = min(byteOffset + 1024, event.bytes.count)
            let chunk = Array(event.bytes[byteOffset..<end])
            guard send(chunk) else { break }
            pendingBytes -= chunk.count
            byteOffset = end
            if byteOffset == event.bytes.count {
                head += 1
                byteOffset = 0
            }
        }
        if head == events.count || head >= 256 {
            events.removeFirst(head)
            head = 0
        }
    }

    var nextDeadline: TimeInterval? { head < events.count ? events[head].deadline : nil }

    /// Renders one buffer covering deadlines [start, start + frames / sampleRate) and
    /// delivers every due event at its own position inside it, instead of all at the
    /// buffer start. Late events go first. Returns false if rendering failed.
    mutating func render(bufferStart start: TimeInterval, frames: Int, sampleRate: Double,
                         send: ([UInt8]) -> Bool, render: (_ offset: Int, _ count: Int) -> Bool) -> Bool {
        var offset = 0
        while let deadline = nextDeadline {
            let position = Int(((deadline - start) * sampleRate).rounded())
            guard position < frames else { break }
            if position > offset {
                guard render(offset, position - offset) else { return false }
                offset = position
            }
            let before = pendingBytes
            flush(dueBy: deadline, send: send)
            // Backpressure (SC-55 UART full): retry in the next buffer.
            if pendingBytes == before { break }
        }
        return offset >= frames || render(offset, frames - offset)
    }
}

/// Maps a player buffer to the host time its first frame corresponds to. Completion
/// callbacks arrive with scheduling jitter; buffers are exactly one period apart, so
/// follow the callback times loosely and re-anchor after a gap (start, reset, stall).
struct InternalSynthBufferClock {
    private var expected: TimeInterval?

    mutating func reset() { expected = nil }

    mutating func bufferStart(now: TimeInterval, period: TimeInterval) -> TimeInterval {
        var start = now
        if let expected, abs(now - expected) < period * 3 {
            start = expected + (now - expected) * 0.1
        }
        expected = start + period
        return start
    }
}

/// One Nuked SC-55 instance; all core and audio scheduling work is serialized.
final class SC55Synthesizer {
    static let shared = SC55Synthesizer()
    private let worker = DispatchQueue(label: "MPX68K.SC55", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 64000, channels: 2)!
    private var generation = 0
    private var running = false
    private var pendingMIDI = SC55MIDIEventQueue()
    private var clockGeneration = -1
    private var bufferClock = InternalSynthBufferClock()
    private let framesPerBuffer: AVAudioFrameCount = 512
    private var audioBuffers: [AVAudioPCMBuffer] = []
    var onFailure: ((String) -> Void)? // Installed and called on the main queue.

    /// See InternalMIDISynthesizer.outputLatency (3 buffers of 8 ms).
    var outputLatency: TimeInterval { 2 * Double(framesPerBuffer) / format.sampleRate }

    // Host output gain, independent of MIDI channel volume and firmware resets.
    // Read/write from the main thread; audio changes are serialized with playback.
    var volume: Double {
        get {
            let saved = UserDefaults.standard.object(forKey: "SC55OutputVolume") as? NSNumber
            let value = saved?.doubleValue ?? 1.0
            return value.isFinite ? min(1.0, max(0.0, value)) : 1.0
        }
        set {
            guard newValue.isFinite else { return }
            let value = min(1.0, max(0.0, newValue))
            UserDefaults.standard.set(value, forKey: "SC55OutputVolume")
            worker.async { self.engine.mainMixerNode.outputVolume = Float(value) }
        }
    }

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Float(volume)
        #if os(iOS)
        // iOS stops the engine on an audio configuration change (the audio session being
        // configured or activated after start, a route change) and on interruptions.
        // Restart output so the SC-55 does not go silent while MIDI keeps being sent.
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
            // Buffers queued on the stopped player are gone; start a fresh chain.
            generation += 1
            player.stop()
            for buffer in audioBuffers { scheduleBuffer(buffer, generation: generation) }
            player.play()
            warningLog("SC-55 output restarted (\(reason))", category: .audio)
        } catch {
            fail("SC-55の音声出力を再開できませんでした: \(error.localizedDescription)")
        }
    }
    #endif

    static let requiredROMs: [(String, Set<Int>)] = [
        ("sc55_rom1.bin", [0x8000]),
        ("sc55_rom2.bin", [0x40000, 0x80000]),
        ("sc55_waverom1.bin", [0x100000]),
        ("sc55_waverom2.bin", [0x100000]),
        ("sc55_waverom3.bin", [0x100000])
    ]

    static func readROMs(from folder: URL) throws -> [Data] {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        return try requiredROMs.map { name, sizes in
            let url = folder.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, sizes.contains(size) else {
                throw failure("\(name): ROMサイズが正しくありません（必要: \(sizes.sorted().map(String.init).joined(separator: " / ")) bytes）。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Bound the read even if the file changes after the metadata check.
            let data = try handle.read(upToCount: sizes.max()! + 1) ?? Data()
            guard sizes.contains(data.count), data.contains(where: { $0 != 0 && $0 != 255 }) else {
                throw failure("\(name): 空または無効なROMです。")
            }
            return data
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MPX68K.SC55", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func start(roms: [Data], completion: @escaping (Error?) -> Void) {
        worker.async {
            self.stopOnWorker()
            let loaded = roms[0].withUnsafeBytes { p1 in
                roms[1].withUnsafeBytes { p2 in
                    roms[2].withUnsafeBytes { w1 in
                        roms[3].withUnsafeBytes { w2 in
                            roms[4].withUnsafeBytes { w3 in
                                X68SC55_Load(p1.bindMemory(to: UInt8.self).baseAddress, p1.count,
                                            p2.bindMemory(to: UInt8.self).baseAddress, p2.count,
                                            w1.bindMemory(to: UInt8.self).baseAddress,
                                            w2.bindMemory(to: UInt8.self).baseAddress,
                                            w3.bindMemory(to: UInt8.self).baseAddress, w1.count)
                            }
                        }
                    }
                }
            }
            do {
                guard loaded else { throw Self.failure("SC-55 ROMの読み込みに失敗しました。") }
                try self.warmUpFirmware()
                if self.audioBuffers.isEmpty {
                    var buffers: [AVAudioPCMBuffer] = []
                    for _ in 0..<3 {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: self.framesPerBuffer) else {
                            throw Self.failure("SC-55音声バッファを確保できませんでした。")
                        }
                        buffers.append(buffer)
                    }
                    self.audioBuffers = buffers
                }
                try self.engine.start()
                self.running = true
                for buffer in self.audioBuffers { self.scheduleBuffer(buffer, generation: self.generation) }
                guard self.running else { throw Self.failure("SC-55の初期化に失敗しました。") }
                self.player.play()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.stopOnWorker()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func stop() { worker.async { self.stopOnWorker() } }

    private func stopOnWorker() {
        generation += 1
        running = false
        player.stop()
        engine.stop()
        pendingMIDI = SC55MIDIEventQueue()
    }

    func reset() {
        worker.async {
            guard self.running else { return }
            self.generation += 1
            self.player.stop()
            self.pendingMIDI = SC55MIDIEventQueue()
            X68SC55_Reset()
            do { try self.warmUpFirmware() }
            catch {
                self.fail(error.localizedDescription)
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
        // Capture arrival before dispatch: worker congestion must not shift the deadline.
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, delayMs) / 1000
        worker.async {
            guard self.running else { return }
            guard self.pendingMIDI.enqueue(event, deadline: deadline) else {
                self.fail("SC-55のMIDI入力が処理上限を超えました。音源を再選択してください。")
                return
            }
        }
    }

    private func fail(_ message: String) {
        stopOnWorker()
        DispatchQueue.main.async { self.onFailure?(message) }
    }

    private func warmUpFirmware() throws {
        // SC-55 v1.21 ignores MIDI during its cold-start initialization. Advance four
        // emulated seconds silently before reporting ready (also after a system reset).
        var left = [Float](repeating: 0, count: 1024)
        var right = left
        for _ in 0..<250 {
            guard X68SC55_Render(&left, &right, 1024) else {
                throw Self.failure("SC-55の起動に失敗しました。ROMセットを確認してください。")
            }
        }
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer, generation: Int) {
        guard running, self.generation == generation,
              let channels = buffer.floatChannelData else { return }
        if clockGeneration != generation {
            // A new buffer chain (start, reset, restart): re-anchor the buffer clock.
            clockGeneration = generation
            bufferClock.reset()
        }
        // Deliver MIDI at its deadline within the buffer, independently of SpriteKit frames.
        let frames = Int(framesPerBuffer)
        let start = bufferClock.bufferStart(now: ProcessInfo.processInfo.systemUptime,
                                            period: Double(frames) / format.sampleRate)
        let rendered = pendingMIDI.render(bufferStart: start, frames: frames, sampleRate: format.sampleRate,
                                          send: { chunk in X68SC55_Send(chunk, chunk.count) },
                                          render: { offset, count in
            X68SC55_Render(channels[0] + offset, channels[1] + offset, count)
        })
        guard rendered else {
            fail("SC-55音源の処理が停止しました。ROMセットを確認してください。")
            return
        }
        buffer.frameLength = framesPerBuffer
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.worker.async { self.scheduleBuffer(buffer, generation: generation) }
        }
    }
}
