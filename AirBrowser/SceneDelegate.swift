import UIKit
import WebKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var externalWindow: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let roleString = String(describing: session.role)

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
            // 2. Main iPad Screen: Touchpad / Controller interface
            let mainWindow = UIWindow(windowScene: windowScene)
            let mainVC = MainAppViewController()
            mainWindow.rootViewController = mainVC
            mainWindow.makeKeyAndVisible()
            self.window = mainWindow
            
            // If no external display is active, host the webView on the main iPad screen using Auto Layout
            if DisplayController.shared.externalWindow == nil {
                let webView: WKWebView = DisplayController.shared.webView
                webView.removeFromSuperview()
                webView.translatesAutoresizingMaskIntoConstraints = false
                mainVC.view.addSubview(webView)
                
                NSLayoutConstraint.activate([
                    webView.topAnchor.constraint(equalTo: mainVC.view.topAnchor),
                    webView.bottomAnchor.constraint(equalTo: mainVC.view.bottomAnchor),
                    webView.leadingAnchor.constraint(equalTo: mainVC.view.leadingAnchor),
                    webView.trailingAnchor.constraint(equalTo: mainVC.view.trailingAnchor)
                ])
                mainVC.view.layoutIfNeeded()
            }
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let roleString = String(describing: scene.session.role)
        
        if roleString.contains("ExternalDisplay") || roleString.contains("external") || windowScene.screen !== UIScreen.main {
            externalWindow?.isHidden = true
            externalWindow = nil
            DisplayController.shared.externalWindow = nil
            DisplayController.shared.isExternalConnected = false
            DisplayController.shared.detachExternalScreen()
            
            // Re-attach webView back to main iPad screen cleanly using Auto Layout upon disconnect
            if let mainVC = self.window?.rootViewController {
                let webView: WKWebView = DisplayController.shared.webView
                webView.removeFromSuperview()
                webView.translatesAutoresizingMaskIntoConstraints = false
                mainVC.view.addSubview(webView)
                
                NSLayoutConstraint.activate([
                    webView.topAnchor.constraint(equalTo: mainVC.view.topAnchor),
                    webView.bottomAnchor.constraint(equalTo: mainVC.view.bottomAnchor),
                    webView.leadingAnchor.constraint(equalTo: mainVC.view.leadingAnchor),
                    webView.trailingAnchor.constraint(equalTo: mainVC.view.trailingAnchor)
                ])
                mainVC.view.layoutIfNeeded()
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
