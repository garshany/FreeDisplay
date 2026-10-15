#if os(macOS)
import SwiftUI
import TopologyCore

/// The record can survive an absent display or failed readback. Deleting it is an explicit choice,
/// separate from Keep, and never races the transaction that still owns it.
struct PendingRevertRecordCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingForget = false

    var body: some View {
        if let record = model.revertRecordPresentation {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pending display settings revert").font(.headline)
                    Text("Saved display modes, positions, mirroring and main display selection are waiting to be restored.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let date = record.createdAt {
                        Text("Since \(date.formatted(date: .abbreviated, time: .standard))").font(.caption)
                    } else {
                        Text("Record date unknown").font(.caption)
                    }
                    if !record.readable {
                        Text("The revert record could not be read.").font(.caption)
                    }
                    ForEach(record.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName(for: entry.observation)).font(.callout).bold()
                            Text(entry.id.rawValue).font(.caption).textSelection(.enabled)
                            if entry.awaitingDisplay { Text("Waiting for this display").font(.caption) }
                            let observation = entry.observation
                            if let mode = observation.mode {
                                Text("Recorded mode: \(mode.pointWidth) × \(mode.pointHeight), \(mode.refreshHz) Hz")
                                    .font(.caption)
                            }
                            Text("Recorded position: \(observation.origin.x), \(observation.origin.y)").font(.caption)
                            if observation.isMain { Text("Recorded as main display").font(.caption) }
                            if let source = observation.mirrorSourceID {
                                Text("Recorded mirror source: \(source.rawValue)").font(.caption)
                            } else {
                                Text("Recorded as independent display").font(.caption)
                            }
                        }
                    }
                    Button("Forget Pending Revert…", role: .destructive) { confirmingForget = true }
                        .disabled(model.displayConfigurationBusy)
                    if let error = model.revertRecordError { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("Forget the pending revert?", isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget Pending Revert", role: .destructive) { model.forgetPendingRevert() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The saved display settings will no longer be restored at launch, including settings waiting for absent displays. Current display settings stay in effect.")
            }
        }
    }
}
#endif
