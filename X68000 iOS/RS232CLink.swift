import Foundation
import Network
import UIKit
import dnssd

/// The RS-232C port's cross cable to another device running this app.
///
/// The emulation core (scc.c) turns everything the port does into an ordered byte
/// stream: characters, RTS/DTR/break changes and the line settings. This class only
/// finds the other device and carries that stream both ways. Discovery is Bonjour with
/// peer-to-peer enabled, so two devices find each other with or without a shared Wi-Fi
/// network (Bluetooth is used to discover, Wi-Fi to carry the data).
final class RS232CLink {
    static let shared = RS232CLink()

    enum State: Equatable {
        case off
        case searching
        case connected(peer: String)
        /// The user has not allowed local network access.
        case blocked
    }

    /// Changes are reported on the main queue.
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .off

    private static let serviceType = "_mpx68k-rs232c._tcp"
    private static let greeting = "MPX68K-RS232C/1 "

    private let queue = DispatchQueue(label: "mpx68k.rs232c-link")
    /// Decides which of two devices opens the connection: the smaller ID does.
    private let id = String(format: "%08X", UInt32.random(in: UInt32.min ... UInt32.max))
    private var running = false
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var candidates: [NWConnection] = []
    private var connection: NWConnection?

    private let drainLock = NSLock()
    private var drainScheduled = false

    private init() {}

    // MARK: - Control (main queue)

    var isEnabled: Bool { state != .off }

    func start() {
        guard state == .off else { return }
        state = .searching
        SCC_LinkSetTxNotify { RS232CLink.shared.scheduleDrain() }
        queue.async {
            self.running = true
            self.startDiscovery()
        }
    }

    func stop() {
        guard state != .off else { return }
        state = .off
        SCC_LinkSetTxNotify(nil)
        queue.async {
            self.running = false
            self.stopDiscovery()
            self.candidates.forEach { $0.cancel() }
            self.candidates.removeAll()
            if let connection = self.connection {
                self.connection = nil
                connection.cancel()
                SCC_LinkSetConnected(0)
            }
        }
    }

    private func publish(_ newState: State) {
        DispatchQueue.main.async {
            // stop() wins over anything still arriving from the link queue.
            guard self.state != .off, self.state != newState else { return }
            self.state = newState
            self.onStateChange?(newState)
        }
    }

    // MARK: - Discovery (link queue)

    private var displayName: String { UIDevice.current.name }

