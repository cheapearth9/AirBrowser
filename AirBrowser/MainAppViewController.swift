import UIKit
import WebKit

class MainAppViewController: UIViewController, UITextFieldDelegate, WKNavigationDelegate {

    var webView: WKWebView!
    var urlTextField: UITextField!
    
    private var trackpadContainer: UIView!
    private var trackpadView: UIView!
    private var keyboardTriggerButton: UIButton!
    private var airPlayToggleButton: UIButton!

    private var isAirPlayModeActive: Bool = false {
        didSet {
            airPlayToggleButton.setTitle(isAirPlayModeActive ? "AirPlay: ON" : "AirPlay: OFF", for: .normal)
            airPlayToggleButton.setTitleColor(isAirPlayModeActive ? .systemBlue : .systemGray, for: .normal)
            updateLayoutForAirPlayMode()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 1. Setup Top Toolbar
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
        airPlayToggleButton.isHidden = (UIScreen.screens.count <= 1)

        let settingsButton = createButton(title: "⚙️", action: #selector(openSettings))

        let topStack = UIStackView(arrangedSubviews: [backButton, forwardButton, urlTextField, airPlayToggleButton, settingsButton])
        topStack.axis = .horizontal
        topStack.spacing = 8
        topStack.alignment = .center
        topStack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(topStack)

        // 2. Setup Web View with macOS Safari User-Agent & Edge Swipe Gestures
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        
        // macOS Safari User-Agent for desktop-class layout
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        
        view.addSubview(webView)

        // Also assign delegate to DisplayController's webView so back/forward updates URL bar there too
        DisplayController.shared.webView.navigationDelegate = self

        // 3. Setup Touchpad Container (Hidden initially)
        trackpadContainer = UIView()
        trackpadContainer.translatesAutoresizingMaskIntoConstraints = false
        trackpadContainer.isHidden = true
        view.addSubview(trackpadContainer)

        trackpadView = UIView()
        trackpadView.translatesAutoresizingMaskIntoConstraints = false
        trackpadView.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.5)
        trackpadView.layer.cornerRadius = 12
        trackpadView.layer.borderWidth = 1
        trackpadView.layer.borderColor = UIColor.separator.cgColor
        trackpadContainer.addSubview(trackpadView)

        let touchpadLabel = UILabel()
        touchpadLabel.translatesAutoresizingMaskIntoConstraints = false
        touchpadLabel.text = "iPad Touchpad Control Area\n(Drag to move cursor, Tap to click)"
        touchpadLabel.numberOfLines = 2
        touchpadLabel.textAlignment = .center
        touchpadLabel.textColor = .secondaryLabel
        touchpadLabel.font = .systemFont(ofSize: 14, weight: .medium)
        trackpadView.addSubview(touchpadLabel)

        keyboardTriggerButton = UIButton(type: .system)
        keyboardTriggerButton.translatesAutoresizingMaskIntoConstraints = false
        keyboardTriggerButton.setTitle("⌨️ Show Keyboard", for: .normal)
        keyboardTriggerButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        keyboardTriggerButton.backgroundColor = .systemBackground
        keyboardTriggerButton.layer.cornerRadius = 8
        keyboardTriggerButton.layer.borderWidth = 1
        keyboardTriggerButton.layer.borderColor = UIColor.systemBlue.cgColor
        keyboardTriggerButton.addTarget(self, action: #selector(triggerKeyboard), for: .touchUpInside)
        trackpadContainer.addSubview(keyboardTriggerButton)

        // Constraints
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 50),

            topStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            topStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            topStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            
            backButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            airPlayToggleButton.widthAnchor.constraint(equalToConstant: 90),
            settingsButton.widthAnchor.constraint(equalToConstant: 36),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            trackpadContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            trackpadContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            trackpadContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            trackpadContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            trackpadView.topAnchor.constraint(equalTo: trackpadContainer.topAnchor, constant: 16),
            trackpadView.leadingAnchor.constraint(equalTo: trackpadContainer.leadingAnchor, constant: 16),
            trackpadView.trailingAnchor.constraint(equalTo: trackpadContainer.trailingAnchor, constant: -16),
            trackpadView.bottomAnchor.constraint(equalTo: keyboardTriggerButton.topAnchor, constant: -16),

            touchpadLabel.centerXAnchor.constraint(equalTo: trackpadView.centerXAnchor),
            touchpadLabel.centerYAnchor.constraint(equalTo: trackpadView.centerYAnchor),

            keyboardTriggerButton.leadingAnchor.constraint(equalTo: trackpadContainer.leadingAnchor, constant: 16),
            keyboardTriggerButton.trailingAnchor.constraint(equalTo: trackpadContainer.trailingAnchor, constant: -16),
            keyboardTriggerButton.bottomAnchor.constraint(equalTo: trackpadContainer.bottomAnchor, constant: -16),
            keyboardTriggerButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        setupGestures()

        if let url = URL(string: "https://www.google.com") {
            webView.load(URLRequest(url: url))
            urlTextField.text = "https://www.google.com"
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screenDidConnect), name: UIScreen.didConnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenDidDisconnect), name: UIScreen.didDisconnectNotification, object: nil)
    }

    private func createButton(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    private func setupGestures() {
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        trackpadView.addGestureRecognizer(panGesture)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        trackpadView.addGestureRecognizer(tapGesture)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: trackpadView)
        gesture.setTranslation(.zero, in: trackpadView)
        DisplayController.shared.moveCursor(deltaX: translation.x, deltaY: translation.y)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        DisplayController.shared.performClickAtCursor()
    }

    @objc func goBack() {
        if isAirPlayModeActive {
            if DisplayController.shared.webView.canGoBack { DisplayController.shared.webView.goBack() }
        } else {
            if webView.canGoBack { webView.goBack() }
        }
    }

    @objc func goForward() {
        if isAirPlayModeActive {
            if DisplayController.shared.webView.canGoForward { DisplayController.shared.webView.goForward() }
        } else {
            if webView.canGoForward { webView.goForward() }
        }
    }

    @objc func toggleAirPlayMode() {
        isAirPlayModeActive.toggle()
    }

    @objc func triggerKeyboard() {
        urlTextField.becomeFirstResponder()
    }

    @objc func openSettings() {
        let alert = UIAlertController(title: "Browser Settings", message: "Manage browsing data", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Clear Cache & Cookies", style: .destructive) { _ in
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date(timeIntervalSince1970: 0)) {}
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

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
            if isAirPlayModeActive {
                DisplayController.shared.webView.load(URLRequest(url: url))
            } else {
                webView.load(URLRequest(url: url))
            }
        }
        return true
    }

    // MARK: - WKNavigationDelegate (Updates URL bar dynamically on back/forward/swipes)
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let urlString = webView.url?.absoluteString {
            urlTextField.text = urlString
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let urlString = webView.url?.absoluteString {
            urlTextField.text = urlString
        }
    }

    @objc func screenDidConnect(_ notification: Notification) {
        airPlayToggleButton.isHidden = false
    }

    @objc func screenDidDisconnect(_ notification: Notification) {
        isAirPlayModeActive = false
        airPlayToggleButton.isHidden = true
        DisplayController.shared.detachExternalScreen()
    }

    private func updateLayoutForAirPlayMode() {
        if isAirPlayModeActive && UIScreen.screens.count > 1 {
            webView.isHidden = true
            trackpadContainer.isHidden = false
            
            if let currentURL = webView.url {
                DisplayController.shared.webView.load(URLRequest(url: currentURL))
            }
            DisplayController.shared.attachToExternalScreen(UIScreen.screens[1])
        } else {
            webView.isHidden = false
            trackpadContainer.isHidden = true
            DisplayController.shared.detachExternalScreen()
        }
    }
}
