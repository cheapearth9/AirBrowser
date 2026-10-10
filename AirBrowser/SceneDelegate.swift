import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    var externalWindow: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Phân tách màn hình chính (iPad) và màn hình ngoài (HDMI/AirPlay)
        if windowScene.screen != UIScreen.main {
            let extWindow = UIWindow(windowScene: windowScene)
            extWindow.rootViewController = DisplayController()
            extWindow.isHidden = false
            self.externalWindow = extWindow
        } else {
            let mainWin = UIWindow(windowScene: windowScene)
            mainWin.rootViewController = MainAppViewController()
            mainWin.makeKeyAndVisible()
            self.window = mainWin
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {}
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {}
    func sceneDidEnterBackground(_ scene: UIScene) {}
}
