import Foundation
import Observation
import Security

// The clip's own hotspot passphrase (SECURITY-AUDIT WIFI-1, WIFI-2, IOS-8). A clip leaves the factory with
// the published `HotspotDefaults.password`; after the first join over Wi‑Fi the app gives it a random one of
// its own, once, without asking anything (`HotspotPasswords.setUpIfNeeded`), and keeps it in the Keychain.

/// The values the app keeps about the clip's passphrase.
public enum HotspotPasswordSlot: String, CaseIterable, Sendable {
    /// The clip's passphrase as this iPhone knows it (absent: the factory one).
    case current
    /// A new passphrase written before the clip is told, promoted to `current` once the clip took it.
    case pending
    /// The passphrase the remembered `PixelClip-…` network was installed with (so a change installs it again).
    case remembered
}

public enum HotspotPasswordStoreError: Error, Equatable, Sendable {
    case keychain(Int32)
    case unavailable
}

/// Where the passphrases live: the Keychain on the phone, memory for tests and the virtual clip.
public protocol HotspotPasswordStoring: AnyObject, Sendable {
    func read(_ slot: HotspotPasswordSlot) throws -> String?
    /// Nil removes the value.
    func write(_ value: String?, to slot: HotspotPasswordSlot) throws
}

/// Generic passwords in this app's own Keychain: readable after the first unlock (a send may run while the
/// phone is locked), never synchronised to other devices, no access group (the Share Extension has no access).
public final class KeychainHotspotPasswordStore: HotspotPasswordStoring {
    public let service: String

    public init(service: String = "pixelclip.hotspot") { self.service = service }

    private func query(_ slot: HotspotPasswordSlot) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    public func read(_ slot: HotspotPasswordSlot) throws -> String? {
        var q = query(slot)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw HotspotPasswordStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?, to slot: HotspotPasswordSlot) throws {
        guard let value else {
            let status = SecItemDelete(query(slot) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw HotspotPasswordStoreError.keychain(status) }
            return
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        var status = SecItemUpdate(query(slot) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(slot)
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HotspotPasswordStoreError.keychain(status) }
    }
}

/// In memory: tests, and the virtual clip (which starts from the factory passphrase at every launch).
public final class InMemoryHotspotPasswordStore: HotspotPasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HotspotPasswordSlot: String]
    private var failing: Set<HotspotPasswordSlot> = []

    public init(_ values: [HotspotPasswordSlot: String] = [:]) { self.values = values }

    /// Tests: writes to these slots fail (a Keychain that refuses).
    public func failWrites(to slots: Set<HotspotPasswordSlot>) { lock.withLock { failing = slots } }

    public func read(_ slot: HotspotPasswordSlot) throws -> String? { lock.withLock { values[slot] } }

    public func write(_ value: String?, to slot: HotspotPasswordSlot) throws {
        try lock.withLock {
            if failing.contains(slot) { throw HotspotPasswordStoreError.unavailable }
            values[slot] = value
        }
    }
}

/// Random passphrases for the clip: 24 characters from an alphabet without look-alikes (no 0 O 1 l I),
/// about 140 bits, from the system's cryptographically secure generator. Always valid for the clip
/// (8 to 63 printable ASCII).
public enum HotspotPasswordGenerator {
    public static let alphabet: [Character] = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
    public static let length = 24

    public static func generate(length: Int = HotspotPasswordGenerator.length) -> String {
        let n = alphabet.count
        // Rejection sampling: only bytes below the largest multiple of n, so every character is equally likely.
        let limit = 256 - 256 % n
        var out: [Character] = []
        out.reserveCapacity(length)
        while out.count < length {
            var bytes = [UInt8](repeating: 0, count: 2 * length)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
            for b in bytes where Int(b) < limit && out.count < length {
                out.append(alphabet[Int(b) % n])
            }
        }
        return String(out)
    }
}

/// The app's view of the clip's passphrase: what to join with, the automatic first setup, manual entry.
@MainActor @Observable
public final class HotspotPasswords {
    /// The clip's own passphrase as this iPhone knows it (nil: the factory one).
    public private(set) var current: String?
    /// Written before the clip was told; promoted after the clip confirmed (or after a join with it).
    public private(set) var pending: String?
    /// The passphrase the remembered network was installed with.
    public private(set) var remembered: String?
    public private(set) var isSettingUp = false

    @ObservationIgnored public let store: any HotspotPasswordStoring
    @ObservationIgnored private let generate: @MainActor () -> String

    public init(store: any HotspotPasswordStoring, generate: @escaping @MainActor () -> String = { HotspotPasswordGenerator.generate() }) {
        self.store = store
        self.generate = generate
        current = (try? store.read(.current)) ?? nil
        pending = (try? store.read(.pending)) ?? nil
        remembered = (try? store.read(.remembered)) ?? nil
    }

    // MARK: Choosing

