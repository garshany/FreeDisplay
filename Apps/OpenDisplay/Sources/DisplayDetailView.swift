#if os(macOS)
import AutomationSchema
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// The per-display detail pane (Settings → Displays). This is where everything that used to crowd the
/// menu-bar card now lives: resolution & refresh, appearance (rotation/colour), hardware controls,
/// input, "use as", identity, and read-only info — grouped into System-Settings-style cards. The menu
/// bar deep-links here via "Display settings…". See `Docs/InterfaceRedesign.md`.
struct DisplayDetailView: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let pending = model.pendingRevert {
                    // Timed auto-revert prompt for a change made here in Settings (Issue 6).
                    VStack(alignment: .leading, spacing: 6) {
                        ODInlineBanner(tone: .orange, systemImage: "clock.arrow.circlepath",
                                       title: "Сохранить эти настройки монитора?",
                                       message: "\(pending.message). Отмена через \(pending.secondsRemaining) с…")
                        HStack(spacing: 8) {
                            Button("Сохранить") { model.confirmArrangementChange() }
                                .keyboardShortcut(.defaultAction)
                            Button("Отменить сейчас") { Task { await model.revertArrangementChange() } }
                            Spacer()
                        }
                    }
                }
                ResolutionCard(display: display)
                AppearanceCard(display: display)
                if display.displayClass != .builtIn { ControlsCard(display: display) }
                DimmingCard(display: display)
                UseAsCard(display: display)
                IdentityCard(display: display)
                InformationCard(display: display)
                // Display-agnostic, but the Displays tab is where it belongs (Issue #39) and this is
                // the tab's only scrolling surface.
                DisplayGroupsCard()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: display.recordID) {
            // Opening the detail pane is a deliberate act — if this display currently has NO working
            // hardware control, retry even negatively-cached DDC features so a monitor that just
            // recovered (power-cycle, input switch) shows its controls now. Healthy displays keep
            // their probe cache, so reopening the pane stays fast.
            model.retryDDCDiscoveryIfDead(for: display)
            await model.refreshBrightness(for: display)
            await model.refreshColorProfile(for: display)
            if display.displayClass != .builtIn {
                await model.refreshHardwareControls(for: display)
                await model.refreshColorPreset(for: display)
                await model.refreshInputSource(for: display)
            }
        }
    }
}

// MARK: - Resolution

