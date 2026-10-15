#if os(macOS)
import AutomationSchema
import DisplayDomain
import SwiftUI
import TopologyCore

struct ClockDisplayRecipesCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Per-display Clock Mode").font(.title3)
            Text("FreeDisplay uses normalized brightness (0–100%) through the selected current controller. Hardware-only requests never fall back to software. Each selected display keeps its own Day/Evening points and an explicit brightness-only Restore value.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Run per-display schedules", isOn: Binding(
                get: { model.settings.clockScheduleEnabled },
                set: { model.updateClockMode(configuration, enabled: $0) }))
            TextField("Time zone identifier (empty follows this Mac)", text: Binding(
                get: { configuration.timeZoneIdentifier ?? "" },
                set: { value in edit { $0.timeZoneIdentifier = value.isEmpty ? nil : value } }))
            Picker("After wake", selection: Binding(
                get: { configuration.resumePolicy },
                set: { value in edit { $0.resumePolicy = value } })) {
                Text("Apply current interval; skip missed transitions").tag(ClockResumePolicy.currentInterval)
                Text("Pause until Resume is pressed").tag(ClockResumePolicy.pauseUntilResumed)
            }
            Text("Missing DST times use the first valid time after the gap; repeated times use the first occurrence. Manual brightness changes hold until the next schedule point. Synced groups and active app presets block Clock Mode writes. Explicit targets are reserved from Adaptive brightness even while the schedule is off.")
                .font(.caption).foregroundStyle(.secondary)
            if model.safeStartup {
                Text("Shift safe startup suppresses all recurring Clock Mode writes. Apply Now and Restore remain explicit actions.")
                    .font(.caption)
            }
            if let error = model.clockModeConfigurationError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            ClockRecipeLocationEditor()
            Menu("Add Display Recipe") {
                ForEach(model.automationDisplayEntries, id: \.id) { display in
                    Button(display.name) { add(display.id) }
                        .disabled(configuration.displays.contains { $0.displayID == display.id }
                                  || model.brightness[display.id] == nil || !model.canPersistDisplaySettings(display.id))
                }
            }
            Text("Adding a display uses its currently known brightness as the editable Restore value. It adds no schedule points and does not change brightness.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(configuration.displays) { schedule in
                ClockDisplayRecipeEditor(schedule: schedule, update: { replacement in
                    edit { config in
                        if let index = config.displays.firstIndex(where: { $0.displayID == schedule.displayID }) {
                            config.displays[index] = replacement
                        }
                    }
                }, remove: {
                    edit { $0.displays.removeAll { $0.displayID == schedule.displayID } }
                })
            }
            Button("Resume Clock Mode") { model.resumeClockRecipes() }
                .disabled(!model.settings.clockScheduleEnabled)
            Text("Turning schedules off keeps current brightness. Restore stays available and turns scheduling off before applying that display’s declared value. Already dispatched writes may finish; other apps and hardware buttons can still change brightness.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var configuration: ClockModeConfiguration {
        model.settings.clockMode ?? ClockModeConfiguration(timeZoneIdentifier: nil, resumePolicy: .currentInterval,
                                                         displays: [])
    }

    private func edit(_ change: (inout ClockModeConfiguration) -> Void) {
        var copy = configuration
        change(&copy)
        model.clockModeConfigurationError = nil
        model.updateClockMode(copy)
    }

    private func add(_ id: DisplayRecordID) {
        guard model.canPersistDisplaySettings(id), let current = model.brightness[id], let level = AutomationLevel(normalized: Double(current)) else { return }
        edit { $0.displays.append(ClockDisplaySchedule(displayID: id, entries: [], method: .automatic,
                                                       restoreLevel: level,
                                                       rampMinutes: ClockSchedulePolicy.defaultRampMinutes)) }
    }
}

private struct ClockRecipeLocationEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Solar latitude", text: $latitude)
                TextField("Solar longitude", text: $longitude)
                Button("Save Solar Coordinates") {
                    guard let lat = Double(latitude), let lon = Double(longitude),
                          lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else {
                        invalid = true
                        return
                    }
                    invalid = false
                    model.updateClockModeLocation(GeoCoordinate(latitude: lat, longitude: lon))
                }
                Button("Clear Solar Coordinates") {
                    model.updateClockModeLocation(nil)
                    latitude = ""
                    longitude = ""
                }
            }
            if invalid {
                Text("Enter valid latitude and longitude in decimal degrees.").font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear {
            if let coordinate = model.settings.clockManualLocation {
                latitude = String(coordinate.latitude)
                longitude = String(coordinate.longitude)
            }
        }
    }
}

private struct ClockDisplayRecipeEditor: View {
    @EnvironmentObject private var model: AppModel
    let schedule: ClockDisplaySchedule
    let update: (ClockDisplaySchedule) -> Void
    let remove: () -> Void

