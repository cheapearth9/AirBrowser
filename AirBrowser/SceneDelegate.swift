import UIKit
import WebKit

/// The iPad's main window.
/// While AirPlay mode is ON the iPad pointer is locked and a physical mouse drives the monitor.
/// The system still delivers the mouse's clicks to whatever iPad button sits under the hidden pointer,
/// so while `ignoresMouseClicks` is true those clicks are dropped. Finger touches are not affected.
final class MainWindow: UIWindow {
    var ignoresMouseClicks = false

    override func sendEvent(_ event: UIEvent) {
        if ignoresMouseClicks,
           event.type == .touches,
           let touches = event.allTouches,
           !touches.isEmpty,
           touches.allSatisfy({ $0.type == .indirectPointer }) {
            return
        }
        super.sendEvent(event)
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        if session.role == .windowApplication {
            // Main iPad screen: browser UI with the touchpad & keyboard controls.
            let mainWindow = MainWindow(windowScene: windowScene)
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
    private var pins: [NSLayoutConstraint] = []

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
        pinWebView(force: true)

        // Cursor dot sits on top of the page.
        cursorView.removeFromSuperview()
        view.addSubview(cursorView)
    }

    /// Pins the web view to all four edges of the monitor. Does nothing if it is already pinned,
    /// unless `force` is true (used after a page leaves full screen, which can drop the layout rules).
    func pinWebView(force: Bool = false) {
        if !force, webView.superview === view, !pins.isEmpty, pins.allSatisfy({ $0.isActive }) { return }

        NSLayoutConstraint.deactivate(pins)
        if webView.superview !== view {
            webView.removeFromSuperview()
            view.insertSubview(webView, at: 0)
        }
        webView.translatesAutoresizingMaskIntoConstraints = false

        pins = [
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ]
        NSLayoutConstraint.activate(pins)

        if cursorView.superview === view { view.bringSubviewToFront(cursorView) }
    }
}
