import AppKit

/// App appearance is a user preference; document typography stays in the document.
enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

final class AppAppearanceController: NSObject, NSMenuItemValidation {
    static let shared = AppAppearanceController()
    static let didChangeNotification = Notification.Name("dev.hermes.appAppearanceDidChange")
    private static let preferenceKey = "appAppearance"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    var selection: AppAppearance {
        AppAppearance(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
    }

    func apply() {
        NSApp.appearance = selection.appearance
    }

    func select(_ appearance: AppAppearance) {
        defaults.set(appearance.rawValue, forKey: Self.preferenceKey)
        apply()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    @objc func changeAppearance(_ sender: Any?) {
        let tag = (sender as? NSPopUpButton)?.selectedTag() ?? (sender as? NSMenuItem)?.tag ?? -1
        guard AppAppearance.allCases.indices.contains(tag) else { return }
        select(AppAppearance.allCases[tag])
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.state = AppAppearance.allCases.firstIndex(of: selection) == item.tag ? .on : .off
        return true
    }
}
