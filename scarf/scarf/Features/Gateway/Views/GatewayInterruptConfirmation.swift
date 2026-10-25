import SwiftUI

extension View {
    /// Asks whether to interrupt live sessions after Hermes refused a
    /// Stop/Restart (v0.22.3+, ``GatewayInterruptRequest``). Shared by every
    /// pane with a gateway Stop or Restart so they all ask the same question.
    /// `onConfirm` is the ONLY path to a `--yes` run; Cancel and dismissal
    /// both just clear the request.
    func gatewayInterruptConfirmation(
        _ request: GatewayInterruptRequest?,
        onConfirm: @escaping (GatewayInterruptRequest) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            request?.title ?? "",
            isPresented: Binding(get: { request != nil }, set: { if !$0 { onCancel() } })
        ) {
            Button(request?.confirmLabel ?? "", role: .destructive) {
                if let request { onConfirm(request) }
            }
            Button("Cancel", role: .cancel) { onCancel() }
        } message: {
            Text(request?.message ?? "")
        }
    }
}
