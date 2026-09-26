//
//  MIDIController.swift
//  Xcode11
//
//  Created by GOROman on 2020/04/06.
//  Copyright © 2020 GOROman. All rights reserved.
//

import Foundation
import CoreMIDI
#if os(macOS)
import AppKit
#endif

/// A UInt8 array, usually 3 bytes long
public typealias MidiEvent = [UInt8]

extension MIDIPacketList {
    init(midiEvents: [MidiEvent]) {
        
        let timestamp = MIDITimeStamp(0)
        let totalBytesInAllEvents = midiEvents.reduce(0) { total, event in
            return total + event.count
        }
        
        // Without this, we'd run out of space for the last few MidiEvents
        let listSize = MemoryLayout<MIDIPacketList>.size + totalBytesInAllEvents
        
        // CoreMIDI supports up to 65536 bytes, but in practical tests it seems
        // certain devices accept much less than that at a time. Unless you're
        // turning on / off ALL notes at once, 256 bytes should be plenty.
        assert(totalBytesInAllEvents <= 256,
               "The packet list was too long! Split your data into multiple lists.")
        
        // Allocate space for a certain number of bytes
        let byteBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: listSize)
        
        // Use that space for our MIDIPacketList
        self = byteBuffer.withMemoryRebound(to: MIDIPacketList.self, capacity: 1) { packetList -> MIDIPacketList in
            var packet = MIDIPacketListInit(packetList)
            midiEvents.forEach { event in
                packet = MIDIPacketListAdd(packetList, listSize, packet, timestamp, event.count, event)
            }
            
            return packetList.pointee
        }
        
        byteBuffer.deallocate() // release the manually managed memory
    }
}


class MIDIController {
    /// Internal sound modules that MIDI output can be routed to instead of CoreMIDI.
    enum InternalSynth: String, CaseIterable {
        case sc55
        case mt32

        var displayName: String { self == .sc55 ? "SC-55" : "MT-32" }
    }

    private(set) var activeInternalSynth: InternalSynth?
    var usesInternalSC55: Bool { activeInternalSynth == .sc55 }
    var usesInternalMT32: Bool { activeInternalSynth == .mt32 }

    /// The running internal module, if MIDI is routed to one.
    var activeSynthesizer: InternalMIDISynthesizer? {
        switch activeInternalSynth {
        case .sc55: return SC55Synthesizer.shared
        case .mt32: return MT32Synthesizer.shared
        case nil: return nil
        }
    }

    private var configurationGeneration = 0

    /// ROM data read for one of the internal modules.
    private enum LoadedROMs {
        case sc55([Data])
        case mt32(MT32ROMSet)

        var kind: InternalSynth {
            if case .sc55 = self { return .sc55 }
            return .mt32
        }
    }

    // macOS: user-chosen ROM folders are remembered per module.
    private func bookmarkKey(_ kind: InternalSynth) -> String {
        kind == .sc55 ? "SC55ROMFolderBookmark" : "MT32ROMFolderBookmark"
    }
    private func bookmarkScopedKey(_ kind: InternalSynth) -> String {
        kind == .sc55 ? "SC55ROMFolderBookmarkIsScoped" : "MT32ROMFolderBookmarkIsScoped"
    }
    private func enabledKey(_ kind: InternalSynth) -> String {
        kind == .sc55 ? "SC55InternalEnabled" : "MT32InternalEnabled"
    }

    private static func readROMs(_ kind: InternalSynth, from folder: URL) throws -> LoadedROMs {
        switch kind {
        case .sc55: return .sc55(try SC55Synthesizer.readROMs(from: folder))
        case .mt32: return .mt32(try MT32Synthesizer.findROMs(in: folder))
        }
    }

    func configureSC55(folder: URL, completion: @escaping (Error?) -> Void) {
        configureInternalSynth(.sc55, folder: folder, completion: completion)
    }

    func configureMT32(folder: URL, completion: @escaping (Error?) -> Void) {
        configureInternalSynth(.mt32, folder: folder, completion: completion)
    }

