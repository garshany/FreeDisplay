# Проверка цвета, EDID и HiDPI

Проверено локально 13 октября 2026 года. Исходный код — оригинальный, GPL-3.0-or-later.

| Функция | Реальное доказательство | Непроверенная часть |
|---|---|---|
| EDIDDocument.init | 6 тестов: длины 0/1/127/129/32769/32896, предел 32768, заголовок, число расширений, контрольные суммы базового блока и расширения, код производителя, идентификаторы | Произвольные реальные EDID разных мониторов |
| overridePropertyList | XML plist повторно прочитан; точное равенство EDID, vendor/product ID; 1 и 256 блоков | Принятие override системой; установка не реализована |
| HiDPIConfigurationPlan.init | 1/1920/8192, двойные размеры; ноль/отрицательные/8193/Int.max отвергнуты; JSON round trip; 4 русских шага восстановления | Применение физического режима; не реализовано |
| EDIDError.errorDescription | Все пять вариантов имеют сообщение; номер повреждённого блока выводится | Отрисовка диалогов |
| HiDPIPlanError.errorDescription | Оба варианта проверены на русские сообщения | Отрисовка диалогов |
| AdvancedDisplayToolsView.screen/body | Swift 6 typecheck; поиск NSScreen по CGDirectDisplayID, русские подписи | Живой HDR/EDR монитор и визуальная проверка |
| importEDID | Typecheck; строгий парсер отдельно проверен; oversized файл отвергается до чтения | Ручной выбор файла/отмена NSOpenPanel |
| save | Typecheck; атомарная запись в выбранный пользователем URL | NSSavePanel, отмена, ошибки файловой системы в UI |
| exportEDID | Typecheck; результат сериализации проверен тестами | UI выбор места сохранения |
| exportPlan | Typecheck; JSON round trip проверен тестом | UI выбор места сохранения |
| ColorProfileService.deviceUUID | Read-only executable: текущий дисплей не предоставил UUID | Реальный дисплей с UUID |
| isControllable | Read-only executable: false при отсутствии UUID | Управляемый дисплей |
| availableProfiles | Read-only executable: 0 профилей в текущем процессе | Перечисление реальных установленных ICC, фильтрация и сортировка непустого списка |
| currentProfileName / profileDescription | Read-only executable: nil при отсутствии устройства; Swift 6 compile | Чтение настоящего ICC, custom/factory branches |
| setProfile | Синтетический несуществующий ICC отвергнут до вызова записи | Применение валидного ICC, постпроверка; запись не запускалась |
| resetToFactory | Swift 6 compile, статически проверена привязка к UUID | Живой сброс; запись не запускалась |
| ClockLocationProvider.init/requestOnce | Swift 6 typecheck, статически проверены busy/authorization branches | Разрешение геолокации, реальная координата |
| locationManagerDidChangeAuthorization | Swift 6 typecheck, статический разбор всех ветвей | Системный callback |
| didUpdateLocations/didFailWithError/finish | Swift 6 typecheck, статический разбор nil/success/однократного completion | Runtime callbacks; геолокация не запрашивалась |

ColorSync вернул пустой список и не предоставил текущий дисплей этому процессу.
Это ограничение среды проверки, а не доказательство работоспособности ICC на оборудовании.
Строки собственных инструментов и fallback ICC русифицированы; названия профилей
приходят от ColorSync и сохраняются как пользовательские данные.
