import SwiftUI
import PixelClipKit

/// Settings (docs/DESIGN.md ▸ Settings), one screen: the clip, and "If something's off" (help, the
/// calibration wizard, and everything technical under Advanced).
struct SettingsView: View {
    @Environment(ClipSession.self) private var session
    @Environment(Router.self) private var router
    @State private var showCalibration = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                clipSection
                helpSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .z2Screen("Settings")
        // Not on its Wi‑Fi: read the clip's settings over Bluetooth (no hotspot).
        .task { if !session.isConnected { await session.refreshOverBluetooth() } }
        .sheet(isPresented: $showCalibration) { CalibrationSheet() }
        .onAppear {
            #if DEBUG
            if DemoContent.consume("calibrate") { showCalibration = true }
            #endif
        }
    }

    // MARK: Clip

    /// Heard nearby (or on its Wi‑Fi): the clip's settings can change; each change links over Bluetooth first.
    private var reachable: Bool { session.isNearby }

    /// Links over the Bluetooth fast lane if nothing is open, then applies `change`.
    private func onClip(_ change: @escaping @MainActor () async -> Void) {
        Task {
            if !session.isConnected && !session.fastLaneReady {
                guard await session.openFastLane() else { return }
                await session.refreshOverBluetooth()
            }
            await change()
        }
    }

    private var clipSection: some View {
        @Bindable var session = session
        let mode = session.config?.orientation ?? .auto
        return VStack(alignment: .leading, spacing: 8) {
            Z2SectionLabel(text: "Clip")
            VStack(spacing: 0) {
                Z2Row(title: "Brightness") {
                    Slider(value: $session.brightness, in: 8...255) { editing in
                        if !editing { onClip { await session.commitBrightness() } }
                    }
                    .frame(maxWidth: 170)
                    .onChange(of: session.brightness) { onClip { await session.previewBrightness() } }
                    .accessibilityLabel("Brightness")
                    .accessibilityValue("\(Int(session.brightness / 255 * 100)) percent")
                }
                .disabled(!reachable)
                Z2Divider()
                Z2Row(title: "Auto-rotate", detail: "Flips when worn the other way up") {
                    Toggle("Auto-rotate", isOn: Binding(get: { mode == .auto }, set: { on in
                        onClip { await session.setOrientation(on ? .auto : session.isScreenFlipped ? .flipped : .normal) }
                    }))
                    .labelsHidden().tint(Color.accentColor)
                    .accessibilityIdentifier("autoRotateToggle")
                }
                .disabled(!reachable)
                if mode != .auto {
                    Z2Divider()
                    Z2Row(title: "Upside down") {
                        Toggle("Upside down", isOn: Binding(get: { mode == .flipped }, set: { v in
                            onClip { await session.setOrientation(v ? .flipped : .normal) }
                        }))
                        .labelsHidden().tint(Color.accentColor)
                    }
                    .disabled(!reachable)
                }
                Z2Divider()
                Z2Row(title: "Battery") {
                    Text(session.batteryLine ?? "not heard yet").font(.subheadline).foregroundStyle(Z2.secondary)
                }
            }
            .background(Z2.card, in: .rect(cornerRadius: 18, style: .continuous))
            .animation(Z2.spring, value: mode)
            if !reachable {
                Text("Brightness and rotation change when the clip is near.")
                    .font(.footnote).foregroundStyle(Z2.hint).padding(.horizontal, 4)
            }
        }
    }

    // MARK: If something's off

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Z2SectionLabel(text: "If something’s off")
            VStack(spacing: 0) {
                link("Can’t find the clip?", "›") { router.cantFind = true }
                    .accessibilityIdentifier("cantFindRow")
                Z2Divider()
                link("Sand falls the wrong way", "Calibrate ›") { showCalibration = true }
                    .accessibilityIdentifier("calibrateRow")
                Z2Divider()
                link("Advanced", "firmware, logs ›") { router.open(.advanced) }
                    .accessibilityIdentifier("advancedRow")
            }
            .background(Z2.card, in: .rect(cornerRadius: 18, style: .continuous))
        }
    }

    private func link(_ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Z2Row(title: title) { Text(detail).font(.subheadline).foregroundStyle(Z2.secondary) }
                .contentShape(.rect)
        }
        .buttonStyle(Z2Press(scale: 0.99))
    }
}