    /// Loads the module's ROMs from a user-chosen folder, starts it and remembers the folder.
    func configureInternalSynth(_ kind: InternalSynth, folder: URL, completion: @escaping (Error?) -> Void) {
        do {
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            let roms = try Self.readROMs(kind, from: folder)
            let bookmark: Data
            let scoped: Bool
            do {
                bookmark = try folder.bookmarkData(options: .x68ReadOnlySecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
                scoped = true
            } catch {
                // Non-sandboxed development builds may not have the app-scope entitlement.
                // An ordinary bookmark remembers the selection without granting any access.
                bookmark = try folder.bookmarkData(options: [.minimalBookmark],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
                scoped = false
            }
            startInternalSynth(roms: roms) { [weak self] error in
                guard let self else { return }
                for other in InternalSynth.allCases {
                    UserDefaults.standard.set(error == nil && other == kind, forKey: self.enabledKey(other))
                }
                if error == nil {
                    UserDefaults.standard.set(bookmark, forKey: self.bookmarkKey(kind))
                    UserDefaults.standard.set(scoped, forKey: self.bookmarkScopedKey(kind))
                    infoLog("Internal \(kind.displayName) enabled", category: .audio)
                }
                completion(error)
            }
        } catch { completion(error) }
    }

    /// Starts the internal module with loaded ROMs and routes MIDI to it on success.
    /// Only one module runs at a time. `completion` is not called if another
    /// configuration started in the meantime.
    private func startInternalSynth(roms: LoadedROMs, completion: @escaping (Error?) -> Void) {
        configurationGeneration += 1
        let generation = configurationGeneration
        let kind = roms.kind
        let finish: (Error?) -> Void = { [weak self] error in
            guard let self, self.configurationGeneration == generation else { return }
            self.clearPendingMIDI()
            if error == nil && self.activeInternalSynth == nil {
                // Silence the previous (external) destination before changing the route.
                for channel in UInt8(0)..<16 {
                    self.sendEventImmediate([0xB0 | channel, 120, 0])
                }
            }
            self.activeInternalSynth = error == nil ? kind : nil
            completion(error)
        }
        switch roms {
        case .sc55(let data):
            MT32Synthesizer.shared.stop()
            SC55Synthesizer.shared.start(roms: data, completion: finish)
        case .mt32(let set):
            SC55Synthesizer.shared.stop()
            MT32Synthesizer.shared.start(roms: set, completion: finish)
        }
    }

    /// Plays a short C major chord on the active internal module (menu "test sound").
    func playInternalTestChord() {
        guard let kind = activeInternalSynth, let synth = activeSynthesizer else { return }
        // SC-55: part 1 = MIDI channel 1. MT-32: melodic parts start at MIDI channel 2.
        let status: UInt8 = kind == .sc55 ? 0x90 : 0x91
        let notes: [UInt8] = [48, 60, 64, 67]
        for note in notes { synth.send([status, note, 127], delayMs: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for note in notes { synth.send([status & 0xEF, note, 0], delayMs: 0) }
        }
    }

    #if os(iOS)
    // MARK: - iOS: internal module ROMs in Documents/MPX68K
    //
    // On iOS the ROMs live next to IPLROM.DAT in the app's Documents/MPX68K folder
    // instead of a user-chosen folder. They are optional: without them (or if they
    // fail to load) MIDI simply goes to external CoreMIDI destinations, silently.

    /// What the user chose in the MIDI menu.
    enum IOSMIDIOutput: String {
        /// Not chosen yet: SC-55 if its ROMs are present, else MT-32, else external.
        case automatic
        case sc55
        case mt32
        case external
    }

    private static let iOSMIDIOutputKey = "ios_midi_output"
    private static let legacyIOSPrefersSC55Key = "ios_sc55_preferred"

    var iOSMIDIOutput: IOSMIDIOutput {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.iOSMIDIOutputKey),
               let value = IOSMIDIOutput(rawValue: raw) { return value }
            // Before MT-32 support this was a Bool (default true = SC-55 when present).
            if let legacy = UserDefaults.standard.object(forKey: Self.legacyIOSPrefersSC55Key) as? Bool, !legacy {
                return .external
            }
            return .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.iOSMIDIOutputKey) }
    }

