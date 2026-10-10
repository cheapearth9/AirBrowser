import UIKit
import WebKit

class MainAppViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate {

    var webView: WKWebView!
    var urlTextField: UITextField!
    private var isAirPlayModeActive: Bool = false {
        didSet {
            airPlayToggleButton.setTitle(isAirPlayModeActive ? "AirPlay: ON" : "AirPlay: OFF", for: .normal)
            airPlayToggleButton.setTitleColor(isAirPlayModeActive ? .systemBlue : .systemGray, for: .normal)
            updateExternalDisplayState()
        }
    }
    private var airPlayToggleButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 1. Setup Toolbar (Back, Forward, URL Bar, AirPlay Toggle, Settings)
        let toolbar = UIView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = .secondarySystemBackground
        view.addSubview(toolbar)

        let backButton = createButton(title: "◄", action: #selector(goBack))
        let forwardButton = createButton(title: "►", action: #selector(goForward))
        
        urlTextField = UITextField()
        urlTextField.translatesAutoresizingMaskIntoConstraints = false
        urlTextField.borderStyle = .roundedRect
        urlTextField.placeholder = "Enter URL or search..."
        urlTextField.font = .systemFont(ofSize: 14)
        urlTextField.returnKeyType = .go
        urlTextField.delegate = self
        
        airPlayToggleButton = createButton(title: "AirPlay: OFF", action: #selector(toggleAirPlayMode))
        airPlayToggleButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)

        let settingsButton = createButton(title: "⚙️", action: #selector(openSettings))

        let stack = UIStackView(arrangedSubviews: [backButton, forwardButton, urlTextField, airPlayToggleButton, settingsButton])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)

        // 2. Setup WebView for Main Screen Browsing
        webView = WKWebView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 50),

            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            
            backButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            airPlayToggleButton.widthAnchor.constraint(equalToConstant: 90),
            settingsButton.widthAnchor.constraint(equalToConstant: 36),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        // Load default start page
        if let url = URL(string: "https://www.google.com") {
            webView.load(URLRequest(url: url))
            urlTextField.text = "https://www.google.com"
        }
    }

    private func createButton(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    @objc func goBack() { if webView.canGoBack { webView.goBack() } }
    @objc func goForward() { if webView.canGoForward { webView.goForward() } }

    @objc func toggleAirPlayMode() {
        isAirPlayModeActive.toggle()
    }

    @objc func openSettings() {
        let alert = UIAlertController(title: "Browser Settings", message: "Manage browsing data", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Clear Cache & Cookies", style: .destructive) { _ in
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date(timeIntervalSince1970: 0)) {}
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - UITextFieldDelegate (URL Navigation)
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        guard let text = textField.text, !text.isEmpty else { return true }
        
        var formattedURL = text
        if !formattedURL.hasPrefix("http://") && !formattedURL.hasPrefix("https://") {
            if formattedURL.contains(".") && !formattedURL.contains(" ") {
                formattedURL = "https://" + formattedURL
            } else {
                let encoded = formattedURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? formattedURL
                formattedURL = "https://www.google.com/search?q=\(encoded)"
            }
        }
        
        if let url = URL(string: formattedURL) {
            webView.load(URLRequest(url: url))
        }
        return true
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        urlTextField.text = webView.url?.absoluteString
    }

    // MARK: - External Screen & Toggle Routing via DisplayController Singleton
    private func updateExternalDisplayState() {
        if isAirPlayModeActive && UIScreen.screens.count > 1 {
            DisplayController.shared.attachToExternalScreen(UIScreen.screens[1])
        } else {
            DisplayController.shared.detachExternalScreen()
        }
    }
}