struct ResolutionCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    let compact: Bool

    init(display: DisplayObservation, compact: Bool = false) {
        self.display = display
        self.compact = compact
    }
    @State private var allModes: [DisplayMode] = []
    @State private var selectedMode: DisplayMode?
    @State private var applying = false
    @State private var showLowerDensity = false

    private var choices: [DisplayMode] {
        DisplayModeChoices.visible(from: allModes, current: display.mode, includeLowerDensity: showLowerDensity)
    }

    private var canApply: Bool {
        !applying && model.pendingRevert == nil && display.isActive
            && DisplayModeChoices.canApply(selectedMode, current: display.mode, choices: choices)
    }

    var body: some View {
        ODCard(title: compact ? nil : "Разрешение и масштабирование",
               footnote: compact ? "Выбор режима применяется только кнопкой «Применить»." : "Логический размер определяет рабочую область. Буфер — размер изображения, которое рисует macOS; он не сообщает физическое разрешение матрицы. Большой буфер HiDPI может дополнительно масштабироваться и не гарантирует лучшую чёткость на любом мониторе. Выбор вступает в силу только после нажатия «Применить» и требует подтверждения.") {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Текущий режим").font(.system(size: 11)).foregroundStyle(.secondary)
                    currentModeText
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Выбрать режим").font(.system(size: 11)).foregroundStyle(.secondary)
                    modePicker.frame(maxWidth: .infinity)
                }.padding(10)
            } else {
                ODRow("Текущий режим") {
                    currentModeText.multilineTextAlignment(.trailing)
                        .frame(maxWidth: 380, alignment: .trailing)
                }
                ODDivider()
                ODRow("Выбрать режим") { modePicker.frame(maxWidth: 380) }
            }
            ODDivider()
            ODRow("Дополнительные режимы") {
                Toggle(compact ? "Показывать без HiDPI" : "Показывать альтернативы без HiDPI", isOn: $showLowerDensity)
                    .font(.system(size: 11)).disabled(applying || model.pendingRevert != nil)
                    .help("По умолчанию скрыты варианты без HiDPI, если для того же логического размера есть HiDPI. Текущий режим всегда остаётся видимым.")
            }
            if let error = model.modeChangeError {
                ODDivider()
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    .textSelection(.enabled).padding(10)
            }
            if let selectedMode, selectedMode != display.mode {
                ODDivider()
                if compact {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Будет применено").foregroundStyle(.secondary)
                        Text(DisplayModeChoices.label(selectedMode))
                    }
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                } else {
                    ODRow("Будет применено") {
                        Text(DisplayModeChoices.label(selectedMode))
                            .font(.system(size: 11)).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 380, alignment: .trailing)
                    }
                }
            }
            if !compact, let current = display.mode {
                ODDivider()
                ODRow("Избранные режимы") {
                    HStack(spacing: 8) {
                        Button { model.toggleFavoriteResolution(current, for: display) } label: {
                            Image(systemName: model.isFavoriteResolution(current, for: display) ? "star.fill" : "star")
                        }
                        .buttonStyle(.plain)
                        .help("Добавить текущий режим в избранное или убрать его")
                        Menu("Выбрать из избранного") {
                            ForEach(model.favoriteResolutions(among: choices, for: display), id: \.self) { favorite in
                                Button(DisplayModeChoices.label(favorite)) { selectedMode = favorite }
                            }
                        }
                        .disabled(model.favoriteResolutions(among: choices, for: display).isEmpty
                                  || applying || model.pendingRevert != nil)
                    }
                }
            }
            ODDivider()
            if compact {
                actionButtons.frame(maxWidth: .infinity, alignment: .trailing).padding(10)
            } else {
                ODRow("Изменение режима") { actionButtons }
            }
        }
        .task(id: display.cgDisplayID) {
            allModes = model.allModes(for: display)
            selectedMode = display.mode
        }
        .onChange(of: showLowerDensity) { _, _ in
            if let selectedMode, !choices.contains(selectedMode) { self.selectedMode = display.mode }
        }
        .onChange(of: display.mode) { _, current in
            // Restore/readback only updates the draft; observing a mode never writes a mode.
            selectedMode = current
            allModes = model.allModes(for: display)
        }
    }

    private var currentModeText: some View {
        Text(display.mode.map(DisplayModeChoices.label) ?? "macOS не сообщила текущий режим")
            .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
    }

    @ViewBuilder private var modePicker: some View {
        if choices.isEmpty {
            Text("Нет доступных режимов").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Picker("Новый режим экрана", selection: $selectedMode) {
                if selectedMode == nil { Text("Выберите режим").tag(nil as DisplayMode?) }
                ForEach(choices, id: \.self) { mode in
                    Text(DisplayModeChoices.label(mode)).tag(Optional(mode))
                }
            }
            .labelsHidden().pickerStyle(.menu)
            .disabled(applying || model.pendingRevert != nil)
            .help("Полный режим: логические размеры, буфер изображения, частота и HiDPI")
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("Сбросить выбор") { selectedMode = display.mode }
                .disabled(applying || selectedMode == display.mode)
            Button("Применить") { applySelection() }.disabled(!canApply)
            if applying { ProgressView().controlSize(.small) }
        }
    }

    private func applySelection() {
        guard canApply, let target = selectedMode else { return }
        applying = true
        Task { @MainActor in
            defer { applying = false }
            // AppModel checkpoints this exact mode change and auto-reverts until confirmed.
            await model.setMode(target, for: display)
        }
    }
}

// MARK: - Appearance (rotation + colour)

