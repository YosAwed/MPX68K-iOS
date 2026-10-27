//
//  SoundMonitorView.swift
//  MPX68K for iOS
//
//  A sound monitor in the style of the X68000's MDX player screens: one row per
//  OPM (YM2151) channel with a keyboard, the note, a level meter, the pan and the
//  algorithm, plus a row for the ADPCM. Shown in the lower half of the inner
//  display (see InnerPanel.sound).
//
//  fmgen has no readable state, so the levels are estimated from the registers:
//  the carriers' total level, and a simple envelope that restarts on key on and
//  falls with the carriers' release rate on key off.
//

import UIKit

final class SoundMonitorView: UIView {

    private struct FMChannel {
        var level: CGFloat = 0
        var peak: CGFloat = 0
        var peakHold: CFTimeInterval = 0
        var envelope: CGFloat = 0
        var keyOnCount: UInt32 = 0
        var isKeyOn = false
        /// MIDI note number, nil before the first key code write.
        var note: Int?
        /// Pitch above `note` in 1/64 semitones (the key fraction).
        var fraction = 0
        var left = true
        var right = true
        var algorithm = 0
        var feedback = 0
        var isNoise = false
    }

    private var channels = [FMChannel](repeating: FMChannel(), count: 8)
    private var pcmLevel: CGFloat = 0
    private var pcmPeak: CGFloat = 0
    private var pcmPeakHold: CFTimeInterval = 0
    private var pcmPlaying = false
    private var pcmOutput: Int32 = 0
    /// The core keeps the ADPCM "playing" after a sample ends, so show it as playing
    /// only while the decoded output keeps changing.
    private var pcmActiveUntil: CFTimeInterval = 0
    private var pcmLeft = true
    private var pcmRight = true
    private var pcmRate: UInt32 = 0
    private var lfoFrequency = 0
    private var lfoWave = 0

    private var displayLink: CADisplayLink?
    private var lastStep: CFTimeInterval = 0
    private var regs = [UInt8](repeating: 0, count: 256)
    private var slots = [UInt8](repeating: 0, count: 8)
    private var keyOns = [UInt32](repeating: 0, count: 8)

    /// Keyboard background, drawn once per size.
    private var keyboardImage: UIImage?
    private var keyboardImageSize: CGSize = .zero

    // Lowest octave shown (C1 = MIDI 24) and how many octaves.
    private static let firstOctave = 1
    private static let octaves = 7
    private static let meterSegments = 16
    private static let peakHoldTime: CFTimeInterval = 0.6

