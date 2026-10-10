import UIKit
import WebKit
import AVKit

class MainAppViewController: UIViewController, WKNavigationDelegate {

    var webView: WKWebView!
    private var externalWindow: UIWindow?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 1. Setup Navigation Toolbar
        let toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = .secondarySystemBackground
        view.addSubview(toolbar)

        let backButton = createButton(title: "◄", action: #selector(goBack))
        let forwardButton = createButton(title: "►", action: #selector(goForward))
        let settingsButton = createButton(title: "⚙️", action: #selector(openSettings))

        let airPlayPicker = AVRoutePickerView()
        airPlayPicker.translatesAutoresizingMaskIntoConstraints = false
        airPlayPicker.activeTintColor = .systemBlue
        airPlayPicker.tintColor = .label

        let stack = UIStackView(arrangedSubviews: [backButton, forwardButton, airPlayPicker, settingsButton])
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)

        // 2. Setup WebView (Touchpad / Control Interface on iPad)
        webView = WKWebView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        if let url = URL(string: "https://www.google.com") {
            webView.load(URLRequest(url: url))
        }

        // 3. Intercept HDMI Hardware Connection Directly
        NotificationCenter.default.addObserver(self, selector: #selector(screenDidConnect), name: UIScreen.didConnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenDidDisconnect), name: UIScreen.didDisconnectNotification, object: nil)

        // Check if HDMI is already plugged in at launch
        if UIScreen.screens.count > 1 {
            activateExternalDisplay(UIScreen.screens[1])
        }
    }

    private func createButton(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    @objc func goBack() { if webView.canGoBack { webView.goBack() } }
    @objc func goForward() { if webView.canGoForward { webView.goForward() } }

    @objc func openSettings() {
        let alert = UIAlertController(title: "AirBrowser Settings", message: "Choose an action:", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Clear Browser Cache", style: .default) { _ in
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date(timeIntervalSince1970: 0)) {}
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc func screenDidConnect(_ notification: Notification) {
        guard let screen = notification.object as? UIScreen else { return }
        activateExternalDisplay(screen)
    }

    @objc func screenDidDisconnect(_ notification: Notification) {
        externalWindow?.isHidden = true
        externalWindow = nil
    }

    private func activateExternalDisplay(_ screen: UIScreen) {
        // Programmatically bind DisplayController to the external monitor hardware
        let extWindow = UIWindow(frame: screen.bounds)
        extWindow.screen = screen
        extWindow.rootViewController = DisplayController()
        extWindow.isHidden = false
        self.externalWindow = extWindow
    }
}
