import Foundation

// The BLE fast lane's framing (PROTOCOL §3b, firmware/README.md "BLE fast lane"): the same rules as
// `firmware/components/ble/pixelclip_frame.c` and `firmware/scripts/ble_api.py` (whose golden vectors the
// tests replay). Pure Swift: no CoreBluetooth.
//
// A message is cut into frames of at most ATT_MTU−3 bytes. Byte 0 of each frame is a header:
// bit 7 = first, bit 6 = last, bits 0–5 = sequence number (from 0, +1 per frame, mod 64); the rest is
// message bytes. A one-frame message has both bits set; an empty message is the single byte 0xC0.

/// Why a frame was refused while reassembling.
public enum BLEFrameError: Error, Equatable, Sendable {
    case emptyFrame
    /// A continuation frame with no message open (e.g. the tail of a response the app gave up on).
    case strayContinuation(header: UInt8)
    case sequenceGap(got: Int, expected: Int)
    /// More bytes than the reassembly buffer takes.
    case tooLarge(Int)
}

public enum BLEFrameCodec {
    /// Splits a message into frames of at most `maxFrame` bytes (header + data). `maxFrame` < 2 is
    /// treated as 2 (one data byte per frame).
    public static func frames(_ payload: Data, maxFrame: Int) -> [Data] {
        let room = max(2, maxFrame) - 1
        let bytes = [UInt8](payload)
        var out: [Data] = []
        out.reserveCapacity(bytes.count / room + 1)
        var offset = 0
        var seq: UInt8 = 0
        while true {
            let end = min(offset + room, bytes.count)
            var header = seq & PixelClipBLE.frameSequenceMask
            if offset == 0 { header |= PixelClipBLE.frameFirst }
            if end >= bytes.count { header |= PixelClipBLE.frameLast }
            var frame = Data(capacity: 1 + end - offset)
            frame.append(header)
            frame.append(contentsOf: bytes[offset..<end])
            out.append(frame)
            offset = end
            seq = (seq &+ 1) & PixelClipBLE.frameSequenceMask
            if header & PixelClipBLE.frameLast != 0 { return out }
        }
    }
}

/// The receiving side: feed frames in arrival order, get the message back after its last frame.
/// A first frame always starts over (the sender gave up on the previous message); a gap closes the
/// message (frames are then refused until the next first frame).
public struct BLEFrameReassembler: Sendable {
    public private(set) var isOpen = false
    public let maxBytes: Int
    private var buffer = Data()
    private var nextSeq: UInt8 = 0

    /// - Parameter maxBytes: the largest message accepted (default: the 16 KB body plus room for the
    ///   request or status line, like the firmware's buffer).
    public init(maxBytes: Int = PixelClipBLE.apiMaxBytes + 512) { self.maxBytes = maxBytes }

    /// The complete message after its last frame, nil while more frames are expected.
    public mutating func push(_ frame: Data) throws -> Data? {
        guard let header = frame.first else { throw BLEFrameError.emptyFrame }
        let seq = header & PixelClipBLE.frameSequenceMask
        if header & PixelClipBLE.frameFirst != 0 {
            buffer = Data()
            isOpen = true
        } else if !isOpen {
            throw BLEFrameError.strayContinuation(header: header)
        } else if seq != nextSeq {
            isOpen = false
            throw BLEFrameError.sequenceGap(got: Int(seq), expected: Int(nextSeq))
        }
        nextSeq = (seq &+ 1) & PixelClipBLE.frameSequenceMask
        guard buffer.count + frame.count - 1 <= maxBytes else {
            isOpen = false
            throw BLEFrameError.tooLarge(buffer.count + frame.count - 1)
        }
        buffer.append(frame.dropFirst())
        guard header & PixelClipBLE.frameLast != 0 else { return nil }
        isOpen = false
        defer { buffer = Data() }
        return buffer
    }

    /// Drop anything half-received (after a timeout).
    public mutating func reset() {
        buffer = Data()
        isOpen = false
        nextSeq = 0
    }
}