    /// What the next join uses, from what this iPhone holds and what the clip last said about
    /// `ap_password_set` (nil: not known, e.g. Bluetooth off, or firmware without the flag).
    ///
    /// - `current` set: it, unless the clip says it has the factory passphrase again: then nothing (the
    ///   person chooses "Set up again"; never a silent fall back to the published passphrase).
    /// - only `pending`: it when the clip says set; the factory one when the clip says not set (the setup
    ///   runs again); both, `pending` first, when unknown.
    /// - neither: the factory one, unless the clip says it has its own (then the person must enter it).
    public static func plan(current: String?, pending: String?, clipReportsSet: Bool?) -> HotspotPasswordPlan {
        let factory = HotspotDefaults.password
        if let current {
            return clipReportsSet == false ? .blocked(.clipWasReset) : .join([current])
        }
        if let pending {
            switch clipReportsSet {
            case true?: return .join([pending])
            case false?: return .join([factory])
            case nil: return .join([pending, factory])
            }
        }
        return clipReportsSet == true ? .blocked(.passwordUnknown) : .join([factory])
    }

    public func plan(clipReportsSet: Bool?) -> HotspotPasswordPlan {
        Self.plan(current: current, pending: pending, clipReportsSet: clipReportsSet)
    }

    /// The passphrase joins use when the clip doesn't say otherwise.
    public var effective: String { current ?? HotspotDefaults.password }

    // MARK: Changes

    /// Builds before the Keychain kept the passphrase in UserDefaults: a non-default one becomes `current`
    /// (once; an existing `current` wins). True when the old copy can be removed.
    @discardableResult
    public func migrate(legacy: String?) -> Bool {
        guard let legacy, !legacy.isEmpty, legacy != HotspotDefaults.password, current == nil else { return true }
        do {
            try store.write(legacy, to: .current)
            current = legacy
            return true
        } catch {
            current = legacy   // for this launch; the old copy stays until the Keychain takes it
            return false
        }
    }

    /// After a join that went through with `passphrase`: a pending one is now known to work.
    /// True when it was promoted.
    @discardableResult
    public func didJoin(with passphrase: String?) -> Bool {
        guard current == nil, let passphrase, let pending, passphrase == pending else { return false }
        return promote()
    }

    public enum SetupResult: Equatable, Sendable {
        /// The clip already has its own passphrase, this iPhone holds one, or the clip didn't say.
        case notNeeded
        /// The clip took the new passphrase (it applies from its next Wi‑Fi session).
        case done
        /// The Keychain didn't take it: the clip was not changed.
        case storeFailed
        /// The clip didn't confirm: the passphrase stays pending for the next connection.
        case clipFailed
    }

    /// The automatic first setup, on the clip's Wi‑Fi only: when this iPhone uses the factory passphrase
    /// and the clip says it has it (`clipReportsSet == false`), a new random one is saved as pending,
    /// `send` gives it to the clip (`PUT /config {"ap_password"}` over HTTP), and it becomes current.
    /// Never when the clip didn't say (older firmware), and never over a passphrase the person entered.
    public func setUpIfNeeded(clipReportsSet: Bool?, send: (String) async throws -> Void) async -> SetupResult {
        guard current == nil, clipReportsSet == false, !isSettingUp else { return .notNeeded }
        isSettingUp = true
        defer { isSettingUp = false }
        let password: String
        if let pending {
            password = pending   // an earlier attempt the clip may not have heard
        } else {
            password = generate()
            do { try store.write(password, to: .pending) } catch { return .storeFailed }
            pending = password
        }
        do { try await send(password) } catch { return .clipFailed }
        promote()
        return .done
    }

    /// Settings ▸ Advanced: a passphrase the person typed (one another phone set, say). Kept as is and
    /// never replaced automatically; empty or the factory one goes back to the factory default.
    /// Returns why it can't be used (nil: saved).
    @discardableResult
    public func setManually(_ text: String) -> String? {
        if text.isEmpty || text == HotspotDefaults.password {
            clear()
            return nil
        }
        if let problem = ClipConfig(apPassword: text).validationProblem { return problem }
        do {
            try store.write(text, to: .current)
            try? store.write(nil, to: .pending)
        } catch {
            return "This iPhone couldn’t save it. Try again."
        }
        current = text
        pending = nil
        return nil
    }

    /// "Set up again": forget the clip's passphrase on this iPhone (the next join uses the factory one
    /// and the setup runs again).
    public func clear() {
        try? store.write(nil, to: .current)
        try? store.write(nil, to: .pending)
        current = nil
        pending = nil
    }

    /// The remembered network was installed with `passphrase` (nil: removed).
    public func setRemembered(_ passphrase: String?) {
        try? store.write(passphrase, to: .remembered)
        remembered = passphrase
    }

    @discardableResult
    private func promote() -> Bool {
        guard let pending else { return false }
        do { try store.write(pending, to: .current) } catch { return false }   // stays pending: still tried next time
        try? store.write(nil, to: .pending)
        current = pending
        self.pending = nil
        return true
    }
}
