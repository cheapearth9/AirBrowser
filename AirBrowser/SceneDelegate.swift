import UIKit
import WebKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var externalWindow: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let externalDisplayRole = UISceneSession.Role(rawValue: "UIWindowSceneSessionRoleExternalDisplay")

        if session.role == externalDisplayRole {
            // 1. External Display: True independent desktop browser view
            let extWindow = UIWindow(windowScene: windowScene)
            
            let extVC = UIViewController()
            extVC.view.backgroundColor = .black
            
            let webView = DisplayController.shared.webView
            webView.removeFromSuperview()
            webView.frame = extVC.view.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            extVC.view.addSubview(webView)
            
            extVC.view.addSubview(DisplayController.shared.cursorView)
            
            extWindow.rootViewController = extVC
            extWindow.makeKeyAndVisible()
            
            self.externalWindow = extWindow
            DisplayController.shared.externalWindow = extWindow
            DisplayController.shared.isExternalConnected = true
            
        } else {
            // 2. Main iPad Screen: Touchpad / Controller interface
            let mainWindow = UIWindow(windowScene: windowScene)
            mainWindow.rootViewController = MainAppViewController()
            mainWindow.makeKeyAndVisible()
            self.window = mainWindow
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        let externalDisplayRole = UISceneSession.Role(rawValue: "UIWindowSceneSessionRoleExternalDisplay")
        if scene.session.role == externalDisplayRole {
            externalWindow?.isHidden = true
            externalWindow = nil
            DisplayController.shared.detachExternalScreen()
        }
    }
}
