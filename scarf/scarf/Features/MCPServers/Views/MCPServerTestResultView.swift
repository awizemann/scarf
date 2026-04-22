import SwiftUI
import ScarfCore

struct MCPServerTestResultView: View {
    let result: MCPTestResult
    @State private var showOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: result.succeeded ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    (result.succeeded ? Text("Test passed") : Text("Test failed"))
                        .font(.subheadline.bold())
                    Text("\(result.elapsed.formatted(.number.precision(.fractionLength(1))))s · \(result.tools.count) tools")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showOutput.toggle()
                } label: {
                    Label {
                        showOutput ? Text("Hide Output") : Text("Show Output")
                    } icon: {
                        Image(systemName: showOutput ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            if !result.tools.isEmpty {
                WrapChips(items: result.tools)
            }
            if showOutput {
                ScrollView {
                    Text(result.output.isEmpty ? "(no output)" : result.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((result.succeeded ? Color.green : Color.red).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct WrapChips: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }
}
