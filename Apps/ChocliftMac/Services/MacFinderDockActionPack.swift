import ChocliftCore
import CoreFoundation
import Foundation

enum MacFinderDockActionPack {
    static func run(
        id: String,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        FinderDockCompanionAction.execute(
            id: id,
            language: language,
            readPreference: readBooleanPreference(domain:key:),
            writePreference: writeBooleanPreference(domain:key:value:),
            restartProcess: restartApplicationProcess(named:)
        )
    }

    private static func readBooleanPreference(domain: String, key: String) -> Bool? {
        let cfDomain = domain as CFString
        _ = CFPreferencesAppSynchronize(cfDomain)
        let raw = CFPreferencesCopyAppValue(key as CFString, cfDomain)
        return FinderDockPreferenceToggle.parsePreferenceValue(raw)
    }

    private static func writeBooleanPreference(domain: String, key: String, value: Bool) -> Bool {
        let cfDomain = domain as CFString
        let cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        CFPreferencesSetAppValue(key as CFString, cfValue, cfDomain)
        return CFPreferencesAppSynchronize(cfDomain)
    }

    /// Restarts `Finder` or `Dock` using the same `/usr/bin/killall` pattern as
    /// `MacSystemControlService.setFinderDesktopIconsVisible`.
    private static func restartApplicationProcess(named processName: String) {
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killProcess.arguments = [processName]
        do {
            try killProcess.run()
            killProcess.waitUntilExit()
        } catch {
            return
        }
    }
}
