import AppKit
import SwiftUI
import HoatzinCore

struct PromptSheet: View {
    let pending: PromptCenter.Pending
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch pending.content {
            case .password(let prompt):
                PasswordPromptView(prompt: prompt) { answer in
                    model.prompts.respond(pending.id, answer.map { .password($0) } ?? .cancelled)
                }
            case .confirm(let prompt):
                ConfirmPromptView(prompt: prompt) { ok, option in
                    model.prompts.respond(pending.id, prompt.optionTitle == nil ? .confirmed(ok) : .confirmedWithOption(ok, option: option))
                }
            case .text(let prompt):
                TextPromptView(prompt: prompt) { value in
                    model.prompts.respond(pending.id, value.map { .text($0) } ?? .cancelled)
                }
            }
        }
        .id(pending.id)
    }
}

struct PasswordPromptView: View {
    let prompt: PasswordPrompt
    let finish: (PasswordAnswer?) -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var save = true
    @State private var copied = false
    @State private var userHandle = FieldHandle()
    @State private var passwordHandle = FieldHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: prompt.isRetry ? "exclamationmark.lock.fill" : "key.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(prompt.isRetry ? Color.orange : Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.title).font(.headline)
                    if let message = prompt.message {
                        Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("User").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    AutoFillField(text: $username, placeholder: String(localized: "user name"), contentType: .username,
                                  isEnabled: prompt.usernameEditable, handle: userHandle)
                }
                GridRow {
                    Text(prompt.secretLabel).foregroundStyle(.secondary)
                    AutoFillField(text: $password, placeholder: prompt.secretLabel.lowercased(), secure: true,
                                  contentType: .password, autofocus: true, handle: passwordHandle, onSubmit: submit)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("In Passwords? Click into the field and choose the entry from the AutoFill menu (key icon). Search for **\(prompt.key.server)**.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "person.badge.key")
                }
                .font(.callout)
                HStack(spacing: 8) {
                    Button(copied ? "Copied" : "Copy “\(prompt.key.server)”") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt.key.server, forType: .string)
                        copied = true
                    }
                    Button("Open Passwords") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Passwords.app"))
                    }
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            Toggle("Remember in the macOS Keychain (never stored in Hoatzin)", isOn: $save)
                .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 470)
        .onAppear {
            username = prompt.key.account
            save = prompt.saveByDefault
        }
    }

    private func submit() {
        let user = userHandle.value ?? username
        let secret = passwordHandle.value ?? password
        guard !secret.isEmpty else { return }
        finish(PasswordAnswer(username: user, password: secret, save: save))
    }
}

struct ConfirmPromptView: View {
    let prompt: ConfirmPrompt
    /// (confirmed, option checkbox ticked)
    let finish: (Bool, Bool) -> Void

    @State private var option = false
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: prompt.destructive ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(prompt.destructive ? Color.orange : Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.title).font(.headline)
                    Text(prompt.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let detail = prompt.detail {
                ScrollView {
                    Text(detail)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
            HStack {
                if let optionTitle = prompt.optionTitle {
                    Toggle(optionTitle, isOn: $option)
                }
                Spacer()
                Button(prompt.cancelTitle, role: .cancel) { finish(false, false) }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.confirmTitle, role: prompt.destructive ? .destructive : nil) { finish(true, option) }
                    .keyboardShortcut(prompt.guardsAgainstStrayKeys ? nil : .defaultAction)
                    .disabled(prompt.guardsAgainstStrayKeys && !armed)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            guard prompt.guardsAgainstStrayKeys else { return }
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
    }
}

struct TextPromptView: View {
    let prompt: TextPrompt
    let finish: (String?) -> Void

    @State private var value = ""
    @State private var handle = FieldHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title).font(.headline)
            Text(prompt.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            AutoFillField(text: $value, placeholder: prompt.placeholder, secure: prompt.secure,
                          contentType: prompt.secure ? .password : .oneTimeCode, autofocus: true, handle: handle, onSubmit: submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        finish(handle.value ?? value)
    }
}
