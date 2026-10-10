import UIKit
import WebKit

class DisplayController: UIViewController, WKNavigationDelegate {
    static let shared = DisplayController()

    var webView: WKWebView!
    private(set) var cursorView: UIView!
    
    var cursorPosition: CGPoint = .zero {
        didSet {
            cursorView?.center = cursorPosition
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        YouTubeAdBlocker.apply(to: config)

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        view.addSubview(webView)

        setupCursorView()

        if let url = URL(string: "https://www.youtube.com/tv") {
            webView.load(URLRequest(url: url))
        }
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
        
        // Center cursor initially
        cursorPosition = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.addSubview(cursorView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        webView.frame = view.bounds
    }

    func moveCursor(deltaX: CGFloat, deltaY: CGFloat) {
        var newX = cursorPosition.x + (deltaX * 1.5)
        var newY = cursorPosition.y + (deltaY * 1.5)

        newX = max(0, min(view.bounds.width, newX))
        newY = max(0, min(view.bounds.height, newY))

        cursorPosition = CGPoint(x: newX, y: newY)
    }

    func performClickAtCursor() {
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
        let js = "window.scrollBy(0, \(deltaY * 2.5));"
        webView.evaluateJavaScript(js)
    }
}
