import SwiftUI
import UIKit

/// What the share sheet is about to save (filled from the host app's items).
@MainActor @Observable
final class ShareModel {
    enum Phase: Equatable { case loading, ready, saving, saved, failed(String) }

    /// A photo, GIF or video (a copy in the extension's temporary folder): it goes to Send.
    struct Media: Equatable {
        var url: URL
        var isVideo: Bool
    }

    var phase: Phase = .loading
    var media: Media?
    var title = ""
    var text: String?
    var url: URL?
    var html: String?
    /// Words-per-minute used for the estimate (the app's setting isn't visible here: the default).
    var wpm = 300

    init() {}

    init(title: String, text: String?, url: URL?) {
        self.title = title; self.text = text; self.url = url
        phase = .ready
    }

    var words: Int { text.map(ReaderInbox.roughWordCount) ?? 0 }

    var detail: String {
        var parts: [String] = []
        if words > 0 {
            parts.append("≈ \(words.formatted()) word\(words == 1 ? "" : "s")")
            parts.append("\(max(1, Int((Double(words) / Double(wpm)).rounded()))) min at \(wpm) wpm")
        } else if url != nil {
            parts.append("The article is fetched when PixelClip opens")
        }
        return parts.joined(separator: " · ")
    }

    var canSave: Bool { phase == .ready && (media != nil || words > 0 || url != nil) }

    var item: ReaderInboxItem {
        ReaderInboxItem(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title, text: text, url: url, html: html)
    }
}

/// The Share Extension's sheet. A photo or video: its thumbnail and "Send to PixelClip" (it opens in Send's
/// crop screen next time PixelClip is opened). A text or link: title, word count and "Read on PixelClip" (it opens
/// in the Reader extra). Also shown by the app's `-PixelClipScreen share` debug harness for screenshots.
struct ShareSheetView: View {
    @Bindable var model: ShareModel
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let media = model.media {
                    mediaBody(media)
                } else {
                    textBody
                }
            }
            .padding(20)
            .navigationTitle("PixelClip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            }
        }
        .tint(Color.shareAccent)
    }

    @ViewBuilder private func mediaBody(_ media: ShareModel.Media) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black)
                if !media.isVideo, let image = UIImage(contentsOfFile: media.url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(Color.shareAccentOnBlack)
                }
            }
            .aspectRatio(536.0 / 240.0, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .accessibilityLabel(media.isVideo ? "The shared video" : "The shared photo")
            Spacer(minLength: 0)
            saveButton(title: "Send to PixelClip", systemImage: "paperplane.fill")
            Text("Open PixelClip: it’s waiting in Send, ready to fit into the clip’s frame.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    private var textBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black)
                    HStack(spacing: 0) {
                        Text("lec").foregroundStyle(.white)
                        Text("t").foregroundStyle(Color.shareAccentOnBlack)
                        Text("ure").foregroundStyle(.white)
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .frame(width: 64, height: 40)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title", text: $model.title, axis: .vertical)
                        .font(.headline)
                        .lineLimit(1...3)
                    if let host = model.url?.host() {
                        Text(host).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if model.phase == .loading {
                HStack(spacing: 8) { ProgressView(); Text("Reading what you shared…").foregroundStyle(.secondary) }
                    .font(.subheadline)
            } else if !model.detail.isEmpty {
                Label(model.detail, systemImage: "text.word.spacing")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            saveButton(title: "Read on PixelClip", systemImage: "text.book.closed.fill")
            Text("Open PixelClip: it’s waiting in the Reader, to read on your clip one word at a time.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    private func saveButton(title: String, systemImage: String) -> some View {
        Button(action: onSave) {
            Group {
                if model.phase == .saved {
                    Label("Saved", systemImage: "checkmark")
                } else {
                    Label(title, systemImage: systemImage)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.shareAccent)
        .foregroundStyle(Color.shareOnAccent)
        .controlSize(.large)
        .disabled(!model.canSave)
    }
}

extension Color {
    /// The brand violet: #C6A2FF in dark mode, #8445CE in light mode (as the app's AccentColor).
    static let shareAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0xC6 / 255, green: 0xA2 / 255, blue: 0xFF / 255, alpha: 1)
            : UIColor(red: 0x84 / 255, green: 0x45 / 255, blue: 0xCE / 255, alpha: 1)
    })
    /// Labels on the accent: black on the bright dark-mode violet, white on the deep light-mode one.
    static let shareOnAccent = Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    /// #C6A2FF: the ORP colour on the clip's black.
    static let shareAccentOnBlack = Color(red: 0xC6 / 255, green: 0xA2 / 255, blue: 0xFF / 255)
}
