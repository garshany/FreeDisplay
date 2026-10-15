// Compile against the built frameworks and run this test binary only. It reads bundle resources
// and static descriptions; it never loads the app executable or calls a display provider.
import CoreGraphicsProvider
import Foundation
import TopologyCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let products = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for (product, displayName) in [
    ("FreeDisplay", "FreeDisplay"),
    ("FreeDisplay-PublicAPIOnly", "FreeDisplay"),
    ("FreeDisplayRescue", "FreeDisplay Rescue"),
] {
    let infoURL = products.appendingPathComponent("\(product).app/Contents/Info.plist")
    let data = try Data(contentsOf: infoURL)
    let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    require(info["CFBundleName"] as? String == displayName, "Wrong bundle name for \(product)")
    require(info["CFBundleDisplayName"] as? String == displayName, "Wrong display name for \(product)")
    require(info["CFBundleExecutable"] as? String == product, "Wrong executable for \(product)")
    if product != "FreeDisplayRescue" {
        let urlTypes = info["CFBundleURLTypes"] as! [[String: Any]]
        require(urlTypes.first?["CFBundleURLSchemes"] as? [String] == ["opendisplay"], "URL compatibility changed")
        require(info["OpenDisplayLocalBuild"] as? Bool == true, "Local-build update guard changed")
        let resources = infoURL.deletingLastPathComponent().appendingPathComponent("Resources/ru.lproj")
        let strings = try Data(contentsOf: resources.appendingPathComponent("Localizable.strings"))
        let ru = try PropertyListSerialization.propertyList(from: strings, format: nil) as! [String: String]
        require(ru["Quit FreeDisplay"] == "Выйти из FreeDisplay", "Russian quit translation missing")
        require(ru["Quit OpenDisplay"] == nil, "Old quit localization key remains")
        require(ru[DiagnosticsBundle.contents[0]]?.contains("FreeDisplay") == true,
                "Diagnostics description and Russian catalog key diverged")
    }
}
require(DiagnosticsBundle.contents[0] == "FreeDisplay's own records: the display event timeline, the audit log, the list of displays it turned off, its display registry, and its settings (location and app presets removed)",
        "Diagnostics description uses the wrong brand")
// The UI rename must not migrate storage or rename exported files.
require(DiagnosticsBundle.defaultFileName(now: Date(timeIntervalSince1970: 0)).hasPrefix("OpenDisplay-diagnostics-"),
        "Diagnostics export path changed")
let supportDirectory = try ManagedOfflineStore.defaultDirectory()
require(supportDirectory.lastPathComponent == "OpenDisplay", "Storage directory changed")
print("Branding read-only integration checks passed")
