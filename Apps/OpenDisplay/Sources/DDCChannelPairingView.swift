#if os(macOS) && !PUBLIC_API_ONLY
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI

struct DDCChannelPairingView: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var channels: [DDCChannel] = []
    @State private var selected = ""
    // Both are deliberate user inputs: no diagnostic brightness or duration is invented.
    @State private var level = ""
    @State private var seconds = ""
    @State private var proof: DDCChannelMapping?
    @State private var observedResponse = false
    @State private var working = false
    @State private var message: String?

    private var parameters: DDCChannelTest.Parameters? {
        guard let level = Double(level), let seconds = Double(seconds) else { return nil }
        return .init(levelPercent: level, durationSeconds: seconds)
    }

    var body: some View {
        ODCard(title: String(localized: "Manual DDC channel mapping")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("For identical monitors without unique serials, automatic DDC stays off until a channel is confirmed. Choose a channel, run a brightness test and watch which physical monitor responds. The channel can reach a different screen. Keep the monitor’s own controls available.")
                    .font(.callout).foregroundStyle(.secondary)
                if let saved = model.settings.ddcChannelMappings.first(where: { $0.displayID == display.recordID }) {
                    LabeledContent("Saved channel", value: saved.channelPath)
                    Button("Remove channel mapping") { model.removeDDCChannelMapping(for: display.recordID); proof = nil }
                }
                if let status = model.ddcPairingStatus[display.recordID] {
                    switch status {
                    case .inUse: Text("The confirmed channel is in use")
                    case .notNeeded: Text("Automatic identity matching resolved the channel")
                    case .invalid(let reason): Text(reason.rawValue.appLocalized)
                    }
                }
                Button("List DDC channels") {
                    working = true
                    proof = nil
                    Task { channels = await model.pairingChannels(); working = false }
                }.disabled(working)
                Picker("Channel", selection: $selected) {
                    Text("Choose a channel").tag("")
                    ForEach(channels, id: \.path) { channel in Text(verbatim: channel.path).tag(channel.path) }
                }
                HStack {
                    TextField("Test brightness (%)", text: $level)
                    TextField("Test duration (seconds)", text: $seconds)
                }.textFieldStyle(.roundedBorder)
                Text("Enter a brightness percentage and a positive duration in seconds. The original brightness is read first and sent back afterwards. A successful request does not prove a visible response.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Test chosen channel") {
                    guard let channel = channels.first(where: { $0.path == selected }), let parameters else { return }
                    working = true
                    proof = nil
                    observedResponse = false
                    Task {
                        let result = await model.testDDCChannel(channel, for: display, parameters: parameters)
                        proof = result.0
                        message = result.1
                        working = false
                    }
                }.disabled(working || parameters == nil || selected.isEmpty || !DDCChannelMappingPolicy.canPair(display.recordID) || model.safeStartup || model.busy)
                if let proof {
                    let displaced = DDCChannelMappingPolicy.displaced(by: proof, in: model.settings.ddcChannelMappings)
                    if !displaced.isEmpty {
                        Text("Confirming removes this channel’s previous mapping from:")
                        ForEach(displaced, id: \.self) { Text(model.rememberedDisplayName(for: $0)) }
                    }
                    Toggle("I saw this physical monitor change brightness", isOn: $observedResponse)
                    Button("Confirm channel mapping") {
                        working = true
                        Task {
                            let saved = await model.confirmDDCChannel(proof)
                            message = saved ? String(localized: "Channel mapping saved for this stable identity.")
                                : String(localized: "Identity changed. List channels and run the test again.")
                            self.proof = nil
                            working = false
                        }
                    }.disabled(!observedResponse || working)
                    Button("Cancel pairing") { self.proof = nil; observedResponse = false }
                        .disabled(working)
                }
                if let message { Text(message).font(.callout) }
                Text("Mappings use the stable macOS UUID and channel path with vendor/model/serial evidence. An evidence mismatch revokes the mapping. Identical monitors swapped on the same cables may expose identical evidence; retest after changing cabling. Public API Only has no DDC transport.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12).disabled(working)
        }
        .onChange(of: selected) { proof = nil; observedResponse = false }
        .onChange(of: level) { proof = nil; observedResponse = false }
        .onChange(of: seconds) { proof = nil; observedResponse = false }
    }
}
#endif
