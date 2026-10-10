import UIKit
import WebKit
import Combine

extension Notification.Name {
    /// Posted whenever a monitor's external-display scene connects or disconnects.
    static let externalDisplayAvailabilityChanged = Notification.Name("AirBrowser.externalDisplayAvailabilityChanged")
}

/// Owns the ONE shared web view and decides where it is shown:
///  - on the iPad (default), or
///  - fullscreen on the monitor (AirPlay mode ON).
///
/// The monitor is driven only by its UIWindowScene (handed over by SceneDelegate).
/// No legacy `UIWindow.screen` windows are created, so two windows can never fight over the web view.
final class DisplayController: ObservableObject {
    static let shared = DisplayController()

    let webView: WKWebView
    let cursorView: UIView
    var externalWindow: UIWindow?

    /// True while the monitor is showing the browser (AirPlay mode ON).
    @Published var isExternalConnected: Bool = false
    /// True while a monitor is plugged in and iPadOS has handed us a scene for it.
    @Published private(set) var isExternalDisplayAvailable: Bool = false
    @Published var cursorPosition: CGPoint = .zero

    private weak var externalScene: UIWindowScene?

    private init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        YouTubeAdBlocker.apply(to: config)

        let web = WKWebView(frame: .zero, configuration: config)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.allowsBackForwardNavigationGestures = true

        // macOS Safari User-Agent for desktop-class layout
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

        self.webView = web
        self.cursorView = DisplayController.makeCursorView()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidDisconnect(_:)),
            name: UIScreen.didDisconnectNotification,
            object: nil
        )
    }

    private static func makeCursorView() -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        view.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        view.layer.cornerRadius = 11
        view.layer.borderColor = UIColor.white.cgColor
        view.layer.borderWidth = 2.5
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowRadius = 4
        view.layer.shadowOpacity = 0.5
        view.isUserInteractionEnabled = false
        return view
    }

    // MARK: - Monitor scene bookkeeping (called from SceneDelegate)

    func externalSceneDidConnect(_ scene: UIWindowScene) {
        externalScene = scene
        isExternalDisplayAvailable = true
        NotificationCenter.default.post(name: .externalDisplayAvailabilityChanged, object: nil)
    }

    func externalSceneDidDisconnect(_ scene: UIWindowScene) {
        // Ignore a stale scene that disconnects after a newer one already took over (quick replug).
        if let current = externalScene, current !== scene { return }
        tearDownExternalScene()
    }

    @objc private func screenDidDisconnect(_ notification: Notification) {
        guard let screen = notification.object as? UIScreen,
              let scene = externalScene,
              scene.screen === screen else { return }
        tearDownExternalScene()
    }

    private func tearDownExternalScene() {
        stopExternalPresentation()
        externalScene = nil
        isExternalDisplayAvailable = false
        NotificationCenter.default.post(name: .externalDisplayAvailabilityChanged, object: nil)
    }

    // MARK: - Showing / hiding the browser on the monitor

    /// Moves the shared web view onto the monitor. Returns false if no monitor scene exists.
    @discardableResult
    func startExternalPresentation() -> Bool {
        if externalWindow != nil { return true }
        guard let scene = externalScene else { return false }

        // The view controller pulls the web view and cursor out of the iPad UI and pins them fullscreen.
        let controller = ExternalBrowserViewController(webView: webView, cursorView: cursorView)
        controller.loadViewIfNeeded()

        // A window created from the scene gets the monitor's exact size, so there are no black bars.
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.isHidden = false // not makeKeyAndVisible: the iPad keeps keyboard focus

        externalWindow = window
        cursorPosition = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        cursorView.center = cursorPosition
        isExternalConnected = true
        return true
    }

    /// Takes the browser off the monitor. The caller puts the web view back on the iPad.
    /// With no window left on the monitor, iPadOS goes back to mirroring the iPad.
    func stopExternalPresentation() {
        guard let window = externalWindow else { return }

        webView.removeFromSuperview()
        cursorView.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil

        externalWindow = nil
        isExternalConnected = false
    }

    // Kept so older call sites still compile; the monitor is now driven by its scene.
    func attachToExternalScreen(_ screen: UIScreen) {
        startExternalPresentation()
    }

    func detachExternalScreen() {
        stopExternalPresentation()
    }

    // MARK: - Cursor, click and scroll

    func moveCursor(deltaX: CGFloat, deltaY: CGFloat) {
        guard let window = externalWindow else { return }

        var newX = cursorPosition.x + (deltaX * 1.5)
        var newY = cursorPosition.y + (deltaY * 1.5)

        newX = max(0, min(window.bounds.width, newX))
        newY = max(0, min(window.bounds.height, newY))

        cursorPosition = CGPoint(x: newX, y: newY)
        cursorView.center = cursorPosition
    }

    func performClickAtCursor() {
        guard isExternalConnected else { return }

        let js = """
        (function() {
            const elem = document.elementFromPoint(\(cursorPosition.x), \(cursorPosition.y));
            if (elem) {
                elem.click();
                if (elem.tagName === 'INPUT' || elem.tagName === 'TEXTAREA') {
                    elem.focus();
                }
            }
        })();
        """
        webView.evaluateJavaScript(js)
    }

    func performScroll(deltaY: CGFloat) {
        guard isExternalConnected else { return }
        let js = "window.scrollBy(0, \(deltaY * 2.5));"
        webView.evaluateJavaScript(js)
    }
}