// MARK: - Messages

/// A fast-lane request: `METHOD SP path LF [body]` in UTF-8, e.g. `POST /brightness\n{"value":200}`.
public struct FastLaneRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var body: Data

    public init(_ method: String, _ path: String, body: Data = Data()) {
        self.method = method.uppercased(); self.path = path; self.body = body
    }

    public var route: FastLaneRoute { FastLaneRoute(method, path) }

    public var encoded: Data {
        var d = Data("\(method) \(path)\n".utf8)
        d.append(body)
        return d
    }

    /// The clip's side (the virtual clip): parses a reassembled request. A missing LF means no body
    /// (`GET /status`), a CR before the LF is tolerated, as on the firmware.
    public init?(decoding message: Data) {
        let bytes = [UInt8](message)
        let lf = bytes.firstIndex(of: 0x0A) ?? bytes.count
        var lineBytes = Array(bytes[..<lf])
        if lineBytes.last == 0x0D { lineBytes.removeLast() }
        guard let line = String(bytes: lineBytes, encoding: .utf8) else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].hasPrefix("/"), parts[1].utf8.count <= 255 else { return nil }
        method = String(parts[0]).uppercased()
        path = String(parts[1])
        body = lf < bytes.count ? Data(bytes[(lf + 1)...]) : Data()
    }
}

/// A fast-lane response: `STATUS SP LF [body]`, e.g. `200 \n{"ok":true}`. The body is exactly the
/// HTTP response body.
public struct FastLaneResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) { self.status = status; self.body = body }

    public var encoded: Data {
        var d = Data(String(format: "%03d \n", status).utf8)
        d.append(body)
        return d
    }

    /// Splits at the first LF: status, body.
    public init(decoding message: Data) throws {
        let bytes = [UInt8](message)
        guard let lf = bytes.firstIndex(of: 0x0A) else { throw ClipError.badResponse("no LF in the Bluetooth response") }
        let head = String(decoding: bytes[..<lf], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let status = head.isEmpty ? 0 : Int(head) else { throw ClipError.badResponse("bad status “\(head)” over Bluetooth") }
        self.status = status
        body = Data(bytes[(lf + 1)...])
    }
}

/// Where a request may go (PROTOCOL §3b): everything except the bulk transfers, which the clip
/// answers `413 use_wifi` over Bluetooth.
public struct FastLaneRoute: Sendable, Hashable {
    public var method: String
    public var path: String

    public init(_ method: String, _ path: String) { self.method = method.uppercased(); self.path = path }

    /// `PUT /assets/{id}`, `PUT /texts/{id}`, `POST /ota`, `GET /screenshot`, `GET /assets/{id}`, `GET /batlog`.
    public var isBulk: Bool {
        let p = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        switch method {
        case "PUT": return p.hasPrefix("/assets/") || p.hasPrefix("/texts/")
        case "POST": return p == "/ota"
        case "GET": return p == "/screenshot" || p.hasPrefix("/assets/") || p == "/batlog"
        default: return false
        }
    }

    /// Small, but only over the clip's Wi‑Fi: `POST /ota/ask` (the firmware answers `413 use_wifi` over Bluetooth).
    public var isWiFiOnly: Bool {
        let p = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return method == "POST" && p == "/ota/ask"
    }

    public var isEligible: Bool { !isBulk && !isWiFiOnly }

    /// Safe to send again over Wi‑Fi when a Bluetooth exchange broke off midway (the clip may have
    /// run it): everything but stepping the playlist, capturing a calibration pose and the oracle's
    /// draw and turn (a second one would draw again or skip a page).
    public var isIdempotent: Bool {
        method != "POST" || !["/next", "/prev", "/imu/calibrate", "/oracle/draw", "/oracle/turn", "/oracle/back"].contains(path)
    }

    /// "PUT /playlist".
    public var line: String { "\(method) \(path)" }
}