    static var romLibraryFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MPX68K", isDirectory: true)
    }

    /// All five SC-55 ROM files exist in Documents/MPX68K (sizes are checked when loading).
    static var hasSC55ROMsInLibrary: Bool {
        guard let folder = romLibraryFolder else { return false }
        return SC55Synthesizer.requiredROMs.allSatisfy { name, _ in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
    }

    /// A compatible MT-32/CM-32L control + PCM ROM pair exists in Documents/MPX68K.
    /// Files are identified by content; results are cached per file.
    static var hasMT32ROMsInLibrary: Bool {
        guard let folder = romLibraryFolder else { return false }
        return (try? MT32Synthesizer.findROMs(in: folder)) != nil
    }

    static func hasROMsInLibrary(for kind: InternalSynth) -> Bool {
        kind == .sc55 ? hasSC55ROMsInLibrary : hasMT32ROMsInLibrary
    }

    /// Applies `iOSMIDIOutput`: starts the chosen internal module if its ROMs load,
    /// otherwise uses external MIDI. Never shows an error: a missing or broken ROM set
    /// only logs and falls back. `completion(true)` means the requested internal module
    /// (or, for `.automatic`, any internal module) is now active. Call on the main queue.
    func applyIOSMIDIOutput(completion: ((Bool) -> Void)? = nil) {
        let choice = iOSMIDIOutput
        let candidates: [InternalSynth]
        switch choice {
        case .external: candidates = []
        case .sc55: candidates = [.sc55]
        case .mt32: candidates = [.mt32]
        case .automatic: candidates = [.sc55, .mt32]
        }
        guard !candidates.isEmpty, let folder = Self.romLibraryFolder else {
            // Also cancels a ROM load still in flight.
            useExternalMIDI()
            completion?(false)
            return
        }
        configurationGeneration += 1
        let generation = configurationGeneration
        // Reading several MB of ROMs off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            var loaded: LoadedROMs?
            for kind in candidates {
                // Automatic mode only considers modules whose ROMs are present at all.
                if choice == .automatic && kind == .sc55 && !Self.hasSC55ROMsInLibrary { continue }
                do {
                    loaded = try Self.readROMs(kind, from: folder)
                    break
                } catch {
                    failures.append("\(kind.displayName): \(error.localizedDescription)")
                }
            }
            let result = loaded
            let failureSummary = failures.joined(separator: "; ")
            DispatchQueue.main.async {
                guard let self, self.configurationGeneration == generation else { return }
                guard let loaded = result else {
                    if !failureSummary.isEmpty {
                        warningLog("Internal MIDI ROMs not usable, using external MIDI: \(failureSummary)", category: .audio)
                    }
                    self.useExternalMIDI()
                    completion?(false)
                    return
                }
                self.startInternalSynth(roms: loaded) { [weak self] error in
                    if let error {
                        warningLog("\(loaded.kind.displayName) unavailable, using external MIDI: \(error.localizedDescription)", category: .audio)
                        self?.useExternalMIDI()
                    } else {
                        infoLog("Internal \(loaded.kind.displayName) enabled (Documents/MPX68K)", category: .audio)
                    }
                    completion?(error == nil)
                }
            }
        }
    }
    #endif

    func useExternalMIDI() {
        configurationGeneration += 1
        clearPendingMIDI()
        activeInternalSynth = nil
        SC55Synthesizer.shared.stop()
        MT32Synthesizer.shared.stop()
        for kind in InternalSynth.allCases {
            UserDefaults.standard.set(false, forKey: enabledKey(kind))
        }
    }

    func restoreSC55(completion: @escaping (Error?) -> Void) {
        restoreInternalSynth(.sc55, completion: completion)
    }

    func restoreMT32(completion: @escaping (Error?) -> Void) {
        restoreInternalSynth(.mt32, completion: completion)
    }

    /// Restarts a module from its remembered ROM folder (macOS).
    func restoreInternalSynth(_ kind: InternalSynth, completion: @escaping (Error?) -> Void) {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey(kind)) else {
            let message = "\(kind.displayName) ROMフォルダーを選択してください。"
            completion(kind == .sc55 ? SC55Synthesizer.failure(message) : MT32Synthesizer.failure(message))
            return
        }
        do {
            var stale = false
            let scoped = UserDefaults.standard.object(forKey: bookmarkScopedKey(kind)) as? Bool ?? true
            let folder = try URL(resolvingBookmarkData: bookmark, options: scoped ? .x68SecurityScope : [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            // configureInternalSynth refreshes the bookmark after validating and loading the files.
            configureInternalSynth(kind, folder: folder, completion: completion)
        } catch { completion(error) }
    }

    /// Whether a ROM folder has been chosen for the module (macOS).
    func hasRememberedROMFolder(for kind: InternalSynth) -> Bool {
        UserDefaults.standard.data(forKey: bookmarkKey(kind)) != nil
    }

    private func clearPendingMIDI() {
        pendingEvents.removeAll()
        pendingIndex = 0
        runningStatus = nil
        pendingStatus = nil
        pendingExpected = 0
        pendingData.removeAll()
        inSysEx = false
        sysExBuffer.removeAll()
    }

    /// Reboots the active internal module together with the emulated X68000.
    func resetInternalSynth() {
        clearPendingMIDI()
        activeSynthesizer?.reset()
    }

    /// Pauses/resumes whichever internal module is running (app inactive/active).
    func setInternalSynthPaused(_ paused: Bool) {
        SC55Synthesizer.shared.setPaused(paused)
        MT32Synthesizer.shared.setPaused(paused)
    }

    private func reportInternalSynthError(_ kind: InternalSynth, _ error: Error) {
        errorLog("\(kind.displayName): \(error.localizedDescription)", category: .audio)
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "\(kind.displayName) Internal MIDI"
        alert.informativeText = error.localizedDescription + "\nSystem → MIDI Output から設定を確認してください。"
        alert.runModal()
        #endif
    }
    var clientRef:   MIDIClientRef = 0
    var inPortRef:   MIDIPortRef = 0
    var outPortRef:  MIDIPortRef = 0
    var outPortRef2: MIDIPortRef = 0

    var midiSource : MIDIEndpointRef = 0
    var midiDst0 : MIDIEndpointRef = 0
    var midiDst1 : MIDIEndpointRef = 0
    var midiDst2 : MIDIEndpointRef = 0
    private var midiDests: [MIDIEndpointRef] = []
    private var outputDelayMs: Double = 0.0

    private struct PendingEvent {
        let dueTime: CFTimeInterval
        let data: [UInt8]
    }
    private var pendingEvents: [PendingEvent] = []
    private var pendingIndex: Int = 0

    private var runningStatus: UInt8? = nil
    private var pendingStatus: UInt8? = nil
    private var pendingExpected: Int = 0
    private var pendingData: [UInt8] = []
    private var inSysEx: Bool = false
    private var sysExBuffer: [UInt8] = []
    
    
    init() {
        Connect()
        SC55Synthesizer.shared.onFailure = { [weak self] message in
            self?.useExternalMIDI()
            self?.reportInternalSynthError(.sc55, SC55Synthesizer.failure(message))
        }
        MT32Synthesizer.shared.onFailure = { [weak self] message in
            self?.useExternalMIDI()
            self?.reportInternalSynthError(.mt32, MT32Synthesizer.failure(message))
        }
        #if os(iOS)
        DispatchQueue.main.async { [weak self] in
            self?.applyIOSMIDIOutput()
        }
        #else
        if let kind = InternalSynth.allCases.first(where: { UserDefaults.standard.bool(forKey: enabledKey($0)) }) {
            DispatchQueue.main.async { [weak self] in
                self?.restoreInternalSynth(kind) { error in
                    if let error { self?.reportInternalSynthError(kind, error) }
                }
            }
        }
        #endif
    }
    let clientName: CFString = "MPX68K" as CFString
    deinit {
        SC55Synthesizer.shared.stop()
        MT32Synthesizer.shared.stop()
        if outPortRef2 != 0 {
            MIDIPortDispose( outPortRef2 )
            outPortRef2 = 0
        }
        if outPortRef != 0 {
            MIDIPortDispose( outPortRef )
            outPortRef = 0
        }
        if inPortRef != 0 {
            MIDIPortDispose( inPortRef )
            inPortRef = 0
        }
        
        if clientRef != 0 {
            MIDIClientDispose( clientRef )
            clientRef = 0
        }
    }
    func MyMIDIReadBlock(packetList: UnsafePointer<MIDIPacketList>,
                         srcConnRefCon: UnsafeMutableRawPointer?) -> Void {
        let packets: MIDIPacketList = packetList.pointee
        var packet: MIDIPacket = packets.packet
        for _ in 0 ..< packets.numPackets {
            if packet.data.0 == 0xF8 || packet.data.0 == 0xFE {
                continue
            }
            var str = ""
            switch packet.length {
            case 1: str = String(format: "%02X", packet.data.0)
            case 2: str = String(format: "%02X %02X", packet.data.0, packet.data.1)
            case 3: str = String(format: "%02X %02X %02X", packet.data.0, packet.data.1, packet.data.2)
            default: str = "length: \(packet.length)"
            }
            debugLog("MIDI: \(str)", category: .network)
            packet = MIDIPacketNext( &packet ).pointee
        }
    }
    
    func Connect() {
        var status: OSStatus = noErr
        
        status = MIDIClientCreateWithBlock( "MPX68K" as CFString, &clientRef, MIDINotifyBlock )
        if status != noErr {
            errorLog("Cannot create MIDI client!", category: .network)
            return
        }
        #if false
        status = MIDIInputPortCreateWithBlock( clientRef, "MPX68K MIDI In" as CFString, &inPortRef, MyMIDIReadBlock )
        if status != noErr {
            errorLog("Cannot create MIDI In!", category: .network)
            return
        }
        #endif
        status = MIDIOutputPortCreate( clientRef, "MPX68K MIDI Out" as CFString, &outPortRef )
        
        if status != noErr {
            errorLog("Cannot create MIDI Out!", category: .network)
            return
        }
        status = MIDIOutputPortCreate( clientRef, "MPX68K MIDI Out" as CFString, &outPortRef2 )
        
        if status != noErr {
            errorLog("Cannot create MIDI Out 2!", category: .network)
            return
        }

        
        self.GetDest()
        self.GetSource()
    }
    
    func Send(_ buffer: UnsafeMutablePointer<UInt8>?, _ count: Int) {
        sendStream(buffer, count)
    }

    func sendStream(_ buffer: UnsafePointer<UInt8>?, _ count: Int) {
        guard let buffer, count > 0 else { return }
        for i in 0..<count {
            handleIncomingByte(buffer[i])
        }
    }

    private func handleIncomingByte(_ byte: UInt8) {
        if inSysEx {
            if byte >= 0xF8 { // realtime can interleave with SysEx
                sendEvent([byte])
                return
            }
            sysExBuffer.append(byte)
            if byte == 0xF7 {
                sendEvent(sysExBuffer)
                sysExBuffer.removeAll(keepingCapacity: true)
                inSysEx = false
            }
            return
        }

        if byte >= 0x80 {
            if byte == 0xF0 {
                inSysEx = true
                sysExBuffer.removeAll(keepingCapacity: true)
                sysExBuffer.append(byte)
                pendingStatus = nil
                pendingExpected = 0
                pendingData.removeAll(keepingCapacity: true)
                return
            }
            if byte >= 0xF8 {
                sendEvent([byte])
                return
            }
            if byte >= 0xF0 {
                runningStatus = nil
                pendingStatus = byte
                pendingExpected = expectedDataLength(for: byte)
                pendingData.removeAll(keepingCapacity: true)
                if pendingExpected == 0 {
                    sendEvent([byte])
                    pendingStatus = nil
                    pendingExpected = 0
                }
                return
            }
            runningStatus = byte
            pendingStatus = byte
            pendingExpected = expectedDataLength(for: byte)
            pendingData.removeAll(keepingCapacity: true)
            return
        }

        if pendingStatus == nil {
            if let running = runningStatus {
                pendingStatus = running
                pendingExpected = expectedDataLength(for: running)
                pendingData.removeAll(keepingCapacity: true)
            } else {
                return
            }
        }

        pendingData.append(byte)
        if pendingData.count >= pendingExpected {
            if let status = pendingStatus {
                var event = [status]
                event.append(contentsOf: pendingData.prefix(pendingExpected))
                sendEvent(event)
                if status >= 0xF0 {
                    runningStatus = nil
                }
            }
            pendingStatus = nil
            pendingExpected = 0
            pendingData.removeAll(keepingCapacity: true)
        }
    }

    private func expectedDataLength(for status: UInt8) -> Int {
        if status >= 0xF0 {
            switch status {
            case 0xF1: return 1
            case 0xF2: return 2
            case 0xF3: return 1
            case 0xF6: return 0
            default: return 0
            }
        }
        let upper = status & 0xF0
        if upper == 0xC0 || upper == 0xD0 {
            return 1
        }
        return 2
    }

    private func sendEvent(_ event: [UInt8]) {
        guard !event.isEmpty else { return }

        if let synth = activeSynthesizer {
            synth.send(event, delayMs: outputDelayMs)
            return
        }

        if outputDelayMs > 0.0 {
            let due = CFAbsoluteTimeGetCurrent() + (outputDelayMs / 1000.0)
            pendingEvents.append(PendingEvent(dueTime: due, data: event))
            return
        }

        sendEventImmediate(event)
    }

    private func sendPackets(_ packets: inout MIDIPacketList) {
        if !midiDests.isEmpty {
            for dest in midiDests {
                MIDISend(outPortRef, dest, &packets)
            }
            return
        }
        if midiDst0 != 0 {
            MIDISend(outPortRef, midiDst0, &packets)
        }
        if midiDst1 != 0 {
            MIDISend(outPortRef2, midiDst1, &packets)
        }
    }

    func setOutputDelayMs(_ ms: Double) {
        outputDelayMs = ms.isFinite ? max(0.0, ms) : 0
    }

    func flushDelayedEvents(_ now: CFTimeInterval = CFAbsoluteTimeGetCurrent()) {
        guard pendingIndex < pendingEvents.count else { return }
        while pendingIndex < pendingEvents.count {
            let item = pendingEvents[pendingIndex]
            if item.dueTime > now {
                break
            }
            sendEventImmediate(item.data)
            pendingIndex += 1
        }
        if pendingIndex > 256 {
            pendingEvents.removeFirst(pendingIndex)
            pendingIndex = 0
        }
    }

    private func sendEventImmediate(_ event: [UInt8]) {
        guard !event.isEmpty else { return }
        if let synth = activeSynthesizer {
            synth.send(event, delayMs: 0)
            return
        }
        if event.count <= 255 {
            var packets = MIDIPacketList(midiEvents: [event])
            sendPackets(&packets)
            return
        }
        var offset = 0
        while offset < event.count {
            let end = min(offset + 255, event.count)
            let slice = Array(event[offset..<end])
            var packets = MIDIPacketList(midiEvents: [slice])
            sendPackets(&packets)
            offset = end
        }
    }
    
    func MIDINotifyBlock(midiNotification: UnsafePointer<MIDINotification>) {
        debugLog("\(#function) \(midiNotification.pointee.messageID.rawValue)", category: .network)
        switch midiNotification.pointee.messageID {
        case .msgPropertyChanged:
            debugLog("msgPropertyChanged", category: .network)
            GetDest()
            GetSource()
        case .msgSetupChanged:
            debugLog("msgSetupChanged", category: .network)
            GetDest()
            GetSource()
        case .msgObjectAdded:   // 接続を検知
            midiDst1 = 0
            debugLog("msgObjectAdded", category: .network)
            GetDest()
            GetSource()
        case .msgObjectRemoved: // 解除を検知
            debugLog("msgObjectRemoved", category: .network)
        case .msgIOError:       // エラーを検知
            errorLog("msgIOError", category: .network)
        default:
            break
        }
        
    }
    
    func GetSource() {
        let n = MIDIGetNumberOfSources()
        for  i in 0..<n {
            // エンドポイントを取得
            let endPointRef = MIDIGetSource( i )
            
            var str: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty( endPointRef, kMIDIPropertyDisplayName, &str )
            if status == noErr {
                
                var text = ""
                text += "MIDI:SRC [\(i)]: "
                text += str!.takeUnretainedValue() as String
                str!.release()
                debugLog("MIDI device: \(text)", category: .network)
                MIDIPortConnectSource(inPortRef,endPointRef,nil)
                
                
            }
            
        }
        
    }
    func GetDest()
    {
        midiDst0 = 0
        midiDst1 = 0
        midiDst2 = 0
        midiDests.removeAll(keepingCapacity: true)

        let n = MIDIGetNumberOfDestinations()
        for  i in 0..<n {
            // エンドポイントを取得
            let endPointRef = MIDIGetDestination( i )
            
            var str: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty( endPointRef, kMIDIPropertyDisplayName, &str )
            if status == noErr {
                
                var text = "MIDI:DST [\(i)]: "
                text += str!.takeUnretainedValue() as String
                str!.release()
                debugLog("MIDI device: \(text)", category: .network)
                midiDests.append(endPointRef)
                if ( i == 0 ) {
                    debugLog("Set! 0", category: .network)
                    midiDst0 = endPointRef
                    //                    var packets = MIDIPacketList(midiEvents: [[0x90, 0x3f, 0x78]])
                    //                    MIDISend(outPortRef, midiDst0, &packets)
                    
                }
                if ( i > 0 ) {
                    debugLog("Set! 1", category: .network)
                    midiDst1 = endPointRef
                }
            }
        }

        if midiDests.isEmpty {
            warningLog("No MIDI destinations found", category: .network)
        }
        
    }
    
    
}
