// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

@MainActor enum GameOrientationPolicy {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
}

final class ClawAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        GameOrientationPolicy.mask
    }
}