    private func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true              // characters must not wait to be batched
        tcp.enableKeepalive = true      // notice a peer that vanished
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    private func startDiscovery() {
        guard running, connection == nil, listener == nil else { return }
        do {
            let listener = try NWListener(using: parameters())
            listener.service = NWListener.Service(name: "\(id) \(displayName)", type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] incoming in self?.adopt(incoming) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.restartDiscovery() }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            restartDiscovery()
            return
        }

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.consider(results) }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                    self.publish(.blocked)
                } else if case .failed = state {
                    self.restartDiscovery()
                }
            case .ready:
                if self.connection == nil { self.publish(.searching) }
            default:
                break
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func stopDiscovery() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
    }

    private func restartDiscovery() {
        stopDiscovery()
        queue.asyncAfter(deadline: .now() + 1) { self.startDiscovery() }
    }

    private func consider(_ results: Set<NWBrowser.Result>) {
        guard running, connection == nil, candidates.isEmpty else { return }
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            let peerID = String(name.prefix(8))
            // Only the smaller ID calls, so a pair never opens two connections.
            guard peerID.count == 8, id < peerID else { continue }
            adopt(NWConnection(to: result.endpoint, using: parameters()))
            return
        }
    }

    // MARK: - Connection (link queue)

    /// A connection that still has to exchange greetings. The first one to finish becomes the cable.
    private func adopt(_ candidate: NWConnection) {
        guard running, connection == nil else {
            candidate.cancel()
            return
        }
        candidates.append(candidate)
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let self, let candidate else { return }
            switch state {
            case .ready:
                let greeting = Data((Self.greeting + self.displayName + "\n").utf8)
                candidate.send(content: greeting, completion: .contentProcessed { _ in })
                self.readGreeting(from: candidate, buffer: Data())
            case .failed, .cancelled:
                self.dropped(candidate)
            case .waiting:
                // The advertised peer is not reachable (a stale record, for example).
                candidate.cancel()
            default:
                break
            }
        }
        candidate.start(queue: queue)
    }

    private func readGreeting(from candidate: NWConnection, buffer: Data) {
        candidate.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                guard line.hasPrefix(Self.greeting), self.connection == nil,
                      self.candidates.contains(where: { $0 === candidate }) else {
                    candidate.cancel()
                    return
                }
                let rest = buffer[buffer.index(after: newline)...]
                self.promote(candidate, peer: String(line.dropFirst(Self.greeting.count)), pending: Data(rest))
            } else if isComplete || error != nil || buffer.count > 256 {
                candidate.cancel()
            } else {
                self.readGreeting(from: candidate, buffer: buffer)
            }
        }
    }

    private func promote(_ candidate: NWConnection, peer: String, pending: Data) {
        connection = candidate
        candidates.removeAll { $0 === candidate }
        candidates.forEach { $0.cancel() }
        candidates.removeAll()
        stopDiscovery()                 // a cable has two ends

        SCC_LinkSetConnected(1)
        feed(pending)
        receive(on: candidate)
        publish(.connected(peer: peer.isEmpty ? "MPX68K" : peer))
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.feed(data) }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { bytes in
            SCC_LinkFeed(bytes.bindMemory(to: UInt8.self).baseAddress, Int32(bytes.count))
        }
    }

    private func dropped(_ gone: NWConnection) {
        candidates.removeAll { $0 === gone }
        guard connection === gone else {
            // A failed call: look again at who is advertising.
            if running, connection == nil, candidates.isEmpty, let browser {
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.browser === browser else { return }
                    self.consider(browser.browseResults)
                }
            }
            return
        }
        connection = nil
        SCC_LinkSetConnected(0)         // the cable was pulled out
        guard running else { return }
        publish(.searching)
        queue.asyncAfter(deadline: .now() + 1) { self.startDiscovery() }
    }

    // MARK: - Outgoing bytes

    /// Called by the core on the emulation thread whenever the port produced something.
    private func scheduleDrain() {
        drainLock.lock()
        let alreadyScheduled = drainScheduled
        drainScheduled = true
        drainLock.unlock()
        guard !alreadyScheduled else { return }
        queue.async { self.drain() }
    }

    private func drain() {
        drainLock.lock()
        drainScheduled = false
        drainLock.unlock()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Int(SCC_LinkDrain(&buffer, Int32(buffer.count)))
            guard count > 0 else { return }
            guard let connection else { continue }      // nobody to send to: discard
            connection.send(content: Data(buffer[0..<count]), completion: .contentProcessed { error in
                if error != nil { connection.cancel() }
            })
        }
    }

    // MARK: - Status text

    /// "9765 bps 8N1", from what the X68000 program set up on the port.
    static func lineSettingsText(baud: Int32, format: Int32) -> String {
        let dataBits = (format >> 16) & 0xff
        let parity = ["N", "O", "E"][Int(min(max((format >> 8) & 0xff, 0), 2))]
        let stop = ["1", "1.5", "2"][Int(min(max((format & 0xff) - 2, 0), 2))]
        return "\(baud) bps \(dataBits)\(parity)\(stop)"
    }

    /// The port as the core sees it right now (main queue, where the emulation runs).
    static func portSummary() -> (settings: String, lines: String, mismatch: Bool) {
        let baud = SCC_LinkGetInfo(Int32(SCC_LINK_INFO_BAUD.rawValue))
        let format = SCC_LinkGetInfo(Int32(SCC_LINK_INFO_FORMAT.rawValue))
        let peerBaud = SCC_LinkGetInfo(Int32(SCC_LINK_INFO_PEER_BAUD.rawValue))
        let peerFormat = SCC_LinkGetInfo(Int32(SCC_LINK_INFO_PEER_FORMAT.rawValue))
        let out = SCC_LinkGetInfo(Int32(SCC_LINK_INFO_LINES.rawValue))
        let peer = SCC_LinkGetInfo(Int32(SCC_LINK_INFO_PEER_LINES.rawValue))
        func lamp(_ on: Bool) -> String { on ? "●" : "○" }
        let lines = "RTS\(lamp(out & 1 != 0)) CTS\(lamp(peer & 1 != 0)) DTR\(lamp(out & 2 != 0)) DSR\(lamp(peer & 2 != 0))"
        let mine = lineSettingsText(baud: baud, format: format)
        guard peerBaud != 0, peerFormat != 0 else { return (mine, lines, false) }
        let theirs = lineSettingsText(baud: peerBaud, format: peerFormat)
        // Stop bits do not have to match; the core applies the same rule.
        let mismatch = abs(peerBaud - baud) * 16 > baud || (peerFormat >> 8) != (format >> 8)
        return (mismatch ? "こちら \(mine)／相手 \(theirs)" : mine, lines, mismatch)
    }
}

/// A short note at the top of the screen when the cable connects or drops.
final class LinkNoticeView: UIView {
    private let label = UILabel()
    private var hideTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.7)
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        isUserInteractionEnabled = false
        alpha = 0
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.numberOfLines = 2
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String) {
        label.text = text
        accessibilityLabel = text
        UIAccessibility.post(notification: .announcement, argument: text)
        hideTimer?.invalidate()
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.4) { self?.alpha = 0 }
        }
    }
}