struct AppearanceCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var detectingModes = false
    /// Set when an explicit "Detect…" came back empty; cleared after a few seconds so a transient
    /// failure doesn't sit on the card as if it were a permanent property of the monitor.
    @State private var detectFoundNothing = false

    /// Displayed kelvin for the temperature slider (absent cache = neutral).
    private var temperature: Float {
        model.colorTemperature[display.recordID] ?? ColorTemperatureCurve.neutralKelvin
    }

    var body: some View {
        ODCard(title: "Изображение") {
            ODRow("Цветовая температура") {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.sun").font(.system(size: 11)).foregroundStyle(.orange)
                    Slider(value: Binding(get: { Double(temperature) },
                                          set: { model.setColorTemperature(Float($0), for: display) }),
                           in: Double(ColorTemperatureCurve.minKelvin)...Double(ColorTemperatureCurve.maxKelvin))
                        .frame(width: 140)
                    Image(systemName: "thermometer.snowflake").font(.system(size: 11)).foregroundStyle(.cyan)
                    Text(model.colorTemperature[display.recordID] == nil
                         ? "Системный" : "\(Int(temperature)) K")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            ODDivider()
            ODRow("Поворот") {
                if model.rotationWritable {
                    HStack(spacing: 6) {
                        ODBadge("Экспериментально", tone: .orange)
                        Menu("\(model.currentRotation(for: display))°") {
                            ForEach([0, 90, 180, 270], id: \.self) { deg in
                                Button("\(deg)°") { Task { await model.setRotation(deg, for: display) } }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                    }
                } else {
                    Text("\(model.currentRotation(for: display))°").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if display.displayClass != .builtIn {
                ODDivider()
                ODRow("Цветовой режим") {
                    // Offer only the preset codes the panel advertises (VCP 0x14 is a non-continuous
                    // enum); a contiguous 1...max guess offers codes the monitor silently ignores.
                    // NOTE: capabilities are only populated by an explicit read (the 0xF3 read can
                    // wedge panels, so the app never runs it automatically) — until then this takes
                    // the 1...max fallback path.
                    let codes = model.colorPresetCodes(for: display)
                    HStack(spacing: 8) {
                        #if !PUBLIC_API_ONLY
                        if model.ddcCapabilities[display.recordID] == nil {
                            Button(detectingModes ? "Определение…" : "Определить…") { detectModes() }
                                .buttonStyle(.link).controlSize(.small)
                                .disabled(detectingModes)
                                .help("Запросить поддерживаемые цветовые режимы")
                        }
                        #endif
                        if codes.isEmpty {
                            Text(model.colorPreset[display.recordID].map { model.presetName($0) } ?? "—")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Menu(model.colorPreset[display.recordID].map { model.presetName($0) } ?? "—") {
                                ForEach(codes, id: \.self) { code in
                                    Button(model.presetName(code)) { model.setColorPreset(code, for: display) }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
                if model.ddcWriteWasIgnored(0x14, for: display), let current = model.colorPreset[display.recordID] {
                    secondaryNote("Монитор сохранил режим «\(model.presetName(current))».")
                }
                #if !PUBLIC_API_ONLY
                if detectFoundNothing {
                    secondaryNote("Монитор не сообщил о возможностях")
                } else if model.ddcCapabilities[display.recordID] == nil {
                    secondaryNote("Запрашивает поддерживаемые режимы. Некоторые мониторы после запроса перестают отвечать по DDC до выключения и включения питания.")
                }
                #endif
            }
            ODDivider()
            ODRow("Цветовой профиль") {
                if model.colorProfileControllable[display.recordID] == true {
                    Menu(model.colorProfileName[display.recordID] ?? "—") {
                        Button("Заводской профиль") { Task { await model.resetColorProfile(for: display) } }
                        Divider()
                        ForEach(model.availableColorProfilesCache) { profile in
                            Button(profile.name) { Task { await model.setColorProfile(profile, for: display) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Text("Недоступно").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        if let reason = model.rotationUnavailableReason {
            Text(reason == "Rotation changes are not safely supported on this macOS version."
                 ? "Безопасный поворот экрана недоступен в этой версии macOS." : reason)
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
    }

    private func secondaryNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Explicit, user-initiated capabilities read (the 0xF3 read is never run automatically — see
    /// `AppModel.refreshCapabilities`). Re-reads the preset afterwards so the menu, now narrowed to
    /// the advertised codes, shows the panel's real current mode.
    private func detectModes() {
        detectingModes = true
        detectFoundNothing = false
        Task {
            await model.refreshCapabilities(for: display)
            await model.refreshColorPreset(for: display)
            detectingModes = false
            guard model.ddcCapabilities[display.recordID] == nil else { return }
            detectFoundNothing = true
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            detectFoundNothing = false
        }
    }
}

// MARK: - Hardware controls (DDC, external only)

struct ControlsCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var confirmingReset = false
    @State private var resetting = false

    /// Shown under a slider whose last write the panel answered with a different value.
    private static let ignoredNote = "Монитор не применил изменение. Текущий режим изображения может блокировать эту настройку."

    var body: some View {
        ODCard(title: "Управление",
               footnote: "Аппаратные команды передаются по DDC/CI. Поддержка зависит от монитора.") {
            // Brightness first, and always: it has a software fallback, so it's usable even on a
            // panel that reports none of the DDC extras below. Same model funnel as the popover.
            ODRow("Яркость", secondary: model.brightnessCaption(for: display)) {
                sliderWithReadout(level: model.brightness[display.recordID] ?? 1) { value in
                    model.setBrightness(value, for: display)
                }
            }
            Toggle("Использовать программную яркость для этого монитора", isOn: Binding(
                get: { model.settings.softwareBrightnessDisplayIDs.contains(display.recordID.rawValue) },
                set: { enabled in Task { await model.setSoftwareBrightness(enabled, for: display) } }))
                .font(.caption)
            Text("Включите, если значения DDC меняются, а изображение — нет. Программная яркость использует выбранный ниже способ затемнения.")
                .font(.caption).foregroundStyle(.secondary)
            if model.ddcWriteWasIgnored(0x10, for: display) { ignoredCaption(Self.ignoredNote) }
            ODDivider()
            let controls = HardwareControl.allCases.filter { model.ddcControl($0, for: display) != nil }
            if controls.isEmpty {
                ODRow("Другие аппаратные настройки не обнаружены") {}
                // A panel that answers nothing usually isn't DDC-less — its scaler's DDC channel is
                // often just stuck (a state that survives display sleep; only its own power button
                // clears it). Say so, or "unsupported" reads as a dead feature the user can't act on.
                Text("Если аппаратное управление работало раньше, канал DDC мог зависнуть. Выключите и включите монитор его кнопкой питания, затем откройте эту панель снова.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(controls.enumerated()), id: \.element) { index, control in
                    if index > 0 { ODDivider() }
                    ODRow(control.label) {
                        sliderWithReadout(level: model.ddcControl(control, for: display) ?? 0.5) { value in
                            model.setHardwareControl(control, value, for: display)
                        }
                    }
                    if model.ddcWriteWasIgnored(control.vcp, for: display) { ignoredCaption(Self.ignoredNote) }
                }
            }
            if let caption = model.groupSyncCaption(for: display) {
                ODDivider()
                Text(caption)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            #if !PUBLIC_API_ONLY
            if let status = model.adaptiveStatusLine(for: display) {
                ODDivider()
                Text(status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            #endif
            ODDivider()
            ODRow("Источник сигнала") {
                Menu(model.inputSource[display.recordID].map { model.inputName($0) } ?? "—") {
                    ForEach(AppModel.standardInputs, id: \.code) { input in
                        Button(input.name) { model.setInputSource(input.code, for: display) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            ODDivider()
            ODRow("Питание", secondary: "Некоторые мониторы нельзя разбудить по DDC после выключения") {
                Menu("Применить…") {
                    ForEach(DDCPowerMode.allCases, id: \.self) { mode in
                        Button(mode.label) { model.setPowerMode(mode, for: display) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            #if !PUBLIC_API_ONLY
            ODDivider()
            ODRow("Сброс к заводским настройкам", secondary: "Восстанавливает заводские настройки монитора") {
                Button(resetting ? "Сброс…" : "Сбросить настройки…") { confirmingReset = true }
                    .controlSize(.small)
                    .disabled(resetting)
            }
            #endif
        }
        .confirmationDialog("Сбросить настройки монитора «\(model.displayName(for: display))»?",
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Сбросить настройки", role: .destructive) {
                resetting = true
                Task {
                    await model.resetToDefaults(for: display)
                    resetting = false
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Восстанавливает заводские настройки монитора: яркость, контрастность, цветовой режим и остальные параметры, которые сбрасывает сам монитор. OpenDisplay также снимает программное затемнение и цветовую температуру.")
        }
    }

    private func ignoredCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sliderWithReadout(level: Float, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { Double(level) }, set: { set(Float($0)) }), in: 0...1)
                .frame(width: 160)
            Text("\(Int((level * 100).rounded()))%")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

// MARK: - Software dimming (any display)

struct DimmingCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    /// Gamma alone bottoms out at its floor; the overlay methods can keep going (still capped short
    /// of full black by the composer).
    private var range: ClosedRange<Double> {
        model.settings.dimmingMethod == .gamma ? 0.15...1 : 0...1
    }

    private var footnote: String {
        switch model.settings.dimmingMethod {
        case .gamma:
            return "Программное затемнение гаммой поверх аппаратной яркости. Работает ниже аппаратного минимума."
        case .overlay:
            return "Чёрный слой с регулируемой прозрачностью поверх изображения. Строка меню остаётся доступной для восстановления."
        case .combined:
            return "Сочетает затемнение гаммой и чёрный слой. Темнее каждого способа по отдельности, но не делает экран полностью чёрным."
        }
    }

    var body: some View {
        ODCard(title: "Затемнение", footnote: footnote) {
            ODRow("Программное затемнение") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(model.softwareDim[display.recordID] ?? 1) },
                                          set: { model.setSoftwareDim(Float($0), for: display) }), in: range)
                        .frame(width: 160)
                    Text("\(Int(((model.softwareDim[display.recordID] ?? 1) * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            ODRow("Способ") {
                Picker("", selection: Binding(
                    get: { model.settings.dimmingMethod },
                    set: { model.setDimmingMethod($0) })) {
                    Text("Гамма").tag(DimmingMethod.gamma)
                    Text("Чёрный слой").tag(DimmingMethod.overlay)
                    Text("Комбинированный").tag(DimmingMethod.combined)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
    }
}

// MARK: - Use as

struct UseAsCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        ODCard(title: "Роль монитора") {
            ODRow("Сделать основным монитором", secondary: "Здесь будут строка меню и Dock") {
                Toggle("", isOn: Binding(get: { display.isMain },
                                         set: { on in if on { Task { await model.setMain(for: display) } } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(display.isMain || model.busy)
            }
            if !display.isMain {
                ODDivider()
                ODRow("Дублировать основной монитор") {
                    Toggle("", isOn: Binding(get: { display.isMirrored },
                                             set: { on in Task { await model.setMirrored(on, for: display) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.busy)
                }
            }
            ODDivider()
            ODRow("Отключить монитор", secondary: "Логическое отключение с возможностью подключения") {
                Button("Отключить", role: .destructive) {
                    Task { await model.setDisplayActive(false, for: display) }
                }
                .controlSize(.small)
                .disabled(model.busy || model.activeDisplayCount <= 1)
            }
        }
    }
}

// MARK: - Identity (rename)

private struct IdentityCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var alias = ""

    var body: some View {
        ODCard(title: "Название") {
            ODRow("Название монитора") {
                TextField(model.displayName(for: display), text: $alias)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { Task { await model.setAlias(alias, for: display) } }
            }
        }
        // Re-seed when the segmented picker switches displays: the view keeps its identity, so an
        // onAppear-only seed would let Enter rename the new display with the previous one's alias.
        .onChange(of: display.recordID, initial: true) { alias = model.records[display.recordID]?.alias ?? "" }
    }
}

// MARK: - Information (read-only)

struct InformationCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        ODCard(title: "Информация") {
            let info = model.displayInfo(for: display)
            ForEach(Array(info.enumerated()), id: \.element.label) { index, item in
                if index > 0 { ODDivider() }
                ODRow(item.label) {
                    Text(item.value).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
#endif
