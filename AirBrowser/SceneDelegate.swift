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
/// Shows one page full screen, or two pages side by side with a thin black line between them.
class ExternalBrowserViewController: UIViewController {
    private(set) var webViews: [WKWebView]
    let cursorView: UIView

    /// Share of the width given to the first page while two pages are open (0.2 ... 0.8).
    var splitRatio: CGFloat {
        didSet { relayout() }
    }

    /// Width of the black line between two pages.
    private let gap: CGFloat = 6

    init(webViews: [WKWebView], cursorView: UIView, ratio: CGFloat) {
        self.webViews = webViews
        self.cursorView = cursorView
        self.splitRatio = ratio
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        attachWebViews()

        // Cursor dot sits on top of the pages.
        cursorView.removeFromSuperview()
        view.addSubview(cursorView)
    }

    /// Replaces the pages shown (a second page was added, or one was closed).
    func setWebViews(_ views: [WKWebView]) {
        webViews = views
        if isViewLoaded { attachWebViews() }
    }

    /// Puts every page back on the monitor and sizes it again. Safe to call at any time
    /// (a page's own full screen can move its web view around).
    func refreshLayout() {
        if isViewLoaded { attachWebViews() }
    }

    private func attachWebViews() {
        // Pull each shared web view out of the iPad UI (or out of full screen) and put it here.
        for web in webViews {
            if web.superview !== view {
                web.removeFromSuperview()
                view.insertSubview(web, at: 0)
            }
            web.translatesAutoresizingMaskIntoConstraints = true
            web.autoresizingMask = []
        }
        // A page that was closed must not stay behind on the monitor.
        for sub in view.subviews where sub is WKWebView {
            if !webViews.contains(where: { $0 === sub }) { sub.removeFromSuperview() }
        }
        if cursorView.superview === view { view.bringSubviewToFront(cursorView) }
        relayout()
    }

    private func relayout() {
        guard isViewLoaded else { return }
        let bounds = view.bounds

        if webViews.count >= 2 {
            let usable = bounds.width - gap
            let ratio = min(max(splitRatio, 0.2), 0.8)
            let firstWidth = (usable * ratio).rounded()
            webViews[0].frame = CGRect(x: 0, y: 0, width: firstWidth, height: bounds.height)
            webViews[1].frame = CGRect(x: firstWidth + gap, y: 0, width: usable - firstWidth, height: bounds.height)
        } else if let only = webViews.first {
            only.frame = bounds
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        relayout()
    }
}
