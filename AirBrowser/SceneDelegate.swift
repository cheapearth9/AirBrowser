import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    var externalWindow: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        // Check if this scene is for an external display
        if windowScene.screen != UIScreen.main {
            // Setup External Fullscreen Window
            let extWindow = UIWindow(windowScene: windowScene)
            extWindow.rootViewController = DisplayController()
            extWindow.isHidden = false
            self.externalWindow = extWindow
        } else {
            // Setup Main iPad Screen (Touchpad & Remote)
            let mainWin = UIWindow(windowScene: windowScene)
            mainWin.rootViewController = MainAppViewController()
            mainWin.makeKeyAndVisible()
            self.window = mainWin
        }
    }
}
