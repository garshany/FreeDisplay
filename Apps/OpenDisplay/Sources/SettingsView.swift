#if os(macOS)
import AppKit
import CoreGraphicsProvider
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore
#if !PUBLIC_API_ONLY
import VirtualDisplayProvider
#endif

/// Settings window. A sidebar (Displays · Arrange · Scenes · Health & Recovery · About) replaces the
/// old 3-tab shell: "Displays" is now a selection list feeding a per-display detail pane (so the
/// topology isn't duplicated with the menu bar), "Arrange" is promoted out of Scenes into its own
/// item, and diagnostics/recovery/Labs are unified under "Health & Recovery". "About" sits directly
/// below Health & Recovery and mirrors the standalone About window (`AboutView`) as an inline card.
/// See `Docs/InterfaceRedesign.md`.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: SettingsSection? = .displays
#if !PUBLIC_API_ONLY
    @StateObject private var virtualSession = VirtualDisplaySession()
#endif

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            switch section ?? .displays {
            case .displays: DisplaysSection()
            case .arrange: ArrangeSection()
            case .scenes: ScenesSection()
            case .capture:
                ScrollView {
                    CapturePanel()
                        .padding(ODSpacing.lg)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .navigationTitle("Захват экрана")
            case .advanced:
                if let display = model.displays.first(where: { $0.recordID == model.selectedDisplayID }) ?? model.displays.first,
                   let id = display.cgDisplayID {
                    AdvancedDisplayToolsView(displayID: id, displayName: model.displayName(for: display))
                } else {
                    ContentUnavailableView("Сначала выберите подключённый монитор.", systemImage: "display")
                        .navigationTitle("EDID и HiDPI")
                }
            case .automation: LocalControlPanel()
            case .virtual:
#if !PUBLIC_API_ONLY
                ScrollView {
                    VirtualDisplaysSettingsView(
                        safeMode: ProcessInfo.processInfo.arguments.contains("--safe-mode"),
                        session: virtualSession)
                        .padding(ODSpacing.lg)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .navigationTitle("Виртуальные экраны")
#else
                Text("Создание виртуальных мониторов недоступно в сборке только с публичными API.")
                    .padding(ODSpacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationTitle("Виртуальные экраны")
#endif
            case .health: HealthSection()
            case .about: AboutSection()
            }
        }
        .frame(minWidth: 720, idealWidth: 720, minHeight: 480, idealHeight: 520)
        .task {
            await model.refreshDiagnostics()
            await model.refreshActivity()
        }
        // Deep-link from the menu bar's "Display settings…": jump to the Displays section so the
        // selected display is shown even if Settings was already open on another section.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenDisplayShowSection"))) { notification in
            if let value = notification.object as? String, let destination = SettingsSection(rawValue: value) {
                section = destination
            }
        }
        .onChange(of: model.selectedDisplayID) { _, newValue in
            if newValue != nil { section = .displays }
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case displays, arrange, scenes, virtual, capture, advanced, automation, health, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .displays: return "Мониторы"
        case .arrange: return "Расположение"
        case .scenes: return "Сцены"
        case .virtual: return "Виртуальные экраны"
        case .capture: return "Захват экрана"
        case .advanced: return "EDID и HiDPI"
        case .automation: return "Автоматизация"
        case .health: return "Диагностика"
        case .about: return "О программе"
        }
    }
    var icon: String {
        switch self {
        case .displays: return "display"
        case .arrange: return "rectangle.3.group"
        case .scenes: return "square.stack.3d.up"
        case .virtual: return "display.2"
        case .capture: return "pip"
        case .advanced: return "slider.horizontal.3"
        case .automation: return "terminal"
        case .health: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Displays (selection list → detail pane)

private struct DisplaysSection: View {
    @EnvironmentObject private var model: AppModel

    private var selected: DisplayObservation? {
        model.displays.first { $0.recordID == model.selectedDisplayID }
            ?? model.displays.first { $0.isMain }
            ?? model.displays.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.displays.isEmpty {
                ContentUnavailableView("Мониторы не обнаружены", systemImage: "display.trianglebadge.exclamationmark")
            } else {
                if model.displays.count > 1 {
                    Picker("", selection: Binding(
                        get: { selected?.recordID ?? model.displays.first?.recordID },
                        set: { model.selectedDisplayID = $0 })) {
                        ForEach(model.displays, id: \.recordID) { display in
                            Text(model.displayName(for: display)).tag(Optional(display.recordID))
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .padding(.horizontal, 16).padding(.top, 16)
                }
                if let display = selected {
                    DisplayDetailView(display: display)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Мониторы")
    }
}

// MARK: - Arrange

private struct ArrangeSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ODSpacing.md) {
                DisplayArrangementView()
                Text("Перетащите монитор, чтобы изменить расположение. Изменения применяются сразу; сохраните расположение в разделе «Сцены».")
                    .font(.caption).foregroundStyle(.secondary)
                ODDivider()
                ProtectedLayoutCard()
            }
            .padding(ODSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Расположение мониторов")
    }
}

// MARK: - Protected layout (Batch-4 #A)

/// "Keep this arrangement": protects the layout for the display set currently on the desk, and lists
/// the other sets that already have one. Protection is per display set, so laptop-alone and
/// laptop-plus-desk each keep their own arrangement.
private struct ProtectedLayoutCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            Text("Защищённое расположение").font(.title3)
            Toggle(isOn: Binding(
                get: { model.settings.layoutProtectionEnabled },
                set: { model.setLayoutProtectionEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Восстанавливать расположение при изменениях")
                    Text("Если macOS или другое приложение меняет расположение, разрешение или основной монитор, защищённая конфигурация восстанавливается, включая отключённые мониторы. Отключённый в OpenDisplay монитор остаётся отключённым после сна независимо от этой настройки.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.settings.layoutProtectionEnabled {
                CurrentLayoutProtectionRow()
                OtherProtectedLayoutsList()
            }
        }
    }
}

private struct CurrentLayoutProtectionRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ODCard {
            ODRow("Этот набор мониторов", secondary: status) {
                HStack(spacing: 8) {
                    Button(model.protectedLayoutForCurrentSet == nil ? "Защитить текущее расположение" : "Обновить") {
                        Task { await model.protectCurrentLayout() }
                    }
                    .controlSize(.small).disabled(model.busy)
                    if model.protectedLayoutForCurrentSet != nil {
                        Button("Удалить") {
                            model.removeProtectedLayout(fingerprint: model.currentLayoutFingerprint)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var status: String {
        guard let protected = model.protectedLayoutForCurrentSet else { return "Не защищено" }
        // Members, not observations: a display the arrangement keeps switched off is one of the
        // displays it covers, and on the experimental path it left no observation behind to count.
        let count = LayoutProtectionPolicy.members(of: protected).count
        return "Защищено · мониторов: \(count) · сохранено "
            + protected.capturedAt.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The layouts stored for display sets that aren't on the desk right now — a docked setup you
/// protected last week is still listed (and removable) while you're on the road.
private struct OtherProtectedLayoutsList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let others = model.settings.protectedLayouts
            .filter { $0.key != model.currentLayoutFingerprint }
            .sorted { $0.key < $1.key }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: ODSpacing.xs) {
                Text("Другие защищённые расположения").font(.caption).foregroundStyle(.secondary)
                ODCard {
                    ForEach(Array(others.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 { ODDivider() }
                        ODRow(memberNames(of: entry.value),
                              secondary: "сохранено " + entry.value.capturedAt.formatted(
                                .dateTime.month(.abbreviated).day())) {
                            Button(role: .destructive) {
                                model.removeProtectedLayout(fingerprint: entry.key)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    /// Names every member the arrangement covers, switched-off displays included. Those displays are
    /// absent from the desk (and, when truly disabled, from the stored snapshot too), so the
    /// remembered-display index is what names them.
    private func memberNames(of config: ProtectedConfig) -> String {
        LayoutProtectionPolicy.members(of: config)
            .map { model.rememberedDisplayName(for: $0) }
            .sorted()
            .joined(separator: " + ")
    }
}

// MARK: - Scenes

private struct ScenesSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ODSpacing.md) {
                if let warning = model.sceneWarning {
                    ODInlineBanner(tone: .orange, systemImage: "exclamationmark.triangle", title: warning)
                }
                if model.scenes.isEmpty {
                    Text("Пока нет сохранённых сцен. Расположите мониторы и сохраните текущую конфигурацию ниже.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ODCard {
                        ForEach(Array(model.scenes.enumerated()), id: \.element.id) { index, scene in
                            if index > 0 { ODDivider() }
                            ODRow(scene.name, secondary: "Мониторов: \(scene.members.count)") {
                                HStack(spacing: 8) {
                                    Button("Применить") { Task { await model.applyScene(scene) } }
                                        .controlSize(.small).disabled(model.busy)
                                    Button(role: .destructive) {
                                        Task { await model.deleteScene(scene) }
                                    } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                SaveSceneRow()
            }
            .padding(ODSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Сцены")
    }
}

private struct SaveSceneRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""

    var body: some View {
        HStack(spacing: ODSpacing.sm) {
            TextField("Название новой сцены", text: $name).textFieldStyle(.roundedBorder)
            Button("Сохранить текущее расположение") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                Task { await model.saveScene(named: trimmed); name = "" }
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Diagnostics bundle export

/// "Export diagnostics…" — builds the bundle a bug report needs (`DiagnosticsBundle`) on the
/// Desktop and reveals it. Lists exactly what goes in before the user clicks, because the file is
/// meant to be attached to a public issue.
private struct DiagnosticsExportSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var exporting = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            Text("Диагностика").font(.title3)
            Text("Если монитор работает неправильно, экспортируйте диагностику и приложите файл к обращению. Файл сохраняется на рабочий стол и никуда не отправляется. Он содержит:")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(DiagnosticsBundle.contents, id: \.self) { item in
                Text("\u{2022} " + item).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: ODSpacing.sm) {
                Button {
                    exporting = true
                    result = nil
                    Task {
                        let url = await model.exportDiagnostics()
                        exporting = false
                        if let url {
                            result = "Файл \(url.lastPathComponent) сохранён на рабочий стол."
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            result = "Не удалось записать файл диагностики."
                        }
                    }
                } label: {
                    Label(exporting ? "Сбор данных\u{2026}" : "Экспортировать диагностику\u{2026}",
                          systemImage: "square.and.arrow.up")
                }
                .disabled(exporting)
                if exporting { ProgressView().controlSize(.small) }
            }
            if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Health & Recovery (diagnostics + recovery + Labs + activity)

private struct HealthSection: View {
    @EnvironmentObject private var model: AppModel

    private func diagnosticStatus(_ value: String) -> String {
        switch value {
        case "supported": return "поддерживается"
        case "unsupported": return "не поддерживается"
        case "degraded": return "ограниченная поддержка"
        case "unavailable": return "недоступно"
        default: return value
        }
    }

    private func diagnosticRisk(_ value: String) -> String {
        switch value {
        case "low": return "низкий"
        case "medium": return "средний"
        case "high": return "высокий"
        default: return value
        }
    }

    /// A DatePicker binding over a minutes-since-midnight Int setting (the schedule fields store
    /// minutes so the cross-platform policy never touches Calendar). Anchored to a fixed reference
    /// day; only the hour/minute components round-trip.
    private func minuteBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding<Date>(
            get: {
                let base = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
                return Calendar.current.date(byAdding: .minute, value: get(), to: base) ?? base
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ODSpacing.md) {
                Text("Провайдеры").font(.title3)
                ForEach(model.diagnostics) { row in
                    HStack(spacing: ODSpacing.sm) {
                        Image(systemName: row.status == "supported" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(row.status == "supported" ? ODColor.connected : ODColor.caution)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.provider)
                            Text("\(diagnosticStatus(row.status)) · риск \(diagnosticRisk(row.risk))\(row.reasons.isEmpty ? "" : " · \(row.reasons.joined(separator: ", "))")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if row.experimental { ODBadge("Экспериментальные функции", tone: .orange) }
                        Spacer()
                    }
                }

                Divider()

                Text("Восстановление").font(.title3)
                LabeledContent("Политика сохранения", value: model.settings.persistencePolicy == .reconnectOnQuit ? "Подключать при выходе" : model.settings.persistencePolicy == .reconnectOnWake ? "Подключать при пробуждении" : "Сохранять отключение")
                LabeledContent("Глобальная горячая клавиша",
                               value: model.settings.reconnectAllHotkeyEnabled ? model.reconnectAllHotkey : "выключено")
                LabeledContent("Контрольные точки", value: model.checkpointLocation)
                Button {
                    Task { await model.reconnectAll() }
                } label: {
                    Label("Подключить все снова", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.busy)

                Divider()

                DiagnosticsExportSection()

                Divider()

                InputHotkeySection()

                Divider()

                Text("Поведение").font(.title3)
                LaunchAtLoginToggle()
                Toggle(isOn: Binding(
                    get: { model.settings.preventDisplaySleepWithExternal },
                    set: { model.setPreventDisplaySleepWithExternal($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Не усыплять мониторы, пока подключён внешний")
                        Text("Не даёт экранам уходить в сон, пока подключён хотя бы один внешний монитор. Блокировка автоматически снимается после отключения последнего внешнего монитора.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { model.settings.autoDisconnectBuiltInOnExternal },
                    set: { model.setAutoDisconnectBuiltInOnExternal($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Отключать встроенный экран при подключении внешнего")
                        Text("Автоматически отключает встроенный экран при подключении внешнего через тот же безопасный механизм, что и ручное отключение. Встроенный экран включается после отключения последнего внешнего.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { model.settings.displayNotificationsEnabled },
                    set: { model.setDisplayNotificationsEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Уведомлять о подключении и отключении мониторов")
                        Text("Показывает системные уведомления о подключении и отключении внешнего монитора и автоматическом отключении встроенного экрана. При первом включении запрашивает разрешение на уведомления.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if Bundle.main.object(forInfoDictionaryKey: "OpenDisplayLocalBuild") as? Bool == true {
                    Text("Обновление локальной сборки").font(.headline)
                    Text("Эта сборка обновляется из исходников: загрузите изменения проекта, соберите приложение и замените установленную версию. Автоматическая загрузка выпусков здесь недоступна.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle(isOn: Binding(
                        get: { model.settings.updateCheckEnabled },
                        set: { model.setUpdateCheckEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Проверять обновления автоматически")
                            Text("Проверяет список выпусков примерно раз в сутки и показывает обновления в меню. Загрузка начинается только с вашего согласия. Ручная проверка доступна всегда.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { model.settings.automaticUpdateDownloadEnabled },
                        set: { model.setAutomaticUpdateDownloadEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Скачивать и устанавливать обновления автоматически")
                            Text("Автоматически устанавливает новый выпуск и перезапускает OpenDisplay. Перед запуском проверяется подпись загрузки. Требует включённой автоматической проверки.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!model.settings.updateCheckEnabled)
                    .padding(.leading, ODSpacing.lg)
                }

                Divider()

                Text("Экранный индикатор").font(.title3)
                Toggle(isOn: Binding(
                    get: { model.settings.osdEnabled },
                    set: { model.setOSDEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Показывать индикатор яркости и громкости")
                        Text("Показывает индикатор на выбранном мониторе при изменении яркости или громкости через меню или клавиши.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.settings.osdEnabled {
                    HStack {
                        Picker("Стиль", selection: Binding(
                            get: { model.settings.osdStyle }, set: { model.setOSDStyle($0) })) {
                            Text("Системный").tag(OSDStyle.native)
                            Text("Минимальный").tag(OSDStyle.minimal)
                            Text("Классический").tag(OSDStyle.classicTahoe)
                            Text("Только внешний индикатор").tag(OSDStyle.external)
                        }
                        .fixedSize()
                        Picker("Положение", selection: Binding(
                            get: { model.settings.osdPosition }, set: { model.setOSDPosition($0) })) {
                            Text("Внизу").tag(OSDPosition.bottomCenter)
                            Text("Вверху").tag(OSDPosition.topCenter)
                            Text("По центру").tag(OSDPosition.center)
                        }
                        .fixedSize()
                    }
                }
                Toggle(isOn: Binding(
                    get: { model.settings.publishOSDEventsEnabled },
                    set: { model.setPublishOSDEventsEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Передавать события приложениям внешних индикаторов")
                        Text("Передаёт изменения яркости и громкости через распределённое уведомление dev.opendisplay.osd для внешних индикаторов. По умолчанию выключено.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text("Мультимедийные клавиши").font(.title3)
                Toggle(isOn: Binding(
                    get: { model.settings.mediaKeyInterceptionEnabled },
                    set: { model.setMediaKeyInterceptionEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Управлять мониторами клавишами яркости и громкости")
                        Text("Клавиши яркости управляют выбранным монитором через аппаратный или программный способ. Клавиши громкости используют DDC только если звук идёт через этот монитор. Для перехвата нужен доступ в разделе «Универсальный доступ»; разрешение запрашивается после включения.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.settings.mediaKeyInterceptionEnabled {
                    Picker("Клавиши яркости управляют", selection: Binding(
                        get: { model.settings.mediaKeyTargetMode }, set: { model.setMediaKeyTargetMode($0) })) {
                        Text("Монитором под указателем").tag(MediaKeyTargetMode.underCursor)
                        Text("Основным монитором").tag(MediaKeyTargetMode.mainDisplay)
                        Text("Встроенным экраном").tag(MediaKeyTargetMode.builtInAlways)
                        Text("Только внешними мониторами").tag(MediaKeyTargetMode.externalOnly)
                    }
                    .fixedSize()
                    Toggle("Требовать Shift для клавиш яркости", isOn: Binding(
                        get: { model.settings.brightnessMediaKeysRequireShift },
                        set: { model.setBrightnessMediaKeysRequireShift($0) }))
                    Text("Клавиши громкости управляют текущим устройством вывода звука.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !MediaKeyTap.isAccessibilityTrusted {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Для перехвата клавиш нужен доступ в разделе «Универсальный доступ».")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Открыть настройки универсального доступа\u{2026}") { openAccessibilitySettings() }
                                .controlSize(.small)
                        }
                    } else {
                        Text(model.mediaKeysActive ? "Перехват мультимедийных клавиш работает." : "Доступ разрешён, но перехват недоступен. Повторная попытка…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Повторить запуск перехвата клавиш") { model.retryMediaKeyCapture() }
                }

                #if !PUBLIC_API_ONLY
                Divider()

                HStack(spacing: 8) {
                    Text("Адаптивное управление").font(.title3)
                    ODBadge("Экспериментальные функции", tone: .orange)
                }
                Toggle(isOn: Binding(
                    get: { model.settings.adaptiveBrightnessSyncEnabled },
                    set: { model.setAdaptiveBrightnessSyncEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Синхронизировать яркость внешнего монитора со встроенным")
                        Text("Синхронизирует аппаратную яркость внешнего монитора со встроенным по DDC. Ручное изменение задаёт смещение и приостанавливает синхронизацию на минуту. При закрытой крышке используется расписание. Изменения кнопками монитора не отслеживаются. Мониторами в группе управляет группа.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { model.settings.adaptiveWarmthEnabled },
                    set: { model.setAdaptiveWarmthEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Делать цвета монитора теплее вечером")
                        Text("Вечером включает тёплый аппаратный цветовой режим, утром возвращает дневной. Следует состоянию Night Shift, если оно доступно, иначе использует расписание.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.settings.adaptiveWarmthEnabled {
                    Picker("Вечерний режим", selection: Binding(
                        get: { model.settings.adaptiveEveningPreset },
                        set: { model.setAdaptiveEveningPreset($0) })) {
                        ForEach([1, 2, 3, 4, 5], id: \.self) { code in
                            Text(model.presetName(code)).tag(code)
                        }
                    }
                    .fixedSize()
                }
                Toggle(isOn: Binding(
                    get: { model.settings.adaptiveLocationModeEnabled },
                    set: { model.setAdaptiveLocationModeEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Учитывать положение солнца")
                        Text("Меняет яркость по высоте солнца для указанного местоположения: темнее на рассвете и закате, ярче днём. Встроенный экран и датчик освещения имеют приоритет, если доступны. Явное расписание всегда имеет высший приоритет.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.settings.adaptiveLocationModeEnabled, !model.settings.clockScheduleEnabled {
                    ClockLocationRow()
                }
                if model.settings.adaptiveBrightnessSyncEnabled || model.settings.adaptiveWarmthEnabled {
                    HStack(spacing: 16) {
                        DatePicker("Начало дня", selection: minuteBinding(
                            get: { model.settings.adaptiveDayStartMinute },
                            set: { model.setAdaptiveSchedule(dayStartMinute: $0,
                                                             nightStartMinute: model.settings.adaptiveNightStartMinute,
                                                             transitionMinutes: model.settings.adaptiveTransitionMinutes) }),
                                   displayedComponents: .hourAndMinute)
                        DatePicker("Начало вечера", selection: minuteBinding(
                            get: { model.settings.adaptiveNightStartMinute },
                            set: { model.setAdaptiveSchedule(dayStartMinute: model.settings.adaptiveDayStartMinute,
                                                             nightStartMinute: $0,
                                                             transitionMinutes: model.settings.adaptiveTransitionMinutes) }),
                                   displayedComponents: .hourAndMinute)
                        Stepper("Переход: \(model.settings.adaptiveTransitionMinutes) мин",
                                value: Binding(
                                    get: { model.settings.adaptiveTransitionMinutes },
                                    set: { model.setAdaptiveSchedule(dayStartMinute: model.settings.adaptiveDayStartMinute,
                                                                     nightStartMinute: model.settings.adaptiveNightStartMinute,
                                                                     transitionMinutes: $0) }),
                                in: 5...120, step: 5)
                    }
                    .fixedSize()
                    if model.settings.adaptiveBrightnessSyncEnabled {
                        HStack(spacing: 16) {
                            Stepper("Дневная яркость: \(Int((model.settings.adaptiveFallbackDayLevel * 100).rounded()))%",
                                    value: Binding(
                                        get: { Double(model.settings.adaptiveFallbackDayLevel) },
                                        set: { model.setAdaptiveFallbackLevels(day: Float($0),
                                                                               night: model.settings.adaptiveFallbackNightLevel) }),
                                    in: 0.1...1, step: 0.05)
                            Stepper("Ночная яркость: \(Int((model.settings.adaptiveFallbackNightLevel * 100).rounded()))%",
                                    value: Binding(
                                        get: { Double(model.settings.adaptiveFallbackNightLevel) },
                                        set: { model.setAdaptiveFallbackLevels(day: model.settings.adaptiveFallbackDayLevel,
                                                                               night: Float($0)) }),
                                    in: 0.1...1, step: 0.05)
                        }
                        .fixedSize()
                    }
                    Text("Источники яркости по приоритету: активный встроенный экран, датчик освещения при открытой крышке, расписание при закрытой крышке. Тёплый режим использует расписание, если состояние Night Shift недоступно.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()
                ClockModeCard()

                Divider()
                AppPresetsCard()
                #endif

                Divider()

                Text("Экспериментальные функции").font(.title3)
                #if !PUBLIC_API_ONLY
                Toggle(isOn: $model.experimentalRotationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Экспериментальный поворот экрана")
                        Text("Поворачивает экраны через закрытый API. По умолчанию выключено; используется изолированный помощник с проверками безопасности и автоматическим откатом. Недоступно в сборках App Store.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                #endif
                // Public Metal/CG only, so unlike the rotation toggle above this stays in the
                // public-API-only build too.
                Toggle(isOn: Binding(
                    get: { model.settings.xdrBrightnessEnabled },
                    set: { model.setXDRBrightnessEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Яркость XDR")
                        Text("Использует запас яркости встроенного XDR-экрана для SDR. Экспериментально: HDR может терять детали, а длительная максимальная яркость нагревает панель. Усиление сбрасывается при выходе.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.settings.xdrBrightnessEnabled {
                    XDRPowerAutomationRows()
                }

                Divider()

                Text("Последние действия").font(.title3)
                if model.recentActivity.isEmpty {
                    Text("Пока нет записанных действий.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.recentActivity.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: ODSpacing.sm) {
                            Text(entry.command).font(.caption).bold()
                            Text(entry.status).font(.caption).foregroundStyle(.secondary)
                            if !entry.targets.isEmpty {
                                Text(entry.targets.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(ODSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Диагностика и восстановление")
    }
}

// MARK: - XDR Brightness power automations (Issue #35)

/// The rules that turn an XDR boost back off on their own, shown under the Labs toggle only while
/// XDR Brightness is on — they are meaningless otherwise, and the Labs section is long enough.
///
/// Indented under the feature they qualify, like the automatic-update row under its check toggle.
/// The restore row is last and reads as the softener it is: it only ever undoes the three rules
/// above it, and the auto-off timer deliberately isn't one of them.
private struct XDRPowerAutomationRows: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.settings.xdrDisableOnBattery },
                set: { model.setXDRDisableOnBattery($0) }
            )) {
                Text("Отключать при питании от аккумулятора")
            }
            Toggle(isOn: Binding(
                get: { model.settings.xdrDisableInLowPowerMode },
                set: { model.setXDRDisableInLowPowerMode($0) }
            )) {
                Text("Отключать в режиме энергосбережения")
            }
            HStack(spacing: 16) {
                Picker("Отключать при заряде ниже", selection: Binding(
                    get: { model.settings.xdrLowBatteryCutoffPercent },
                    set: { model.setXDRLowBatteryCutoffPercent($0) })) {
                    Text("Никогда").tag(Int?.none)
                    ForEach(XDRPowerAutomation.lowBatteryCutoffOptions, id: \.self) { percent in
                        Text("\(percent)% заряда").tag(Int?.some(percent))
                    }
                }
                .fixedSize()
                Picker("Отключать через", selection: Binding(
                    get: { model.settings.xdrAutoOffMinutes },
                    set: { model.setXDRAutoOffMinutes($0) })) {
                    Text("Никогда").tag(Int?.none)
                    ForEach(XDRPowerAutomation.autoOffMinuteOptions, id: \.self) { minutes in
                        Text(Self.durationLabel(minutes)).tag(Int?.some(minutes))
                    }
                }
                .fixedSize()
            }
            Toggle(isOn: Binding(
                get: { model.settings.xdrRestoreOnPower },
                set: { model.setXDRRestoreOnPower($0) }
            )) {
                Text("Восстанавливать усиление при подключении питания")
            }
            Text("Эти условия отключают усиление для экономии аккумулятора. После восстановления питания можно вернуть прежний уровень, если вы не меняли его вручную. Таймер не сбрасывает уже потраченное время.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, ODSpacing.lg)
    }

    /// "30 min" / "1 hour" / "2 hours" — minutes below an hour, whole hours above.
    private static func durationLabel(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) мин" }
        let hours = minutes / 60
        return hours == 1 ? "1 час" : "\(hours) ч"
    }
}

// MARK: - About (mirrors the standalone About window as an inline Settings card)

private struct AboutSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ODSpacing.md) {
                ODCard {
                    AppIdentityRow()
                    ODDivider()
                    UpdateCheckRow()
                    ForEach(AboutView.projectLinks) { link in
                        ODDivider()
                        ProjectLinkRow(link: link)
                    }
                }
            }
            .padding(ODSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("О программе")
    }
}

/// App icon, name, and running version/build — the same bundle-info source `AboutView` reads.
private struct AppIdentityRow: View {
    var body: some View {
        ODRow("OpenDisplay", secondary: "Версия \(AboutView.version) (сборка \(AboutView.build))") {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } trailing: {
            EmptyView()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The check-for-updates affordance, reusing the same `UpdateCheckStatusView` the About window shows.
private struct UpdateCheckRow: View {
    var body: some View {
        ODRow("Обновления") {
            EmptyView()
        } trailing: {
            UpdateCheckStatusView()
        }
    }
}

/// One project link (GitHub, release notes, issues, license) shown as a Settings row.
private struct ProjectLinkRow: View {
    let link: AboutView.AboutLink

    var body: some View {
        ODRow(link.title, action: { NSWorkspace.shared.open(link.url) }) {
            ODGlyphTile(link.systemImage)
        } trailing: {
            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
        }
        .accessibilityHint("Откроется в браузере")
    }
}

// MARK: - Arrange canvas (drag-to-position)

/// The drag-to-arrange canvas: each active display is a proportionally-sized, positioned tile
/// (mirroring System Settings › Displays › Arrange). Dropping a tile applies its new origin live;
/// Core Graphics then re-snaps the layout so displays stay adjacent and the canvas re-renders.
private struct DisplayArrangementView: View {
    @EnvironmentObject private var model: AppModel
    private let canvas = CGSize(width: 480, height: 210)

    var body: some View {
        let tiles = model.displays.compactMap { display -> (DisplayObservation, CGRect)? in
            guard let mode = display.mode, display.isActive else { return nil }
            return (display, CGRect(x: CGFloat(display.origin.x), y: CGFloat(display.origin.y),
                                    width: CGFloat(mode.pointWidth), height: CGFloat(mode.pointHeight)))
        }
        let union = tiles.map(\.1).reduce(CGRect.null) { $0.union($1) }
        let scale: CGFloat = (union.isNull || union.width < 1 || union.height < 1)
            ? 0.05
            : min(canvas.width / union.width, canvas.height / union.height) * 0.82

        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
            ForEach(tiles, id: \.0.recordID) { display, frame in
                DisplayTile(
                    display: display,
                    tileSize: CGSize(width: frame.width * scale, height: frame.height * scale),
                    center: CGPoint(x: (frame.midX - union.midX) * scale + canvas.width / 2,
                                    y: (frame.midY - union.midY) * scale + canvas.height / 2),
                    scale: scale)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

private struct DisplayTile: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    let tileSize: CGSize
    let center: CGPoint
    let scale: CGFloat
    @State private var drag: CGSize = .zero

    var body: some View {
        let tint = display.isMain ? Color.accentColor : Color.secondary
        RoundedRectangle(cornerRadius: 4)
            .fill(tint.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint, lineWidth: display.isMain ? 2 : 1))
            .overlay(
                VStack(spacing: 1) {
                    Text(model.displayName(for: display)).font(.caption2).lineLimit(1).padding(.horizontal, 3)
                    if display.isMain { Text("Основной").font(.system(size: 8)).foregroundStyle(.secondary) }
                }
            )
            .frame(width: max(tileSize.width, 36), height: max(tileSize.height, 24))
            .position(x: center.x + drag.width, y: center.y + drag.height)
            .gesture(
                DragGesture()
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        let dx = Int((value.translation.width / scale).rounded())
                        let dy = Int((value.translation.height / scale).rounded())
                        drag = .zero
                        guard dx != 0 || dy != 0 else { return }
                        let origin = DisplayOrigin(x: display.origin.x + dx, y: display.origin.y + dy)
                        Task { await model.setPosition(origin, for: display) }
                    }
            )
    }
}

#if !PUBLIC_API_ONLY
// MARK: - Clock Mode (Issue 30)

/// Clock Mode editor: enable the schedule, manage time/solar-anchored brightness points, and set the
/// location that solar anchors resolve against. Precedence note is shown inline so the user knows
/// Clock Mode outranks Adaptive brightness sync when both are on.
private struct ClockModeCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            Text("Расписание яркости").font(.title3)
            Toggle(isOn: Binding(
                get: { model.settings.clockScheduleEnabled },
                set: { model.setClockScheduleEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Менять яркость по расписанию")
                    Text("Меняет яркость внешних мониторов в заданное время или относительно восхода, полудня и заката, со смещением и плавными переходами. Индикатор не показывается. Это расписание имеет приоритет над адаптивной синхронизацией.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.settings.clockScheduleEnabled {
                ClockScheduleList()
                ClockLocationRow()
            }
        }
    }
}

private struct ClockScheduleList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            if model.settings.clockScheduleEntries.isEmpty {
                Text("Пока нет точек расписания. Добавьте, например, яркость 70% за 30 минут до восхода.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ODCard {
                    ForEach(Array(model.settings.clockScheduleEntries.enumerated()),
                            id: \.element.id) { index, entry in
                        if index > 0 { ODDivider() }
                        ClockScheduleEntryRow(entry: entry)
                    }
                }
            }
            Button {
                model.upsertClockScheduleEntry(
                    ClockScheduleEntry(anchor: .time, timeMinute: 8 * 60, brightness: 0.7,
                                       transition: .ramp))
            } label: {
                Label("Добавить точку расписания", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }
}

private struct ClockScheduleEntryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: ClockScheduleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: ODSpacing.sm) {
                Picker("", selection: anchorBinding) {
                    Text("Время").tag(ScheduleAnchor.time)
                    Text("Восход").tag(ScheduleAnchor.sunrise)
                    Text("Солнечный полдень").tag(ScheduleAnchor.solarNoon)
                    Text("Закат").tag(ScheduleAnchor.sunset)
                }
                .labelsHidden().fixedSize()

                if entry.anchor == .time {
                    DatePicker("", selection: hourMinuteBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden().fixedSize()
                } else {
                    Stepper(offsetLabel, value: offsetBinding, in: -180...180, step: 5)
                        .fixedSize()
                }
                Spacer()
                Button(role: .destructive) {
                    model.deleteClockScheduleEntry(entry)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: ODSpacing.sm) {
                Stepper("Яркость: \(Int((entry.brightness * 100).rounded()))%",
                        value: brightnessBinding, in: 0...1, step: 0.05)
                    .fixedSize()
                Picker("", selection: transitionBinding) {
                    Text("Мгновенно").tag(ScheduleTransition.instant)
                    Text("Переход за 30 минут").tag(ScheduleTransition.ramp)
                    Text("Плавно").tag(ScheduleTransition.continuous)
                }
                .labelsHidden().fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private var offsetLabel: String {
        let minutes = entry.offsetMinutes
        if minutes == 0 { return "в указанное время" }
        return minutes < 0 ? "за \(-minutes) мин до события" : "через \(minutes) мин после события"
    }

    private var anchorBinding: Binding<ScheduleAnchor> {
        Binding(get: { entry.anchor }, set: { updated in updating { $0.anchor = updated } })
    }
    private var transitionBinding: Binding<ScheduleTransition> {
        Binding(get: { entry.transition }, set: { updated in updating { $0.transition = updated } })
    }
    private var offsetBinding: Binding<Int> {
        Binding(get: { entry.offsetMinutes }, set: { updated in updating { $0.offsetMinutes = updated } })
    }
    private var brightnessBinding: Binding<Double> {
        Binding(get: { Double(entry.brightness) },
                set: { updated in updating { $0.brightness = Float(updated) } })
    }
    private var hourMinuteBinding: Binding<Date> {
        Binding(
            get: {
                let base = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
                return Calendar.current.date(byAdding: .minute, value: entry.timeMinute, to: base) ?? base
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                updating { $0.timeMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0) }
            })
    }

    private func updating(_ transform: (inout ClockScheduleEntry) -> Void) {
        var copy = entry
        transform(&copy)
        model.upsertClockScheduleEntry(copy)
    }
}

private struct ClockLocationRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: ODSpacing.sm) {
                TextField("Широта", value: latitudeBinding, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                TextField("Долгота", value: longitudeBinding, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                Button("Использовать текущее местоположение") { model.useCurrentLocationForClock() }
                    .controlSize(.small)
            }
            Text(locationCaption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var locationCaption: String {
        if model.settings.clockManualLocation == nil {
            return "Для восхода, полудня и заката нужно местоположение. Фиксированное время работает без него."
        }
        return "Для солнечных событий используется это местоположение. Кнопка текущего местоположения получает его через Core Location."
    }

    private var latitudeBinding: Binding<Double> {
        Binding(
            get: { model.settings.clockManualLocation?.latitude ?? 0 },
            set: { newLatitude in
                let longitude = model.settings.clockManualLocation?.longitude ?? 0
                model.setClockManualLocation(GeoCoordinate(latitude: newLatitude, longitude: longitude))
            })
    }
    private var longitudeBinding: Binding<Double> {
        Binding(
            get: { model.settings.clockManualLocation?.longitude ?? 0 },
            set: { newLongitude in
                let latitude = model.settings.clockManualLocation?.latitude ?? 0
                model.setClockManualLocation(GeoCoordinate(latitude: latitude, longitude: newLongitude))
            })
    }
}

private struct AppPresetsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            HStack(spacing: 8) {
                Text("Профили приложений").font(.title3)
                ODBadge("Экспериментальные функции", tone: .orange)
            }
            Toggle(isOn: Binding(
                get: { model.settings.appPresetsEnabled },
                set: { model.setAppPresetsEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Менять профиль монитора при переключении приложения")
                    Text("При переключении на выбранное приложение меняет яркость и при необходимости контрастность и цветовой режим монитора. После переключения на другое приложение восстанавливает значения. Индикатор не показывается; адаптивное управление на время приостанавливается.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.settings.appPresetsEnabled {
                AppPresetList()
            }
        }
    }
}

private struct AppPresetList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            if model.settings.appPresets.isEmpty {
                Text("Пока нет профилей приложений. Добавьте, например, яркость 40% для Final Cut.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ODCard {
                    ForEach(Array(model.settings.appPresets.enumerated()),
                            id: \.element.id) { index, preset in
                        if index > 0 { ODDivider() }
                        AppPresetRow(preset: preset)
                    }
                }
            }
            AddAppPresetMenu()
        }
    }
}

private struct AddAppPresetMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            ForEach(availableChoices, id: \.bundleID) { choice in
                Button(choice.name) {
                    model.upsertAppPreset(AppPresetPolicy.AppPreset(
                        bundleIdentifier: choice.bundleID, applicationName: choice.name,
                        brightness: 0.5, target: .allDisplays))
                }
            }
        } label: {
            Label("Добавить профиль приложения", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    /// Running apps that lack a preset already, so the menu never offers a duplicate.
    private var availableChoices: [(name: String, bundleID: String)] {
        let configured = Set(model.settings.appPresets.map(\.bundleIdentifier))
        return model.runningApplicationChoices().filter { !configured.contains($0.bundleID) }
    }
}

private struct AppPresetRow: View {
    @EnvironmentObject private var model: AppModel
    let preset: AppPresetPolicy.AppPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: ODSpacing.sm) {
                Text(preset.applicationName).bold()
                Spacer()
                Picker("", selection: targetBinding) {
                    Text("Все мониторы").tag(AppPresetPolicy.Target.allDisplays)
                    ForEach(externalDisplays, id: \.recordID) { observation in
                        Text(model.displayName(for: observation))
                            .tag(AppPresetPolicy.Target.display(observation.recordID.rawValue))
                    }
                }
                .labelsHidden().fixedSize()
                Button(role: .destructive) {
                    model.removeAppPreset(preset)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: ODSpacing.md) {
                Toggle("Яркость", isOn: brightnessEnabledBinding)
                if preset.brightness != nil {
                    Stepper("\(Int(((preset.brightness ?? 0) * 100).rounded()))%", value: brightnessBinding,
                            in: 0...1, step: 0.05)
                        .fixedSize()
                }
            }
            HStack(spacing: ODSpacing.md) {
                Toggle("Контрастность", isOn: contrastEnabledBinding)
                if preset.contrast != nil {
                    Stepper("\(Int(((preset.contrast ?? 0) * 100).rounded()))%", value: contrastBinding,
                            in: 0...1, step: 0.05)
                        .fixedSize()
                }
            }
            HStack(spacing: ODSpacing.md) {
                Toggle("Цветовой режим", isOn: colorPresetEnabledBinding)
                if preset.colorPreset != nil {
                    Picker("", selection: colorPresetBinding) {
                        ForEach([1, 2, 3, 4, 5, 6], id: \.self) { code in
                            Text(model.presetName(code)).tag(code)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var externalDisplays: [DisplayObservation] {
        model.displays.filter { $0.displayClass != .builtIn && $0.isActive }
    }

    private var targetBinding: Binding<AppPresetPolicy.Target> {
        Binding(get: { preset.target }, set: { updated in updating { $0.target = updated } })
    }
    private var brightnessEnabledBinding: Binding<Bool> {
        Binding(get: { preset.brightness != nil },
                set: { isOn in updating { $0.brightness = isOn ? ($0.brightness ?? 0.5) : nil } })
    }
    private var brightnessBinding: Binding<Double> {
        Binding(get: { Double(preset.brightness ?? 0) },
                set: { updated in updating { $0.brightness = Float(updated) } })
    }
    private var contrastEnabledBinding: Binding<Bool> {
        Binding(get: { preset.contrast != nil },
                set: { isOn in updating { $0.contrast = isOn ? ($0.contrast ?? 0.5) : nil } })
    }
    private var contrastBinding: Binding<Double> {
        Binding(get: { Double(preset.contrast ?? 0) },
                set: { updated in updating { $0.contrast = Float(updated) } })
    }
    private var colorPresetEnabledBinding: Binding<Bool> {
        Binding(get: { preset.colorPreset != nil },
                set: { isOn in updating { $0.colorPreset = isOn ? ($0.colorPreset ?? 4) : nil } })
    }
    private var colorPresetBinding: Binding<Int> {
        Binding(get: { preset.colorPreset ?? 4 },
                set: { updated in updating { $0.colorPreset = updated } })
    }

    private func updating(_ transform: (inout AppPresetPolicy.AppPreset) -> Void) {
        var copy = preset
        transform(&copy)
        model.upsertAppPreset(copy)
    }
}
#endif

/// Opens System Settings → Privacy & Security → Accessibility so the user can grant the permission the
/// media-key tap needs (Batch-3 #3/#5).
private func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}
#endif