    var body: some View {
        GroupBox(model.automationDisplayEntries.first(where: { $0.id == schedule.displayID })?.name
                 ?? model.automationRememberedName(schedule.displayID) ?? schedule.displayID.rawValue) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Brightness route", selection: binding(\.method)) {
                    Text("Current controller").tag(BrightnessMethodRequest.automatic)
                    Text("Hardware only").tag(BrightnessMethodRequest.hardware)
                    Text("Native only").tag(BrightnessMethodRequest.native)
                    Text("DDC only").tag(BrightnessMethodRequest.ddc)
                    Text("Software only").tag(BrightnessMethodRequest.software)
                }
                TextField("Ramp duration (minutes)", value: binding(\.rampMinutes), format: .number)
                TextField("Restore brightness (%)", value: Binding(
                    get: { schedule.restoreLevel.percent },
                    set: { value in
                        guard let level = AutomationLevel(percent: value) else { return }
                        var copy = schedule
                        copy.restoreLevel = level
                        update(copy)
                    }), format: .number)
                ForEach(schedule.entries) { entry in
                    ClockRecipePointEditor(entry: entry, update: { replacement in
                        var copy = schedule
                        if let index = copy.entries.firstIndex(where: { $0.id == entry.id }) {
                            copy.entries[index] = replacement
                            update(copy)
                        }
                    }, remove: {
                        var copy = schedule
                        copy.entries.removeAll { $0.id == entry.id }
                        update(copy)
                    })
                }
                HStack {
                    Button("Add Schedule Point") {
                        var copy = schedule
                        // Preserve the existing Clock Mode editor's starting point, editable before enabling.
                        copy.entries.append(ClockScheduleEntry(anchor: .time, timeMinute: 8 * 60,
                                                                brightness: 0.7, transition: .ramp))
                        update(copy)
                    }
                    Button("Apply Now") { Task { await model.applyClockRecipe(schedule) } }
                    Button("Restore") { Task { await model.restoreClockRecipe(schedule) } }
                    Button("Remove Recipe", role: .destructive, action: remove)
                }
                if let hold = model.clockModeHolds[schedule.displayID] {
                    Text(holdText(hold)).font(.caption).foregroundStyle(.secondary)
                } else if let result = model.clockModeResults[schedule.displayID] {
                    if let issue = result.issue {
                        Text(DisplayIntentError.commandFailed(issue.code).localizedStringResource)
                            .font(.caption).foregroundStyle(.orange)
                        if issue.code == .methodUnavailable {
                            Text("The requested route must match the display’s configured controller. Hardware routes also require support in this build and permission for DDC.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let report = result.brightness {
                        if let requested = report.requested {
                            Text("Requested brightness: \(requested.wholePercent)%").font(.caption)
                        }
                        if let reported = report.level {
                            Text("Reported brightness: \(reported.wholePercent)%").font(.caption)
                        } else {
                            Text("Brightness readback is unavailable.").font(.caption)
                        }
                        Text(result.succeeded ? "Brightness request completed; check the reported state."
                             : "Brightness request failed or could not be confirmed.")
                            .font(.caption)
                        Text(report.route == .software ? "Software state only; no display luminance measurement."
                             : "Controller readback is not a physical luminance measurement.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<ClockDisplaySchedule, T>) -> Binding<T> {
        Binding(get: { schedule[keyPath: path] }, set: { value in
            var copy = schedule
            copy[keyPath: path] = value
            update(copy)
        })
    }

    private func holdText(_ hold: ClockModeSession.Hold) -> String {
        switch hold {
        case .disabled: return String(localized: "Schedule is off; brightness is retained.")
        case .safeStartup: return String(localized: "Clock Mode paused by Shift safe startup.")
        case .sleeping: return String(localized: "Clock Mode is waiting for wake.")
        case .resumePaused: return String(localized: "Clock Mode is paused after wake. Press Resume.")
        case .manualOverride: return String(localized: "Manual brightness held until the next schedule point.")
        case .competingPolicy: return String(localized: "Clock Mode is blocked by group sync or an active app preset.")
        case .provisionalIdentity: return String(localized: "A verified persistent display identity is required. Earlier provisional associations remain saved but inactive.")
        case .noAnchor: return String(localized: "No available schedule point. Solar points require a location and an available solar event.")
        }
    }
}

private struct ClockRecipePointEditor: View {
    let entry: ClockScheduleEntry
    let update: (ClockScheduleEntry) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Schedule anchor", selection: binding(\.anchor)) {
                    Text("Time").tag(ScheduleAnchor.time)
                    Text("Sunrise").tag(ScheduleAnchor.sunrise)
                    Text("Solar noon").tag(ScheduleAnchor.solarNoon)
                    Text("Sunset").tag(ScheduleAnchor.sunset)
                }
                if entry.anchor == .time {
                    DatePicker("Time", selection: Binding(get: {
                        Calendar.current.date(bySettingHour: entry.timeMinute / 60, minute: entry.timeMinute % 60,
                                              second: 0, of: Date()) ?? Date()
                    }, set: { date in
                        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                        var copy = entry
                        copy.timeMinute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                        update(copy)
                    }), displayedComponents: .hourAndMinute)
                }
                Button("Remove Point", role: .destructive, action: remove)
            }
            HStack {
                TextField("Offset (minutes)", value: binding(\.offsetMinutes), format: .number)
                TextField("Brightness (%)", value: Binding(get: { Double(entry.brightness) * 100 }, set: { value in
                    guard let level = AutomationLevel(percent: value) else { return }
                    var copy = entry
                    copy.brightness = level.float
                    update(copy)
                }), format: .number)
                Picker("Transition", selection: binding(\.transition)) {
                    Text("Instant").tag(ScheduleTransition.instant)
                    Text("Ramp").tag(ScheduleTransition.ramp)
                    Text("Continuous").tag(ScheduleTransition.continuous)
                }
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<ClockScheduleEntry, T>) -> Binding<T> {
        Binding(get: { entry[keyPath: path] }, set: { value in
            var copy = entry
            copy[keyPath: path] = value
            update(copy)
        })
    }
}
#endif
