// SPDX-License-Identifier: GPL-3.0-or-later
// Original OpenDisplay tools. Uses public APIs only; exported plans never install themselves.
#if os(macOS)
import AppKit
import CoreGraphics
import SwiftUI
import TopologyCore

@MainActor
struct AdvancedDisplayToolsView: View {
    let displayID: CGDirectDisplayID
    @State private var edid: EDIDDocument?
    @State private var status = "Импортируйте двоичный EDID монитора для проверки и экспорта конфигурации."
    @State private var width = 1920
    @State private var height = 1080

    private var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
    }

    var body: some View {
        Form {
            Section("Возможности HDR") {
                if let screen {
                    LabeledContent("Доступный запас EDR", value: String(format: "%.2f×", screen.maximumExtendedDynamicRangeColorComponentValue))
                    LabeledContent("Потенциальный запас EDR", value: String(format: "%.2f×", screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
                    Text("Запас EDR описывает текущий вывод macOS. Он не подтверждает передачу HDR на монитор и не включает аппаратный HDR.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Для этого дисплея нет данных NSScreen.")
                }
            }
            Section("Инструменты EDID — только экспорт") {
                Button("Импортировать EDID…", action: importEDID)
                if let edid {
                    LabeledContent("Производитель", value: edid.manufacturer)
                    LabeledContent("Код модели", value: String(format: "0x%04X", edid.productID))
                    LabeledContent("Название", value: edid.displayName ?? "Не указано")
                    LabeledContent("Проверенные блоки", value: String(edid.extensionCount + 1))
                    Button("Экспортировать проверенную конфигурацию…", action: exportEDID)
                }
                Text(status).font(.caption).textSelection(.enabled)
                Text("Импортированный файл не сопоставляется с дисплеем автоматически. Перед внешней установкой проверьте производителя и код модели. OpenDisplay не устанавливает системные конфигурации.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Планирование режима HiDPI") {
                TextField("Логическая ширина", value: $width, format: .number)
                TextField("Логическая высота", value: $height, format: .number)
                Button("Экспортировать план HiDPI…", action: exportPlan)
                Text("Доступные режимы macOS выбираются в обычном списке разрешений. Пользовательские физические режимы требуют внешней настройки с правами администратора. Здесь экспортируются только размеры и порядок восстановления.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func importEDID() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32768 else { throw EDIDError.invalidLength }
            edid = try EDIDDocument(data: Data(contentsOf: url))
            status = "Контрольные суммы всех блоков EDID проверены. Расширения сохраняются без интерпретации."
        } catch {
            edid = nil; status = "EDID отклонён: \(error.localizedDescription)"
        }
    }

    private func save(_ data: Data, name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); status = "Экспортирован \(url.lastPathComponent). Настройки дисплея не изменены." }
        catch { status = "Ошибка экспорта: \(error.localizedDescription)" }
    }

    private func exportEDID() {
        guard let edid else { return }
        do { save(try edid.overridePropertyList(), name: "DisplayProductID-\(String(edid.productID, radix: 16)).plist") }
        catch { status = "Ошибка экспорта конфигурации: \(error.localizedDescription)" }
    }

    private func exportPlan() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            save(try encoder.encode(HiDPIConfigurationPlan(width: width, height: height)), name: "HiDPI-plan.json")
        } catch { status = "Недопустимый план HiDPI: \(error.localizedDescription)" }
    }
}
#endif
