import Foundation

/// The clip's Bluetooth LE "doorbell" (PROTOCOL §3, firmware/README.md "BLE doorbell"). Every UUID
/// and byte layout here is copied from `firmware/components/ble/include/pixelclip_ble_uuids.h`; keep the
/// two in step (this is the only file in the app that knows them). `PixelClipBLETests` pins the values.
///
/// The clip advertises the service UUID in its advertising packet and its `PixelClip-XXXX` name in the
/// scan response; connectable, no pairing.
public enum PixelClipBLE {
    /// `PIXELCLIP_BLE_SERVICE_UUID`.
    public static let serviceUUID = "737B9B00-A500-43FC-B410-86AC8852E678"
    /// `PIXELCLIP_BLE_CHR_WAKE_UUID`: write (with response), exactly one byte.
    public static let wakeCharacteristicUUID = "737B9B01-A500-43FC-B410-86AC8852E678"
    /// `PIXELCLIP_BLE_CHR_STATUS_UUID`: read + notify, the packed `PixelClipBLEStatus`.
    public static let statusCharacteristicUUID = "737B9B02-A500-43FC-B410-86AC8852E678"
    /// `PIXELCLIP_BLE_CHR_INFO_UUID`: read, `"<device id>;<fw version>"`.
    public static let infoCharacteristicUUID = "737B9B03-A500-43FC-B410-86AC8852E678"
    /// `PIXELCLIP_BLE_CHR_REQ_UUID`: write without response, fast-lane request frames (PROTOCOL §3b).
    public static let requestCharacteristicUUID = "737B9B04-A500-43FC-B410-86AC8852E678"
    /// `PIXELCLIP_BLE_CHR_RSP_UUID`: notify, fast-lane response frames.
    public static let responseCharacteristicUUID = "737B9B05-A500-43FC-B410-86AC8852E678"

    // Fast lane framing (`BLEFrameCodec`).
    /// `PIXELCLIP_BLE_FRAME_FIRST`: header bit 7, the first frame of a message.
    public static let frameFirst: UInt8 = 0x80
    /// `PIXELCLIP_BLE_FRAME_LAST`: header bit 6, the last frame of a message.
    public static let frameLast: UInt8 = 0x40
    /// `PIXELCLIP_BLE_FRAME_SEQ_MASK`: header bits 0–5, the sequence number (mod 64, from 0).
    public static let frameSequenceMask: UInt8 = 0x3F
    /// `PIXELCLIP_BLE_API_MAX_BYTES`: max body per fast-lane request and per response.
    public static let apiMaxBytes = 16384
    /// `PIXELCLIP_BLE_PREFERRED_MTU`: the clip's preferred ATT MTU (iOS negotiates up to ~512).
    public static let preferredMTU = 517

    /// Advertised local name prefix (`PixelClip-` + the SSID's suffix).
    public static let namePrefix = "PixelClip-"

    /// `PIXELCLIP_BLE_CMD_WAKE`: start upload mode exactly like a long press (during a session: resets
    /// its idle timer).
    public static let wakeCommand: UInt8 = 0x01
    /// `PIXELCLIP_BLE_CMD_END`: end the session (also suspends `wifi_always_on` until reboot).
    public static let endCommand: UInt8 = 0x02

    /// `PIXELCLIP_BLE_ATT_ERR_LOW_BATTERY`: the ATT error a refused wake returns (battery below the Wi‑Fi
    /// floor, no USB). Other refusals use the standard codes (0x0D, 0x13).
    public static let attErrorLowBattery = 0x80

    /// Upload mode needs at least this (the firmware refuses below it unless on USB).
    public static let wakeCutoffMv = ClipStatus.Battery.uploadCutoffMv

    /// A peripheral is a PixelClip when it advertises the service, or (service missing from what was
    /// heard) its name starts with `PixelClip-`.
    public static func matches(name: String?, serviceUUIDs: [String]) -> Bool {
        if serviceUUIDs.contains(where: { $0.caseInsensitiveCompare(serviceUUID) == .orderedSame }) { return true }
        return name?.hasPrefix(namePrefix) ?? false
    }
}

/// What's on the clip's screen, as the `status` characteristic reports it (`PIXELCLIP_BLE_KIND_*`).
public enum PixelClipBLEItemKind: UInt8, Sendable, Equatable {
    /// Idle screen / nothing.
    case none = 0
    /// Image, animation or strip.
    case asset = 1
    // 2 is unused.
    case scene = 3
    case reader = 4
}

/// Result of the last `wake` write (`PIXELCLIP_BLE_RESULT_*`).
public enum PixelClipBLEWakeResult: UInt8, Sendable, Equatable {
    /// No write since boot.
    case none = 0
    case accepted = 1
    /// Refused: battery below the Wi‑Fi floor.
    case lowBattery = 2
    /// Refused: not one byte, or not 0x01 / 0x02.
    case invalid = 3
}

