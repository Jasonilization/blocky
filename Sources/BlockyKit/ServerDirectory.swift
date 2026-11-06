//
//  ServerDirectory.swift
//  Blocky
//
//  PART 4 — Recommended multiplayer servers, with a real Minecraft Server
//  List Ping (SLP) so every row can prove it is connectable right now:
//  TCP handshake → handshake + status packets → the server's own JSON
//  answer (version, player counts, MOTD). No Minecraft code required —
//  the same probe every server browser uses.
//

import Foundation
import Network

// MARK: - Directory

public struct ServerEntry: Identifiable, Hashable {
    public let id = UUID()
    public let name: String
    public let host: String
    public let port: UInt16
    public let blurb: String
    public let tags: [String]
    /// "host:port" as the user would type it into Minecraft's Direct
    /// Connect — always port-explicit so non-25565 servers are copy-safe.
    public var address: String { port == 25565 ? host : "\(host):\(port)" }

    public init(name: String, host: String, port: UInt16, blurb: String, tags: [String]) {
        self.name = name
        self.host = host
        self.port = port
        self.blurb = blurb
        self.tags = tags
    }
}

public enum ServerDirectory {

    /// A standing recommendation list. Offline-friendly / cracked servers
    /// first — Blocky runs offline sessions, so premium-only networks would
    /// just show "invalid session" and waste the user's time.
    public static let recommended: [ServerEntry] = [
        ServerEntry(
            name: "MineBerry",
            host: "mc.mineberry.org",
            port: 25565,
            blurb: "Skyblock, Survival, Towny — plays offline",
            tags: ["Cracked", "Skyblock", "Survival"]
        ),
        ServerEntry(
            name: "Herobrine.org",
            host: "herobrine.org",
            port: 25565,
            blurb: "The classic cracked server",
            tags: ["Cracked", "Survival", "PvP"]
        ),
        ServerEntry(
            name: "BlocksMC",
            host: "blocksmc.com",
            port: 25565,
            blurb: "SkyBlock & EggWars, offline usernames",
            tags: ["Cracked", "SkyBlock", "EggWars"]
        ),
        ServerEntry(
            name: "PvP Legacy",
            host: "play.pvplegacy.net",
            port: 25565,
            blurb: "Factions & competitive SkyBlock",
            tags: ["Cracked", "Factions", "SkyBlock"]
        ),
        ServerEntry(
            name: "OPBlocks",
            host: "mc.opblocks.com",
            port: 25565,
            blurb: "OP survival and skyblock, offline friendly",
            tags: ["Cracked", "SkyBlock", "OP"]
        ),
    ]

    /// Parse a user-typed address ("host", "host:port", "host:25570").
    public static func parseAddress(_ text: String) -> ServerEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let host: String
        let port: UInt16
        if let colon = trimmed.lastIndex(of: ":"),
           let parsed = UInt16(trimmed[trimmed.index(after: colon)...]) {
            host = String(trimmed[trimmed.startIndex..<colon])
            port = parsed
        } else {
            host = trimmed
            port = 25565
        }
        guard !host.isEmpty else { return nil }
        return ServerEntry(name: host, host: host, port: port, blurb: "Custom server", tags: [])
    }
}

// MARK: - Status

public struct ServerStatus: Hashable {
    public enum State: Hashable {
        case checking
        case online
        case offline       // refused / no answer — not connectable right now
        case unreachable   // DNS or network failure — unknown, not a verdict
    }

    public let state: State
    public let latencyMS: Int?
    public let playersOnline: Int?
    public let playersMax: Int?
    public let versionLabel: String?
    public let motd: String?

    public init(state: State,
                latencyMS: Int? = nil,
                playersOnline: Int? = nil,
                playersMax: Int? = nil,
                versionLabel: String? = nil,
                motd: String? = nil) {
        self.state = state
        self.latencyMS = latencyMS
        self.playersOnline = playersOnline
        self.playersMax = playersMax
        self.versionLabel = versionLabel
        self.motd = motd
    }

    public static let checking = ServerStatus(state: .checking)
}

// MARK: - SLP client

/// One Minecraft Server List Ping over TCP.
public final class ServerPingClient: Sendable {

    /// Minecraft protocol version handed to the server in the handshake.
    /// The STATUS response itself is version-agnostic; any sane server
    /// answers with its own real version in JSON regardless.
    private static let handshakeProtocol = 767

    private static let timeoutSeconds: DispatchTimeInterval = .seconds(6)

    public init() {}