    private enum Palette {
        static let background = UIColor(red: 0.02, green: 0.03, blue: 0.09, alpha: 1)
        static let grid = UIColor(red: 0.15, green: 0.25, blue: 0.45, alpha: 0.5)
        static let label = UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1)
        static let dimLabel = UIColor(red: 0.35, green: 0.55, blue: 0.75, alpha: 1)
        static let value = UIColor(red: 0.95, green: 0.95, blue: 0.75, alpha: 1)
        static let keyLit = UIColor(red: 1.0, green: 0.35, blue: 0.55, alpha: 1)
        static let keyHeld = UIColor(red: 0.6, green: 0.25, blue: 0.45, alpha: 1)
        static let meterOff = UIColor(red: 0.08, green: 0.12, blue: 0.2, alpha: 1)
        static let meterLow = UIColor(red: 0.2, green: 0.95, blue: 0.55, alpha: 1)
        static let meterMid = UIColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1)
        static let meterHigh = UIColor(red: 1.0, green: 0.3, blue: 0.25, alpha: 1)
    }

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let lfoWaveNames = ["SAW", "SQR", "TRI", "NOI"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.background
        layer.cornerRadius = 8
        layer.borderWidth = 1
        layer.borderColor = Palette.grid.cgColor
        clipsToBounds = true
        contentMode = .redraw
        isOpaque = true
        isAccessibilityElement = true
        accessibilityLabel = "サウンドモニター"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHidden: Bool {
        didSet { updateDisplayLink() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    private func updateDisplayLink() {
        let wantsUpdates = window != nil && !isHidden
        if wantsUpdates, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastStep = 0
        } else if !wantsUpdates, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    // MARK: - State

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastStep == 0 ? 1.0 / 60 : min(0.1, now - lastStep)
        lastStep = now

        regs.withUnsafeMutableBufferPointer { r in
            slots.withUnsafeMutableBufferPointer { s in
                keyOns.withUnsafeMutableBufferPointer { k in
                    X68000_GetOPMMonitor(r.baseAddress, s.baseAddress, k.baseAddress)
                }
            }
        }
        lfoFrequency = Int(regs[0x18])
        lfoWave = Int(regs[0x1b] & 3)
        let noiseEnabled = regs[0x0f] & 0x80 != 0

        for ch in 0..<8 {
            var c = channels[ch]
            let control = regs[0x20 + ch]
            c.right = control & 0x80 != 0
            c.left = control & 0x40 != 0
            c.feedback = Int(control >> 3) & 7
            c.algorithm = Int(control & 7)
            c.isNoise = ch == 7 && noiseEnabled

            let keyCode = regs[0x28 + ch]
            c.fraction = Int(regs[0x30 + ch] >> 2)
            if keyCode != 0 || c.note != nil {
                c.note = Self.midiNote(keyCode: keyCode, fraction: c.fraction)
            }

            // Slot offsets in the register map: M1 +0, M2 +8, C1 +16, C2 +24.
            let carriers = Self.carrierSlots(algorithm: c.algorithm)
            let keyMask = Self.keyMask(forSlots: carriers)
            var minTL = 127
            var maxRR = 0
            for slot in carriers {
                minTL = min(minTL, Int(regs[0x60 + slot * 8 + ch] & 0x7f))
                maxRR = max(maxRR, Int(regs[0xe0 + slot * 8 + ch] & 0x0f))
            }
            // TL is in 0.75 dB steps; show the top 48 dB.
            let volume = max(0, 1 - CGFloat(minTL) * 0.75 / 48)

            c.isKeyOn = slots[ch] & keyMask != 0
            if keyOns[ch] != c.keyOnCount {
                c.keyOnCount = keyOns[ch]
                c.envelope = 1
            } else if c.isKeyOn {
                // Settle towards a sustain level while the key is held.
                c.envelope = 0.7 + (c.envelope - 0.7) * CGFloat(exp(-3 * dt))
            } else {
                // RR 15 is near instant, RR 1 takes seconds.
                let rate = 0.35 * pow(2, Double(maxRR) / 2)
                c.envelope *= CGFloat(exp(-rate * dt))
            }
            if !c.left && !c.right { c.envelope = 0 }
            c.level = c.envelope * volume
            Self.updatePeak(level: c.level, peak: &c.peak, hold: &c.peakHold, now: now, dt: dt)
            channels[ch] = c
        }

        var pan: Int32 = 0
        var output: Int32 = 0
        var rate: UInt32 = 0
        let playing = X68000_GetADPCMMonitor(&pan, &output, &rate) != 0
        if playing && output != pcmOutput {
            pcmActiveUntil = now + 0.25
        }
        pcmOutput = output
        pcmPlaying = playing && now < pcmActiveUntil
        pcmRight = pan & 1 == 0
        pcmLeft = pan & 2 == 0
        pcmRate = rate
        let target: CGFloat = pcmPlaying && (pcmLeft || pcmRight) ? min(1, CGFloat(abs(output)) / 1400) : 0
        // Fast attack, slow fall: the decoded sample swings through zero all the time.
        pcmLevel = target > pcmLevel ? target : pcmLevel * CGFloat(exp(-6 * dt))
        Self.updatePeak(level: pcmLevel, peak: &pcmPeak, hold: &pcmPeakHold, now: now, dt: dt)

        setNeedsDisplay()
    }

    private static func updatePeak(level: CGFloat, peak: inout CGFloat, hold: inout CFTimeInterval,
                                   now: CFTimeInterval, dt: CFTimeInterval) {
        if level >= peak {
            peak = level
            hold = now + peakHoldTime
        } else if now > hold {
            peak = max(level, peak - CGFloat(dt) * 0.8)
        }
    }

    /// The X68000 runs the OPM at 4 MHz, not the 3.58 MHz its key codes are specified for,
    /// so every note sounds this many semitones higher (drivers write lower key codes).
    private static let clockOffset = 12 * log2(4_000_000.0 / 3_579_545.0)

    /// OPM key code (octave in bits 6-4, note 0-14 with gaps at 3, 7, 11, 15 in bits 3-0;
    /// note 0 is C#) and key fraction (1/64 semitone) to the MIDI note that sounds.
    /// At 3.58 MHz octave 4 note 10 is A4.
    private static func midiNote(keyCode: UInt8, fraction: Int) -> Int {
        let octave = Int(keyCode >> 4) & 7
        let code = Int(keyCode & 0x0f)
        let step = code - code / 4    // 0,1,2,(3),4,5,6,(7)... -> 0,1,2,3,3,4,5,6...
        let note = 12 * (octave + 1) + 1 + min(step, 11)
        return Int((Double(note) + Double(fraction) / 64 + clockOffset).rounded())
    }

    /// Carrier slots per algorithm, as register slot indices (0 M1, 1 M2, 2 C1, 3 C2).
    private static func carrierSlots(algorithm: Int) -> [Int] {
        switch algorithm {
        case 0...3: return [3]
        case 4: return [2, 3]
        case 5, 6: return [1, 2, 3]
        default: return [0, 1, 2, 3]
        }
    }

    /// Key on bits for register slots (key on order: bit 0 M1, 1 C1, 2 M2, 3 C2).
    private static func keyMask(forSlots slots: [Int]) -> UInt8 {
        let bitForSlot: [UInt8] = [1, 4, 2, 8]
        return slots.reduce(0) { $0 | bitForSlot[$1] }
    }

    // MARK: - Drawing

    private struct Columns {
        var label: CGRect
        var note: CGRect
        var keyboard: CGRect
        var meter: CGRect
        var pan: CGRect
        var algorithm: CGRect?
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let inset = bounds.insetBy(dx: 8, dy: 6)
        let headerHeight: CGFloat = 18
        let rowCount: CGFloat = 9
        let rowHeight = min(34, (inset.height - headerHeight - 4) / rowCount)
        let compact = inset.width < 330

        drawHeader(in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: headerHeight))

        var y = inset.minY + headerHeight + 4
        for ch in 0..<8 {
            let row = CGRect(x: inset.minX, y: y, width: inset.width, height: rowHeight)
            drawFMRow(ch, in: row, compact: compact, context: context)
            y += rowHeight
        }
        drawPCMRow(in: CGRect(x: inset.minX, y: y, width: inset.width, height: rowHeight),
                   compact: compact, context: context)
    }

    private func columns(for row: CGRect, compact: Bool) -> Columns {
        let labelWidth: CGFloat = 30
        let noteWidth: CGFloat = 34
        let meterWidth: CGFloat = compact ? 52 : 72
        let panWidth: CGFloat = 22
        let algorithmWidth: CGFloat = compact ? 0 : 30
        let gap: CGFloat = 6
        var x = row.minX
        func take(_ width: CGFloat) -> CGRect {
            defer { x += width + gap }
            return CGRect(x: x, y: row.minY, width: width, height: row.height)
        }
        let label = take(labelWidth)
        let note = take(noteWidth)
        let fixed = meterWidth + panWidth + (compact ? 0 : algorithmWidth + gap) + 2 * gap
        let keyboard = take(max(40, row.maxX - x - fixed))
        let meter = take(meterWidth)
        let pan = take(panWidth)
        let algorithm = compact ? nil : take(algorithmWidth)
        return Columns(label: label, note: note, keyboard: keyboard, meter: meter, pan: pan, algorithm: algorithm)
    }

    private func drawHeader(in rect: CGRect) {
        let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        draw("YM2151 OPM", in: rect, font: font, color: Palette.label, alignment: .left)
        let lfo = "LFO \(String(format: "%3d", lfoFrequency)) \(Self.lfoWaveNames[lfoWave])"
        let pcm = pcmRate > 0 ? String(format: "  ADPCM %.1fkHz", Double(pcmRate) / 1000) : ""
        draw(lfo + pcm, in: rect, font: UIFont.monospacedSystemFont(ofSize: 10, weight: .medium),
             color: Palette.dimLabel, alignment: .right)
    }

    private func drawFMRow(_ ch: Int, in row: CGRect, compact: Bool, context: CGContext) {
        let c = channels[ch]
        let cols = columns(for: row, compact: compact)
        let font = UIFont.monospacedSystemFont(ofSize: min(12, row.height * 0.5), weight: .semibold)
        let active = c.level > 0.02

        draw("FM\(ch + 1)", in: cols.label, font: font, color: active ? Palette.label : Palette.dimLabel, alignment: .left)
        let noteText: String
        if c.isNoise {
            noteText = "NOIS"
        } else if let note = c.note {
            noteText = "\(Self.noteNames[note % 12])\(note / 12 - 1)"
        } else {
            noteText = "---"
        }
        draw(noteText, in: cols.note, font: font, color: active ? Palette.value : Palette.dimLabel, alignment: .left)

        let keys = cols.keyboard.insetBy(dx: 0, dy: max(2, row.height * 0.12))
        drawKeyboard(in: keys, context: context)
        if let note = c.note, !c.isNoise, c.level > 0.02 || c.isKeyOn {
            let color = c.isKeyOn ? Palette.keyLit : Palette.keyHeld
            highlightKey(note, in: keys, color: color.withAlphaComponent(0.4 + 0.6 * min(1, c.envelope)), context: context)
        }

        drawMeter(level: c.level, peak: c.peak, in: cols.meter.insetBy(dx: 0, dy: row.height * 0.28), context: context)
        drawPan(left: c.left, right: c.right, in: cols.pan, font: font)
        if let algorithmRect = cols.algorithm {
            draw("AL\(c.algorithm)", in: algorithmRect, font: font, color: Palette.dimLabel, alignment: .right)
        }
    }

    private func drawPCMRow(in row: CGRect, compact: Bool, context: CGContext) {
        let cols = columns(for: row, compact: compact)
        let font = UIFont.monospacedSystemFont(ofSize: min(12, row.height * 0.5), weight: .semibold)

        context.setStrokeColor(Palette.grid.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: row.minX, y: row.minY + 0.5))
        context.addLine(to: CGPoint(x: row.maxX, y: row.minY + 0.5))
        context.strokePath()

        draw("PCM", in: cols.label, font: font, color: pcmPlaying ? Palette.label : Palette.dimLabel, alignment: .left)
        draw(pcmPlaying ? "PLAY" : "----", in: cols.note, font: font,
             color: pcmPlaying ? Palette.value : Palette.dimLabel, alignment: .left)
        // A wide meter in place of the keyboard.
        let wave = cols.keyboard.insetBy(dx: 0, dy: row.height * 0.28)
        drawMeter(level: pcmLevel, peak: pcmPeak, in: wave, context: context, segments: 32)
        drawMeter(level: pcmLevel, peak: pcmPeak, in: cols.meter.insetBy(dx: 0, dy: row.height * 0.28), context: context)
        drawPan(left: pcmLeft, right: pcmRight, in: cols.pan, font: font)
    }

    private func drawKeyboard(in rect: CGRect, context: CGContext) {
        if keyboardImage == nil || keyboardImageSize != rect.size {
            keyboardImageSize = rect.size
            keyboardImage = UIGraphicsImageRenderer(size: rect.size).image { _ in
                Self.drawKeys(in: CGRect(origin: .zero, size: rect.size))
            }
        }
        keyboardImage?.draw(in: rect)
    }

    /// White keys with a black-key overlay, `octaves` octaves wide.
    private static func drawKeys(in rect: CGRect) {
        let whiteCount = CGFloat(octaves * 7)
        let whiteWidth = rect.width / whiteCount
        UIColor(white: 0.82, alpha: 1).setFill()
        UIRectFill(rect)
        UIColor(white: 0.35, alpha: 1).setFill()
        for i in 0...Int(whiteCount) {
            UIRectFill(CGRect(x: rect.minX + CGFloat(i) * whiteWidth, y: rect.minY, width: max(0.5, whiteWidth * 0.12), height: rect.height))
        }
        UIColor(white: 0.08, alpha: 1).setFill()
        for octave in 0..<octaves {
            for semitone in [1, 3, 6, 8, 10] {
                UIRectFill(blackKeyRect(octave: octave, semitone: semitone, in: rect))
            }
        }
    }

    private static let whiteIndex = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
    private static func isBlack(_ semitone: Int) -> Bool { [1, 3, 6, 8, 10].contains(semitone) }

    private static func blackKeyRect(octave: Int, semitone: Int, in rect: CGRect) -> CGRect {
        let whiteWidth = rect.width / CGFloat(octaves * 7)
        let width = whiteWidth * 0.62
        let x = rect.minX + CGFloat(octave * 7 + whiteIndex[semitone] + 1) * whiteWidth - width / 2
        return CGRect(x: x, y: rect.minY, width: width, height: rect.height * 0.6)
    }

    private func highlightKey(_ note: Int, in rect: CGRect, color: UIColor, context: CGContext) {
        let octave = note / 12 - 1 - Self.firstOctave
        guard octave >= 0, octave < Self.octaves else { return }
        let semitone = note % 12
        let keyRect: CGRect
        if Self.isBlack(semitone) {
            keyRect = Self.blackKeyRect(octave: octave, semitone: semitone, in: rect)
        } else {
            let whiteWidth = rect.width / CGFloat(Self.octaves * 7)
            keyRect = CGRect(x: rect.minX + CGFloat(octave * 7 + Self.whiteIndex[semitone]) * whiteWidth,
                             y: rect.minY, width: whiteWidth, height: rect.height)
        }
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6, color: color.cgColor)
        color.setFill()
        UIRectFill(keyRect.insetBy(dx: 0.5, dy: 0))
        context.restoreGState()
    }

    private func drawMeter(level: CGFloat, peak: CGFloat, in rect: CGRect, context: CGContext,
                           segments: Int = SoundMonitorView.meterSegments) {
        let gap: CGFloat = 1.5
        let width = (rect.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        guard width > 0 else { return }
        let lit = Int((level * CGFloat(segments)).rounded())
        let peakIndex = Int((peak * CGFloat(segments)).rounded()) - 1
        for i in 0..<segments {
            let fraction = CGFloat(i) / CGFloat(segments)
            let onColor = fraction < 0.6 ? Palette.meterLow : (fraction < 0.85 ? Palette.meterMid : Palette.meterHigh)
            let color = (i < lit || i == peakIndex) ? onColor : Palette.meterOff
            color.setFill()
            UIRectFill(CGRect(x: rect.minX + CGFloat(i) * (width + gap), y: rect.minY, width: width, height: rect.height))
        }
    }

    private func drawPan(left: Bool, right: Bool, in rect: CGRect, font: UIFont) {
        let half = rect.width / 2
        draw("L", in: CGRect(x: rect.minX, y: rect.minY, width: half, height: rect.height), font: font,
             color: left ? Palette.label : Palette.meterOff, alignment: .center)
        draw("R", in: CGRect(x: rect.minX + half, y: rect.minY, width: half, height: rect.height), font: font,
             color: right ? Palette.label : Palette.meterOff, alignment: .center)
    }

    private func draw(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let height = font.lineHeight
        (text as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                                withAttributes: attributes)
    }
}
