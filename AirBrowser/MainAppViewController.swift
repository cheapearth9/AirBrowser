import UIKit
import WebKit

class MainAppViewController: UIViewController, WKNavigationDelegate {

    var webView: WKWebView!

    private let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    private let youtubeTVUA = "Mozilla/5.0 (SmartTV; SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()
        let scriptSource = YouTubeAdBlocker.getScript()
        let userScript = WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.customUserAgent = defaultUA

        view.addSubview(webView)

        if let url = URL(string: "https://www.google.com") {
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let urlString = url.absoluteString.lowercased()

        if urlString.contains("youtube.com/tv") {
            if webView.customUserAgent != youtubeTVUA {
                webView.customUserAgent = youtubeTVUA
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }
        } else {
            if webView.customUserAgent != defaultUA {
                webView.customUserAgent = defaultUA
            }
        }

        decisionHandler(.allow)
    }
}