    public func ping(_ entry: ServerEntry) async -> ServerStatus {
        let started = Date()
        guard let port = NWEndpoint.Port(rawValue: entry.port) else {
            return ServerStatus(state: .offline)
        }

        return await withCheckedContinuation { continuation in
            let finisher = OnceResolver()
            let connection = NWConnection(
                host: NWEndpoint.Host(entry.host),
                port: port,
                using: .tcp
            )

            func finish(_ status: ServerStatus) {
                connection.cancel()
                finisher.resolve(continuation, status)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let handshake = Self.handshakePacket(host: entry.host, port: entry.port)
                    let request = Self.statusRequestPacket()
                    let payload = handshake + request
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if error != nil { finish(ServerStatus(state: .offline)); return }
                    })
                    Self.receive(connection: connection) { answer in
                        guard let answer else {
                            finish(ServerStatus(state: .offline)); return
                        }
                        let latency = Int(Date().timeIntervalSince(started) * 1000)
                        finish(ServerStatus(
                            state: .online,
                            latencyMS: latency,
                            playersOnline: answer.playersOnline,
                            playersMax: answer.playersMax,
                            versionLabel: answer.versionLabel,
                            motd: answer.motd
                        ))
                    }
                case .failed, .cancelled:
                    finish(ServerStatus(state: .offline))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            // Cancels the connection and answers .offline if the server
            // never completes the handshake — the continuation resolves
            // exactly once, whichever side fires first.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds) {
                connection.cancel()
                finisher.resolve(continuation, ServerStatus(state: .offline))
            }
        }
    }

    // MARK: Packets

    private static func handshakePacket(host: String, port: UInt16) -> Data {
        var payload = Data()
        writeVarint(0x00, into: &payload)                 // packet id
        writeVarint(handshakeProtocol, into: &payload)
        writeString(host, into: &payload)
        var bigEndianPort = port.bigEndian
        withUnsafeBytes(of: &bigEndianPort) { payload.append(contentsOf: $0) }
        writeVarint(1, into: &payload)                    // next state: status
        return framed(payload)
    }

    private static func statusRequestPacket() -> Data {
        Data([0x01, 0x00])   // length 1, packet id 0
    }

    private static func framed(_ payload: Data) -> Data {
        var frame = Data()
        writeVarint(payload.count, into: &frame)
        frame.append(payload)
        return frame
    }

    private static func writeVarint(_ value: Int, into data: inout Data) {
        var v = UInt32(bitPattern: Int32(value))
        while true {
            if v & 0xFFFFFF80 == 0 {
                data.append(UInt8(v))
                return
            }
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
    }

    private static func writeString(_ text: String, into data: inout Data) {
        let bytes = Array(text.utf8)
        writeVarint(bytes.count, into: &data)
        data.append(contentsOf: bytes)
    }

    // MARK: Receive

    struct Answer {
        let playersOnline: Int?
        let playersMax: Int?
        let versionLabel: String?
        let motd: String?
    }

    private static func receive(connection: NWConnection,
                                completion: @escaping (Answer?) -> Void) {
        // The status response is a single packet; collect it in a growing
        // buffer and re-parse until the varints and the JSON string fit.
        final class Box { var buffer = Data() }
        let box = Box()
        let done = OnceResolver()

        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let data, !data.isEmpty { box.buffer.append(data) }
                if error != nil || isComplete {
                    done.once { completion(nil) }
                    return
                }
                if let answer = parseStatusResponse(box.buffer) {
                    done.once { completion(answer) }
                    return
                }
                pump()
            }
        }
        pump()
    }

    /// Parses ONE status response out of the front of `buffer`:
    /// packetLength, packetID(0), jsonLength, JSON. Returns nil when the
    /// buffer does not hold the whole thing yet.
    static func parseStatusResponse(_ buffer: Data) -> Answer? {
        var cursor = ByteCursor(buffer)
        guard let packetLength = cursor.varint(), packetLength > 1,
              let packetID = cursor.varint(), packetID == 0,
              let jsonLength = cursor.varint(), jsonLength > 1,
              let json = cursor.bytes(jsonLength) else { return nil }

        guard let document = try? JSONSerialization.jsonObject(with: json),
              let dict = document as? [String: Any] else { return nil }

        let players = dict["players"] as? [String: Any]
        return Answer(
            playersOnline: (players?["online"] as? NSNumber)?.intValue,
            playersMax: (players?["max"] as? NSNumber)?.intValue,
            versionLabel: (dict["version"] as? [String: Any])?["name"] as? String,
            motd: motdText(dict["description"])
        )
    }
    /// ("{"text":"…"}" possibly nested). Take the first usable text.
    private static func motdText(_ description: Any?) -> String? {
        if let text = description as? String, !text.isEmpty { return text }
        if let dict = description as? [String: Any],
           let text = dict["text"] as? String, !text.isEmpty {
            return text
        }
        if let extra = (description as? [String: Any])?["extra"] as? [[String: Any]] {
            let joined = extra.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        return nil
    }
}

/// Resolves a CheckedContinuation exactly once, no matter how many paths
/// (success, failure, timeout) fire.
/// Positional reader over a Minecraft protocol byte stream. Reads return
/// nil (rather than trapping) whenever the stream is truncated — the SLP
/// receiver feeds it growing buffers until everything fits.
private struct ByteCursor {
    private let data: Data
    private var position: Int

    init(_ data: Data) {
        self.data = data
        self.position = data.startIndex
    }

    mutating func varint() -> Int? {
        var result = 0
        var shift = 0
        while position < data.endIndex {
            let byte = data[data.index(data.startIndex, offsetBy: position)]
            position += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 35 { return nil }
        }
        return nil
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, position + count <= data.endIndex else { return nil }
        let absoluteStart = start
        let absoluteEnd = data.index(absoluteStart, offsetBy: count)
        position += count
        return data[absoluteStart..<absoluteEnd]
    }

    private var start: Data.Index { data.index(data.startIndex, offsetBy: position) }
}

private final class OnceResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func resolve(_ continuation: CheckedContinuation<ServerStatus, Never>,
                 _ value: ServerStatus) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        continuation.resume(returning: value)
    }

    func tryResolve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }

    func once(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        body()
    }
}