/// The `status` characteristic: `PIXELCLIP_BLE_STATUS_LEN` (7) bytes, little-endian.
///
/// | offset | size | field |
/// |---|---|---|
/// | 0 | u16 | battery mV (0 = unknown) |
/// | 2 | u8 | battery % (0–100) |
/// | 3 | u8 | flags (`Flags`) |
/// | 4 | u8 | current item kind (`PixelClipBLEItemKind`) |
/// | 5 | u8 | HTTP protocol version (as `/status` `device.protocol`) |
/// | 6 | u8 | result of the last `wake` write (`PixelClipBLEWakeResult`) |
///
/// Longer values are accepted (the firmware may append fields). Notified on change while
/// subscribed (checked every 2 s, and at once after a `wake` write and at session start/end).
public struct PixelClipBLEStatus: Equatable, Sendable {
    /// `PIXELCLIP_BLE_STATUS_LEN`.
    public static let byteCount = 7
    /// The fields up to the protocol byte; the wake result is read when present.
    static let minimumByteCount = 6

    /// `PIXELCLIP_BLE_FLAG_*`.
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// SoftAP + HTTP API up.
        public static let sessionActive = Flags(rawValue: 0x01)
        public static let usbPresent = Flags(rawValue: 0x02)
        /// `time.synced`.
        public static let clockOK = Flags(rawValue: 0x04)
        /// The panel is on and shows a playlist item (not the idle screen).
        public static let playing = Flags(rawValue: 0x08)
        /// Below the Wi‑Fi floor: a wake would be refused right now.
        public static let lowBattery = Flags(rawValue: 0x10)
        /// `wifi_always_on` is in effect.
        public static let alwaysOn = Flags(rawValue: 0x20)
    }

    public var millivolts: Int
    public var percent: Int
    public var flags: Flags
    /// Raw kind byte (unknown values from newer firmware are kept, `itemKind` is then nil).
    public var itemKindRaw: UInt8
    public var protocolVersion: Int
    /// Raw last-wake-result byte (0 when the value was too short to carry it).
    public var lastWakeRaw: UInt8

    public init(millivolts: Int, percent: Int, flags: Flags, itemKind: PixelClipBLEItemKind,
                protocolVersion: Int = clipProtocolVersion, lastWake: PixelClipBLEWakeResult = .none) {
        self.millivolts = millivolts; self.percent = percent; self.flags = flags
        self.itemKindRaw = itemKind.rawValue; self.protocolVersion = protocolVersion; self.lastWakeRaw = lastWake.rawValue
    }

    /// Decodes the characteristic value; nil when it's too short.
    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= Self.minimumByteCount else { return nil }
        millivolts = Int(b[0]) | Int(b[1]) << 8
        percent = min(Int(b[2]), 100)
        flags = Flags(rawValue: b[3])
        itemKindRaw = b[4]
        protocolVersion = Int(b[5])
        lastWakeRaw = b.count > 6 ? b[6] : 0
    }

    public var data: Data {
        Data([UInt8(millivolts & 0xFF), UInt8(millivolts >> 8 & 0xFF), UInt8(min(max(percent, 0), 100)),
              flags.rawValue, itemKindRaw, UInt8(min(max(protocolVersion, 0), 255)), lastWakeRaw])
    }

    public var itemKind: PixelClipBLEItemKind? { PixelClipBLEItemKind(rawValue: itemKindRaw) }
    public var lastWake: PixelClipBLEWakeResult? { PixelClipBLEWakeResult(rawValue: lastWakeRaw) }
    public var sessionActive: Bool { flags.contains(.sessionActive) }
    public var usbPresent: Bool { flags.contains(.usbPresent) }
    public var clockOK: Bool { flags.contains(.clockOK) }
    public var playing: Bool { flags.contains(.playing) }
    public var alwaysOn: Bool { flags.contains(.alwaysOn) }
    /// 0 mV = unknown.
    public var millivoltsKnown: Bool { millivolts > 0 }

    /// Too low to start Wi‑Fi: the firmware's own flag, or (older values) the voltage off USB.
    public var tooLowToWake: Bool {
        flags.contains(.lowBattery) || (!usbPresent && millivoltsKnown && millivolts < PixelClipBLE.wakeCutoffMv)
    }

    /// The same reading in `/status` terms, for `BatteryReading`.
    public var battery: ClipStatus.Battery {
        ClipStatus.Battery(mv: millivoltsKnown ? millivolts : nil, pct: percent, charging: usbPresent, usbPresent: usbPresent)
    }
}

/// The `info` characteristic: ASCII `"<device id>;<fw version>"`, e.g. `"3f2a;0.1.0"` (device id =
/// the lower-case hex suffix of the SSID, as `/status` `device.id`). More `;`-separated fields may follow.
public struct PixelClipBLEInfo: Equatable, Sendable {
    public var deviceID: String
    public var firmware: String

    public init(deviceID: String, firmware: String) { self.deviceID = deviceID; self.firmware = firmware }

    public init?(data: Data) {
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)),
              !s.isEmpty else { return nil }
        let parts = s.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        deviceID = parts[0]; firmware = parts[1]
    }

    public var data: Data { Data("\(deviceID);\(firmware)".utf8) }
}
