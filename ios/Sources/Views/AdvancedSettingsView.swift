import SwiftUI
import UniformTypeIdentifiers
import PixelClipKit

/// Settings ▸ Advanced: everything technical, in one place, so the rest of the app never needs it —
/// the clip's name and Wi‑Fi behaviour, the hotspot password, Bluetooth wake, firmware, the battery
/// log, the clip's raw status and (Debug builds) the virtual clip.
struct AdvancedSettingsView: View {
    @Environment(ClipSession.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(Sender.self) private var sender
    @State private var settings = AppSettings.shared
    @State private var name = ""
    @State private var pickFirmware = false
    @State private var revealPassword = false
    @State private var enteringPassword = false
    @State private var typedPassword = ""
    @State private var passwordProblem: String?
    @State private var batteryLog: String?
    @State private var loadingLog = false
    @State private var resettingIMU = false
    @FocusState private var nameFocused: Bool

    static let sleepLevels = [5, 8, 10, 15, 20]
    static let timeouts = [60, 120, 300, 600, 1800]

    private var reachable: Bool { session.isNearby }

    var body: some View {
        List {
            clipSection
            connectionSection
            Section {
                Button { resetCalibration() } label: {
                    HStack { Text("Reset the motion sensor"); Spacer(); if resettingIMU { ProgressView() } }
                }
                .disabled(resettingIMU)
            } header: { Text("Motion sensor") } footer: { Text("Back to the factory idea of which way is down.") }
            maintenanceSection
            aboutSection
            #if DEBUG
            debugSection
            #endif
        }
        .scrollContentBackground(.hidden)
        .z2Screen("Advanced")
        .onAppear { name = session.config?.name ?? "" }
        .onChange(of: session.config?.name) { _, new in if !nameFocused { name = new ?? "" } }
        .task { if !session.isConnected { await session.refreshOverBluetooth() } }
        .fileImporter(isPresented: $pickFirmware, allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { session.startFirmwareUpdate(data) }
        }
    }

    // MARK: The clip's own settings

    private var clipSection: some View {
        Section {
            LabeledContent("Name") {
                TextField("My clip", text: $name)
                    .multilineTextAlignment(.trailing)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await session.rename(name) } }
                    .accessibilityLabel("Clip name")
            }
            Toggle("Screen on while receiving", isOn: Binding(get: { session.config?.screenStaysOn ?? true },
                                                              set: { v in Task { await session.setScreenStaysOn(v) } }))
            Toggle("Wi‑Fi always on (half the wear time)", isOn: Binding(get: { session.config?.wifiAlwaysOn ?? false },
                                                                       set: { v in Task { await session.setAlwaysReachable(v) } }))
            Picker("Wi‑Fi turns off after", selection: Binding(get: { session.config?.uploadTimeoutS ?? 120 },
                                                               set: { v in Task { await session.setUploadTimeout(v) } })) {
                ForEach(Array(Set(Self.timeouts + [session.config?.uploadTimeoutS ?? 120])).sorted(), id: \.self) { s in
                    Text(s < 120 ? "\(s) s" : "\(s / 60) min").tag(s)
                }
            }
            .disabled(session.config?.wifiAlwaysOn == true)
            Picker("Sleep at battery level", selection: Binding(get: { session.config?.lowBatteryPct ?? 8 },
                                                                set: { v in Task { await session.setLowBatteryPct(v) } })) {
                ForEach(Array(Set(Self.sleepLevels + [session.config?.lowBatteryPct ?? 8])).sorted(), id: \.self) { p in Text("\(p)%").tag(p) }
            }
        } header: {
            Text("On the clip")
        } footer: {
            Text(reachable ? (session.notice ?? "Stored on the clip.") : "The clip isn’t near: these change once it is.")
        }
        .disabled(!reachable)
    }

    private var connectionSection: some View {
        Section {
            Toggle("Wake over Bluetooth", isOn: Binding(get: { settings.bluetoothWake },
                                                        set: { v in Task { await session.setBluetoothWake(v) } }))
            if session.clipPasswordWasReset {
                VStack(alignment: .leading, spacing: 6) {
                    Text(SendProblem.clipPasswordReset.title).font(.subheadline.weight(.semibold))
                    Text(SendProblem.clipPasswordReset.message).font(.footnote).foregroundStyle(Z2.secondary)
                    Button("Set up again") { sender.setUpAgain() }
                        .accessibilityIdentifier("setUpPasswordAgain")
                }
                .padding(.vertical, 2)
            }
            passwordRows
            Button("Forget the clip’s Wi‑Fi") {
                Task {
                    await session.forgetClip()
                    router.flash("Forgot the clip’s Wi‑Fi", icon: "wifi.slash")
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            Text(passwordProblem ?? connectionFooter)
        }
    }

    /// The clip's own Wi‑Fi password: shown on request and copied (for a second iPhone), or typed in
    /// (one another iPhone set).
    @ViewBuilder
    private var passwordRows: some View {
        if let password = session.passwords.current {
            LabeledContent("Wi‑Fi password") {
                HStack(spacing: 14) {
                    Button { revealPassword.toggle() } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(revealPassword ? "Hide the Wi‑Fi password" : "Show the Wi‑Fi password")
                    .accessibilityIdentifier("revealPassword")
                    Button { copy(password) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy the Wi‑Fi password")
                        .accessibilityIdentifier("copyPassword")
                }
            }
            if revealPassword {
                Text(password)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("passwordText")
            }
        } else {
            LabeledContent("Wi‑Fi password", value: session.passwords.pending != nil ? "Being set up" : "Set up at the next Wi‑Fi send")
        }
        if enteringPassword {
            SecureField("Password from another iPhone", text: $typedPassword)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit(saveTypedPassword)
                .accessibilityIdentifier("typedPassword")
            HStack {
                Button("Save", action: saveTypedPassword).buttonStyle(.borderless)
                Spacer()
                Button("Cancel") { enteringPassword = false; typedPassword = ""; passwordProblem = nil }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Z2.secondary)
            }
        } else {
            Button("Enter a Wi‑Fi password…") { enteringPassword = true; passwordProblem = nil }
                .accessibilityIdentifier("enterPassword")
        }
    }

    private var connectionFooter: String {
        let forget = "Forgetting makes iPhone ask to join “\(HotspotDefaults.ssidPrefix)…” again and resets the clock record."
        if session.passwords.current != nil {
            return "Your clip has its own Wi‑Fi password, saved on this iPhone. To send from another iPhone, copy it here and enter it there. \(forget)"
        }
        return "The app gives your clip its own Wi‑Fi password the first time it sends over Wi‑Fi. \(forget)"
    }

    private func saveTypedPassword() {
        if let problem = session.setHotspotPasswordManually(typedPassword) {
            passwordProblem = problem
            return
        }
        passwordProblem = nil
        typedPassword = ""
        enteringPassword = false
        router.flash("Wi‑Fi password saved", icon: "lock.fill")
    }

    private func copy(_ password: String) {
        // Gone from the clipboard after two minutes (still there long enough to paste on another iPhone).
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: password]],
                                      options: [.expirationDate: Date().addingTimeInterval(120)])
        router.flash("Copied for two minutes", icon: "doc.on.doc")
    }

    // MARK: Firmware, logs, raw status

    private var maintenanceSection: some View {
        Section {
            firmwareRows
            Button {
                Task { await loadBatteryLog() }
            } label: {
                HStack { Text("Battery log"); Spacer(); if loadingLog { ProgressView() } }
            }
            if let batteryLog {
                ScrollView(.horizontal) {
                    Text(batteryLog.isEmpty ? "(empty)" : batteryLog).font(.caption.monospaced()).textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                Button("Reset the battery log", role: .destructive) {
                    Task {
                        if (try? await session.client.clearBatteryLog()) != nil { self.batteryLog = "" }
                    }
                }
            }
            NavigationLink {
                SendLogView()
            } label: {
                HStack { Text("Send log"); Spacer(); Text("\(SendLog.shared.lines.count)").foregroundStyle(Z2.secondary) }
            }
            .accessibilityIdentifier("sendLogLink")
            DisclosureGroup("The clip’s raw status") {
                Text(rawStatus).font(.caption2.monospaced()).textSelection(.enabled)
            }
        } header: {
            Text("Firmware and logs")
        } footer: {
            Text("Firmware files end in .bin. The clip asks for a press of its button first; keep the phone close until it restarts. The battery log needs the clip’s Wi‑Fi.")
        }
    }

    @ViewBuilder
    private var firmwareRows: some View {
        switch session.firmwareStep {
        case .idle:
            Button("Update firmware…") { pickFirmware = true }
        case .asking:
            HStack { Text("Asking the clip…"); Spacer(); ProgressView() }
        case .waitingForPress(let seconds):
            VStack(alignment: .leading, spacing: 6) {
                Text("Press the button on your clip to allow the update")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("firmwarePressButton")
                Text("\(seconds) s left").font(.footnote.monospacedDigit()).foregroundStyle(Z2.secondary)
                    .contentTransition(.numericText())
            }
            Button("Cancel", role: .cancel) { session.cancelFirmwareUpdate() }
                .accessibilityIdentifier("firmwareCancel")
        case .uploading(let p):
            VStack(alignment: .leading, spacing: 6) {
                Text("Sending the update… \(Int(p * 100))%")
                ProgressView(value: p)
            }
        case .installed:
            Text("Installed. The clip is restarting.")
            Button("Done") { session.resetFirmwareStep() }
        case .notPressed:
            Text("The button wasn’t pressed in time. Nothing was changed on the clip.")
            Button("Try again") { session.retryFirmwareUpdate() }
                .accessibilityIdentifier("firmwareTryAgain")
            Button("Not now", role: .cancel) { session.resetFirmwareStep() }
        case .failed:
            Text("The update didn’t go through. Nothing was changed on the clip.")
            Button("Done") { session.resetFirmwareStep() }
        }
    }

    private var rawStatus: String {
        guard let status = session.status else { return "Not heard yet." }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(status)).flatMap { String(data: $0, encoding: .utf8) } ?? "—"
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: settings.appVersion)
            LabeledContent("Firmware", value: session.status?.device.fw ?? settings.lastFirmware ?? "not heard yet")
            LabeledContent("Protocol", value: "version \(clipProtocolVersion)")
            VStack(alignment: .leading, spacing: 4) {
                Text("Tarot").font(.subheadline.weight(.semibold))
                Text(TarotCredits.deck).font(.footnote).foregroundStyle(.secondary)
                Text(TarotCredits.readings).font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tarotCredits")
        }
    }

    #if DEBUG
    private var debugSection: some View {
        @Bindable var session = session
        return Section {
            Toggle("Virtual clip", isOn: $session.useVirtual)
            if session.useVirtual {
                Toggle("Simulate Bluetooth unavailable", isOn: $session.simulateBluetoothUnavailable)
                Button("Add sample items") { Task { await DemoContent.addSamples(to: library) } }
                Button("Reset the virtual clip’s Wi‑Fi password") { Task { await session.resetVirtualClipPassword() } }
                Button("Reset the virtual clip", role: .destructive) { Task { await session.resetVirtualClip() } }
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Debug builds only. The virtual clip emulates the hardware in memory, so the app works with no clip nearby.")
        }
    }
    #endif

    // MARK: Actions

    private func loadBatteryLog() async {
        loadingLog = true
        defer { loadingLog = false }
        batteryLog = (try? await session.client.batteryLog()) ?? "Couldn’t read it. Is the clip near?"
    }

    private func resetCalibration() {
        resettingIMU = true
        Task {
            defer { resettingIMU = false }
            if !session.isConnected { guard await session.connect() else { return } }
            if await session.resetIMUCalibration() { router.flash("Motion sensor back to its factory setting", icon: "gyroscope") }
        }
    }
}

/// Settings ▸ Advanced ▸ Send log: every step of the last sends and Bluetooth looks, newest last.
struct SendLogView: View {
    @State private var log = SendLog.shared

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if log.lines.isEmpty {
                    Text("Nothing yet. Send something, or turn the playlist on or off.").foregroundStyle(Z2.secondary)
                }
                ForEach(log.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(SendLog.stamp(line.at)).font(.caption2.monospaced()).foregroundStyle(Z2.hint)
                        Text(line.text).font(.caption.monospaced()).foregroundStyle(Z2.text).textSelection(.enabled)
                    }
                    .id(line.id)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .onAppear { if let last = log.lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
        .scrollContentBackground(.hidden)
        .background(Z2.sheet.ignoresSafeArea())
        .navigationTitle("Send log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: log.text) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share the send log")
                Button("Clear", role: .destructive) { log.clear() }
            }
        }
    }
}
