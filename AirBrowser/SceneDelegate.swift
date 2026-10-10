import UIKit
import WebKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var externalWindow: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let roleString = String(describing: scene.session.role)

        if roleString.contains("ExternalDisplay") || roleString.contains("external") || windowScene.screen !== UIScreen.main {
            // 1. External Display: Independent desktop browser view
            let extWindow = UIWindow(windowScene: windowScene)
            
            let webView: WKWebView = DisplayController.shared.webView
            let cursorView: UIView = DisplayController.shared.cursorView
            
            let extVC = ExternalBrowserViewController(webView: webView, cursorView: cursorView)
            extWindow.rootViewController = extVC
            extWindow.makeKeyAndVisible()
            
            self.externalWindow = extWindow
            DisplayController.shared.externalWindow = extWindow
            DisplayController.shared.isExternalConnected = true
            
        } else {
            // 2. Main iPad Screen: Normal controller interface with touchpad & keyboard buttons
            let mainWindow = UIWindow(windowScene: windowScene)
            mainWindow.rootViewController = MainAppViewController()
            mainWindow.makeKeyAndVisible()
            self.window = mainWindow
            
            DisplayController.shared.externalWindow = nil
            // Note: We leave isExternalConnected alone here so the app retains its toggled-on preference!
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let roleString = String(describing: scene.session.role)
        
        if roleString.contains("ExternalDisplay") || roleString.contains("external") || windowScene.screen !== UIScreen.main {
            externalWindow?.isHidden = true
            externalWindow = nil
            DisplayController.shared.externalWindow = nil
            DisplayController.shared.detachExternalScreen()
            
            // Keep isExternalConnected = true so the app state stays toggled on
            // DisplayController.shared.isExternalConnected remains true
            
            if let window = self.window {
                window.rootViewController = MainAppViewController()
            }
        }
    }
}

// MARK: - Dedicated External Display View Controller
class ExternalBrowserViewController: UIViewController {
    let webView: WKWebView
    let cursorView: UIView
    
    init(webView: WKWebView, cursorView: UIView) {
        self.webView = webView
        self.cursorView = cursorView
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        cursorView.removeFromSuperview()
        view.addSubview(cursorView)
        view.layoutIfNeeded()
    }
}
