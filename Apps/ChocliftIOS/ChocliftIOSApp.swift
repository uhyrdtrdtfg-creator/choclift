import ChocliftCore
import SwiftUI

@main
struct ChocliftIOSApp: App {
    @StateObject private var client: CompanionClientEngine = {
        let identity = CompanionDeviceIdentity.resolve(idKey: "com.choclift.ios.uniqueDeviceID")
        return CompanionClientEngine(
            deviceID: identity.deviceID,
            deviceName: identity.deviceName,
            platform: identity.platform
        )
    }()

    var body: some Scene {
        WindowGroup {
            IOSRootTouchBarView(client: client)
                .preferredColorScheme(.dark)
        }
    }
}
