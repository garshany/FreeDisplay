#if !PUBLIC_API_ONLY
import DisplayDomain
import SwiftUI
import VirtualDisplayProvider
import ProviderInterfaces

/// Wire into Settings with the app's actual safe-mode state. Never restores definitions at launch.
struct VirtualDisplaysSettingsView: View {
    let safeMode: Bool
    @ObservedObject var session: VirtualDisplaySession
    @State private var experimentalOptIn = false
    @State private var name = "Рабочий экран OpenDisplay"
    @State private var width = 1920
    @State private var height = 1080
    @State private var hiDPI = false
    @State private var refresh = 60.0
    @State private var busy = false
    @State private var result: String?

    var body: some View {
        GroupBox("Виртуальные экраны · Экспериментально") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Виртуальные экраны используют закрытые API macOS и работают до завершения приложения. Оставьте физический экран доступным для восстановления.")
                    .font(.caption).foregroundStyle(.secondary)
                if safeMode { Text("Недоступно в безопасном режиме.").foregroundStyle(.orange) }
                if !session.isAvailable { Text("В этой версии macOS отсутствует необходимый API виртуальных экранов.").foregroundStyle(.orange) }
                Toggle("Разрешить создание экспериментальных виртуальных экранов", isOn: $experimentalOptIn)
                    .disabled(safeMode || !session.isAvailable || busy)
                TextField("Название", text: $name)
                HStack {
                    TextField("Ширина в пикселях", value: $width, format: .number)
                    Text("×")
                    TextField("Высота в пикселях", value: $height, format: .number)
                    Picker("Частота", selection: $refresh) {
                        Text("30 Гц").tag(30.0); Text("60 Гц").tag(60.0); Text("120 Гц").tag(120.0)
                    }
                }
                Toggle("HiDPI: логический размер рабочего стола вдвое меньше", isOn: $hiDPI)
                Button("Создать виртуальный экран") {
                    guard let pixelWidth = UInt32(exactly: width), let pixelHeight = UInt32(exactly: height) else {
                        result = "Введите допустимые положительные размеры в пикселях."; return
                    }
                    let definition = VirtualDisplayDefinition(name: name, pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight, refreshRate: refresh, hiDPI: hiDPI)
                    run {
                        let endpoint = try await session.create(definition,
                            experimentalOptIn: experimentalOptIn, safeMode: safeMode)
                        result = "Экран \(endpoint.displayID) активен. Размеры в пикселях подтверждены."
                    }
                }
                .disabled(busy || !experimentalOptIn || safeMode || !session.isAvailable)
                ForEach(session.endpoints) { endpoint in
                    HStack {
                        Text(endpoint.definition.name)
                        Spacer()
                        Text("\(endpoint.definition.pixelWidth) × \(endpoint.definition.pixelHeight)")
                        Button("Удалить") { run { try await session.destroy(endpoint.id); result = "Удаление экрана подтверждено." } }
                            .disabled(busy)
                    }
                }
                if busy { ProgressView() }
                if let result { Text(result).font(.caption).textSelection(.enabled) }
            }.padding(8)
        }
    }

    private func localizedError(_ error: Error) -> String {
        guard let failure = error as? ProviderFailure else {
            return error is CancellationError ? "Операция отменена." : "Не удалось выполнить операцию: \(error.localizedDescription)"
        }
        switch failure {
        case .denied: return "Операция запрещена: проверьте разрешение экспериментальных функций, безопасный режим и наличие другого активного экрана."
        case .busy: return "Другая операция ещё выполняется или достигнут предел четырёх виртуальных экранов."
        case .unsupported: return "Эта версия macOS не поддерживает необходимый API."
        case .timeout: return "macOS не подтвердила создание экрана за отведённое время."
        case .providerError(let message), .partial(let message): return message
        case .osRejected(let code): return "macOS отклонила операцию (код \(code))."
        case .ambiguous: return "Не удалось однозначно определить экран."
        case .unknown: return "Причина ошибки неизвестна."
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; result = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch { result = localizedError(error) }
        }
    }
}
#endif
