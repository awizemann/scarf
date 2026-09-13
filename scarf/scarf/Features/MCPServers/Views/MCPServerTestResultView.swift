import SwiftUI
import ScarfCore

struct MCPServerTestResultView: View {
    // MARK: - Three states, not two (P54, round-6)

    /// `hermes mcp test` exits 0 whether the probe connected, refused, or
    /// printed nothing recognisable at all
    /// (``HermesMCPTestVerdict``). This view had a two-way `if` on
    /// `succeeded`, so the third state wore the failure's red seal and the
    /// words "Test failed" — asserting a refusal the run never proved. The
    /// honest answer is a neutral amber: we do not know.
    static func glyph(for confidence: HermesCLIOutcome.Confidence) -> String {
        switch confidence {
        case .confirmed: "checkmark.seal.fill"
        case .failed: "xmark.seal.fill"
        case .unconfirmed: "questionmark.circle.fill"
        }
    }

    static func tint(for confidence: HermesCLIOutcome.Confidence) -> Color {
        switch confidence {
        case .confirmed: .green
        case .failed: .red
        case .unconfirmed: .orange
        }
    }

    static func headline(for confidence: HermesCLIOutcome.Confidence) -> Text {
        switch confidence {
        case .confirmed: Text("Test passed")
        case .failed: Text("Test failed")
        case .unconfirmed: Text("No result — Hermes printed nothing recognisable")
        }
    }

    let result: MCPTestResult
    @State private var showOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: Self.glyph(for: result.confidence))
                    .foregroundStyle(Self.tint(for: result.confidence))
                VStack(alignment: .leading, spacing: 2) {
                    Self.headline(for: result.confidence)
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
        .background(Self.tint(for: result.confidence).opacity(0.08))
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
