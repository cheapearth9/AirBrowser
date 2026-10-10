import UIKit
import WebKit

final class DisplayController: ObservableObject {
    static let shared = DisplayController()

    let webView: WKWebView
    private(set) var externalWindow: UIWindow?
    private(set) var cursorView: UIView!
    
    @Published var isExternalConnected: Bool = false
    @Published var cursorPosition: CGPoint = .zero

    private init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        YouTubeAdBlocker.apply(to: config)

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        setupCursorView()
        setupScreenNotifications()
    }

    private func setupCursorView() {
        cursorView = UIView(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        cursorView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        cursorView.layer.cornerRadius = 11
        cursorView.layer.borderColor = UIColor.white.cgColor
        cursorView.layer.borderWidth = 2.5
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorView.layer.shadowRadius = 4
        cursorView.layer.shadowOpacity = 0.5
        cursorView.isUserInteractionEnabled = false
    }

    private func setupScreenNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDisconnected(_:)),
            name: UIScreen.didDisconnectNotification,
            object: nil
        )
    }

    @objc private func screenDisconnected(_ notification: Notification) {
        detachExternalScreen()
    }

    func attachToExternalScreen(_ screen: UIScreen) {
        if let maxMode = screen.availableModes.max(by: { $0.size.width < $1.size.width }) {
            screen.currentMode = maxMode
        }

        let window = UIWindow(frame: screen.bounds)
        window.screen = screen

        let vc = UIViewController()
        vc.view.backgroundColor = .black

        webView.removeFromSuperview()
        webView.frame = vc.view.bounds
        vc.view.addSubview(webView)

        cursorPosition = CGPoint(x: screen.bounds.midX, y: screen.bounds.midY)
        cursorView.center = cursorPosition
        vc.view.addSubview(cursorView)

        window.rootViewController = vc
        window.makeKeyAndVisible() // Breaks system mirroring and forces standalone external output

        self.externalWindow = window
        self.isExternalConnected = true
    }

    func detachExternalScreen() {
        externalWindow?.isHidden = true
        externalWindow = nil
        isExternalConnected = false
        cursorView.removeFromSuperview()
    }

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
