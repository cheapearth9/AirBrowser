import UIKit
import WebKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        if session.role == .windowApplication {
            // Main iPad screen: browser UI with the touchpad & keyboard controls.
            let mainWindow = UIWindow(windowScene: windowScene)
            mainWindow.rootViewController = MainAppViewController()
            mainWindow.makeKeyAndVisible()
            self.window = mainWindow
        } else {
            // Monitor: do NOT put a window on it yet. Just hand the scene to DisplayController.
            // The browser only appears there while AirPlay mode is ON; otherwise iPadOS keeps mirroring the iPad.
            DisplayController.shared.externalSceneDidConnect(windowScene)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene,
              windowScene.session.role != .windowApplication else { return }
        DisplayController.shared.externalSceneDidDisconnect(windowScene)
    }
}

// MARK: - Full-screen browser shown on the monitor
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

        // Pull the shared web view out of the iPad UI and pin it edge to edge.
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Cursor dot sits on top of the page.
        cursorView.removeFromSuperview()
        view.addSubview(cursorView)
    }
}
