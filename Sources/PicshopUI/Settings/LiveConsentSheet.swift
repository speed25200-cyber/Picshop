#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Asked once, before the first Claude request that carries anything the person
/// says, writes or shows (D12). Declining keeps Live on the iPhone; Settings'
/// Use Claude switch asks again.
struct LiveConsentSheet: View {
    private let onDecision: (_ granted: Bool, _ sendImages: Bool) -> Void
    @State private var sendImages = true

    init(onDecision: @escaping (_ granted: Bool, _ sendImages: Bool) -> Void) {
        self.onDecision = onDecision
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PSSpacing.medium) {
                Text(L("Talk with Claude"))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(PSTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(L("In Live mode with Claude, these are sent to Anthropic to answer you, with your own API key: what you say or type during Live (the text, never the audio); the list of your edits and their settings; what the iPhone recognised in the picture (for example “1 person in the centre, a dog on the left”); the text in your photo or video and a few sentences spoken in the video around the playhead; if you allow it, a reduced copy (1024 px) of the photo or video frame on screen, without location or camera data. Your voice is transcribed on the iPhone: the audio never leaves the device. Outside Live mode, nothing is sent. Anthropic keeps this data according to its privacy policy, and usage is billed to your Anthropic account. You can stop at any time with the End button or in Settings › Live."))
                    .font(PSFont.body())
                    .foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("Also send the picture"), isOn: $sendImages)
                    .font(PSFont.headline())
                    .foregroundStyle(PSTheme.textPrimary)
                    .padding(.vertical, PSSpacing.small)
            }
            .padding(.horizontal, PSSpacing.page)
            .padding(.top, PSSpacing.section)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: PSSpacing.small) {
                // White prominent glass and plain glass, full width, as the studio's primary and secondary.
                Button {
                    Haptics.confirm()
                    onDecision(true, sendImages)
                } label: {
                    Text(L("Accept and continue"))
                        .font(.headline)
                        .foregroundStyle(PSTheme.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glassProminent)
                .tint(PSTheme.primary)
                Button {
                    Haptics.tap()
                    onDecision(false, false)
                } label: {
                    Text(L("Stay on the iPhone"))
                        .font(.headline)
                        .foregroundStyle(PSTheme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glass)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, PSSpacing.page)
            .padding(.bottom, PSSpacing.medium)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
}
#endif
