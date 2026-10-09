import UIKit
import WebKit

class MainAppViewController: UIViewController, WKNavigationDelegate {

    var webView: WKWebView!

    // User-Agent Strings
    // 1. Modern iOS Safari UA to fix Google rendering as an old/basic page
    let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    
    // 2. Smart TV UA to prevent youtube.com/tv from redirecting to m.youtube.com
    let youtubeTVUA = "Mozilla/5.0 (SmartTV; SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        
        // Inject YouTube Ad Blocker script into all subframes and documents
        let adBlockerScript = YouTubeAdBlocker.getScript()
        let userScript = WKUserScript(source: adBlockerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        
        // Default to standard Safari User-Agent
        webView.customUserAgent = defaultUA

        view.addSubview(webView)

        // Load starting URL
        if let url = URL(string: "https://www.google.com") {
            webView.load(URLRequest(url: url))
        }
    }

    // Switch User-Agent dynamically when opening youtube.com/tv
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            if url.absoluteString.contains("youtube.com/tv") {
                if webView.customUserAgent != youtubeTVUA {
                    webView.customUserAgent = youtubeTVUA
                    webView.load(URLRequest(url: url))
                    decisionHandler(.cancel)
                    return
                }
            } else if webView.customUserAgent != defaultUA {
                webView.customUserAgent = defaultUA
            }
        }
        decisionHandler(.allow)
    }
}
