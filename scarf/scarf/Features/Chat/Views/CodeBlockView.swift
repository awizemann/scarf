import SwiftUI
import AppKit

struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                HStack {
                    Text(language)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    copyButton
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            } else {
                HStack {
                    Spacer()
                    copyButton
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(nsColor: NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .padding(.top, 4)
            }
        }
        .background(Color(nsColor: NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy code")
    }
}
