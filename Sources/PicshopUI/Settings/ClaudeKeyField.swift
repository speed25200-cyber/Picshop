#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// The Anthropic API key, as rows of a Settings section: typed or pasted,
/// checked with a free request (no tokens), then kept in this iPhone's
/// Keychain only. Every result of the check has its own line.
struct ClaudeKeyField: View {
    let store: ClaudeKeyStore
    @State private var draft = ""
    @State private var isReplacing = false
    @State private var reveals = false
    @State private var isChecking = false
    @State private var result: ClaudeKeyStatus?
    @State private var saveFailed = false
    @State private var confirmsDelete = false
    @FocusState private var isFocused: Bool

    static let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")!

    var body: some View {
        Group {
            if store.hasKey && !isReplacing {
                savedRows
            } else {
                entryRows
            }
            Link(destination: Self.consoleURL) {
                Label(L("Get a key"), systemImage: "arrow.up.right.square")
            }
        }
        .animation(PSMotion.standard, value: store.hasKey)
        .animation(PSMotion.standard, value: isChecking)
        .confirmationDialog(L("Delete the Claude key?"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(L("Delete the key"), role: .destructive) {
                try? store.delete()
                result = nil
                Haptics.confirm()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Live will answer from the iPhone until you add a key again."))
        }
    }

    // MARK: Entry

    @ViewBuilder
    private var entryRows: some View {
        HStack(spacing: 10) {
            SettingsRowIcon(systemName: "key.fill", tint: PSTheme.voice)
            Group {
                if reveals {
                    TextField(text: $draft, prompt: Text(verbatim: "sk-ant-…")) { Text(L("Claude API key")) }
                } else {
                    SecureField(text: $draft, prompt: Text(verbatim: "sk-ant-…")) { Text(L("Claude API key")) }
                }
            }
            .font(PSFont.mono(15))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($isFocused)
            .onSubmit(verify)
            .disabled(isChecking)
            if draft.isEmpty {
                // Pastes without the system's paste prompt.
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first else { return }
                    Task { @MainActor in
                        draft = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        result = nil
                    }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
            } else {
                Button {
                    reveals.toggle()
                } label: {
                    Image(systemName: reveals ? "eye.slash" : "eye")
                        .foregroundStyle(PSTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(reveals ? L("Hide the key") : L("Show the key"))
            }
        }
        .onChange(of: draft) { _, _ in
            if !isChecking, result != nil { result = nil }
        }
        if isChecking {
            HStack(spacing: 10) {
                ProgressView()
                Text(L("Checking…")).foregroundStyle(PSTheme.textSecondary)
            }
            .font(PSFont.footnote())
        } else if saveFailed {
            statusLine(L("The key could not be saved in the keychain."), symbol: "exclamationmark.triangle.fill", tint: PSTheme.danger)
        } else if let result {
            status(result)
        }
        HStack {
            Button(L("Verify")) { verify() }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
            if isReplacing {
                Spacer()
                Button(L("Cancel")) {
                    isReplacing = false
                    draft = ""
                    result = nil
                    reveals = false
                }
                .foregroundStyle(PSTheme.textSecondary)
            }
        }
        .buttonStyle(.borderless)
        keychainNote
    }

    private func verify() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isChecking else { return }
        isFocused = false
        isChecking = true
        result = nil
        saveFailed = false
        Task {
            let status = await store.check(key)
            isChecking = false
            result = status
            // Saved after a 200, or unverified when offline: it is checked again later.
            guard status == .valid || status == .offline else {
                Haptics.error()
                return
            }
            do {
                try store.save(key)
                draft = ""
                reveals = false
                isReplacing = false
                Haptics.success()
            } catch {
                saveFailed = true
                Haptics.error()
            }
        }
    }

    // MARK: Saved

    @ViewBuilder
    private var savedRows: some View {
        HStack(spacing: 10) {
            SettingsRowIcon(systemName: "key.fill", tint: PSTheme.voice)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: store.maskedKey ?? "sk-ant-…")
                    .font(PSFont.mono(15))
                    .foregroundStyle(PSTheme.textPrimary)
                    .accessibilityLabel(L("Claude API key"))
                savedStatus
            }
            Spacer(minLength: 0)
            if isChecking { ProgressView() }
        }
        HStack {
            Button(L("Replace")) {
                isReplacing = true
                result = nil
            }
            if needsCheck {
                Spacer()
                Button(L("Check again")) {
                    isChecking = true
                    Task {
                        await store.recheck()
                        isChecking = false
                    }
                }
                .disabled(isChecking)
            }
            Spacer()
            Button(L("Delete the key"), role: .destructive) { confirmsDelete = true }
        }
        .buttonStyle(.borderless)
        keychainNote
    }

    @ViewBuilder
    private var savedStatus: some View {
        switch store.status {
        case .unchecked:
            Text(L("Not checked yet")).font(PSFont.footnote()).foregroundStyle(PSTheme.textSecondary)
        default:
            status(store.status, compact: true)
        }
    }

    private var needsCheck: Bool {
        switch store.status {
        case .valid, .invalid, .noAccess, .malformed: return false
        case .unchecked, .noCredit, .rateLimited, .offline, .server: return true
        }
    }

    private var keychainNote: some View {
        Text(L("The key stays in this iPhone's keychain and is not transferred to a new iPhone."))
            .font(PSFont.footnote())
            .foregroundStyle(PSTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Status lines

    @ViewBuilder
    private func status(_ status: ClaudeKeyStatus, compact: Bool = false) -> some View {
        let line = Self.line(for: status)
        if compact {
            Label(line.text, systemImage: line.symbol)
                .font(PSFont.footnote())
                .foregroundStyle(line.tint)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            statusLine(line.text, symbol: line.symbol, tint: line.tint)
        }
    }

    private func statusLine(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(PSFont.footnote())
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    /// What each result of the check says.
    static func line(for status: ClaudeKeyStatus) -> (text: String, symbol: String, tint: Color) {
        switch status {
        case .unchecked:
            return (L("Not checked yet"), "questionmark.circle", PSTheme.textSecondary)
        case .malformed:
            return (L("A Claude key starts with sk-ant-"), "exclamationmark.circle.fill", PSTheme.warning)
        case .valid:
            return (String(format: L("Valid key · %@ available"), ClaudeRequestOptions.model), "checkmark.seal.fill", PSTheme.success)
        case .invalid:
            return (L("Key refused by Anthropic"), "xmark.octagon.fill", PSTheme.danger)
        case .noAccess:
            return (L("This key has no access to Claude Opus 5"), "lock.fill", PSTheme.danger)
        case .noCredit:
            return (L("Anthropic credit used up"), "creditcard.trianglebadge.exclamationmark", PSTheme.warning)
        case .rateLimited:
            return (L("Too many requests — try again in a moment"), "hourglass", PSTheme.warning)
        case .offline:
            return (L("No connection — the key will be checked later"), "wifi.slash", PSTheme.warning)
        case .server:
            return (L("Anthropic isn't answering — try again"), "exclamationmark.icloud", PSTheme.warning)
        }
    }
}
#endif
