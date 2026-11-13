import Foundation

public enum BundledAppIcons {
    private static let resourceNames = [
        "com.apple.finder": "finder",
        "com.apple.Safari": "safari",
        "com.apple.Notes": "notes",
        "com.apple.iCal": "calendar",
        "com.apple.Music": "music",
        "com.apple.MobileSMS": "messages",
        "com.apple.Terminal": "terminal",
        "com.apple.dt.Xcode": "xcode",
        "com.apple.mail": "mail",
        "com.apple.reminders": "reminders"
    ]

    /// Original macOS app icons shipped with the app. Used when the Mac has not yet sent a live icon.
    public static func pngData(for bundleIdentifier: String) -> Data? {
        guard let name = resourceNames[bundleIdentifier] else { return nil }
        for bundle in candidateBundles {
            if let url = bundle.url(forResource: name, withExtension: "png") {
                return try? Data(contentsOf: url)
            }
        }
        return nil
    }

    private static var candidateBundles: [Bundle] {
        var bundles: [Bundle] = []
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        let staticNames = [
            "ChocliftCore_ChocliftCore",
            "ChocliftCore_ChocliftCore.bundle",
            "Choclift_ChocliftCore",
            "ChocliftCoreResources"
        ]
        for name in staticNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "bundle"),
               let bundle = Bundle(url: url) {
                bundles.append(bundle)
            }
        }
        if let url = Bundle.main.resourceURL {
            bundles.append(Bundle(url: url) ?? Bundle.main)
        }
        bundles.append(Bundle.main)
        return bundles
    }
}
