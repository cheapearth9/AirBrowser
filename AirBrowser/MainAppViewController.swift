import UIKit
import WebKit

// MARK: - Invisible first responder that forwards typing to the page on the monitor
/// While AirPlay mode is ON this view holds keyboard focus on the iPad. Everything typed (on the
/// on-screen keyboard or a hardware keyboard) is forwarded to the web page shown on the monitor.
final class KeyCaptureView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onKey: ((String, String, Int) -> Void)?
    var onResign: (() -> Void)?

    /// false = no on-screen keyboard (a hardware keyboard still works). true = show it.
    var showsSoftwareKeyboard = false

    private let emptyInputView = UIView(frame: .zero)

    override var canBecomeFirstResponder: Bool { true }

    // An empty input view keeps the on-screen keyboard hidden while hardware keys still arrive.
    override var inputView: UIView? { showsSoftwareKeyboard ? nil : emptyInputView }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onResign?()
        return result
    }

    // MARK: UIKeyInput (letters, numbers, space, return, backspace)
    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onBackspace?()
    }

    // MARK: Keys that don't produce text (arrows, escape, page up/down, ...)
    override var keyCommands: [UIKeyCommand]? {
        let inputs: [String] = [
            UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
            UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
            UIKeyCommand.inputEscape,
            UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown,
            UIKeyCommand.inputHome, UIKeyCommand.inputEnd,
            "\t"
        ]
        return inputs.map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }

        let names: [String: (String, String, Int)] = [
            UIKeyCommand.inputUpArrow: ("ArrowUp", "ArrowUp", 38),
            UIKeyCommand.inputDownArrow: ("ArrowDown", "ArrowDown", 40),
            UIKeyCommand.inputLeftArrow: ("ArrowLeft", "ArrowLeft", 37),
            UIKeyCommand.inputRightArrow: ("ArrowRight", "ArrowRight", 39),
            UIKeyCommand.inputEscape: ("Escape", "Escape", 27),
            UIKeyCommand.inputPageUp: ("PageUp", "PageUp", 33),
            UIKeyCommand.inputPageDown: ("PageDown", "PageDown", 34),
            UIKeyCommand.inputHome: ("Home", "Home", 36),
            UIKeyCommand.inputEnd: ("End", "End", 35),
            "\t": ("Tab", "Tab", 9)
        ]

        if let (key, code, keyCode) = names[input] {
            onKey?(key, code, keyCode)
        }
    }

    // MARK: Cmd+V
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return action == #selector(paste(_:))
    }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            onText?(text)
        }
    }
}

// MARK: - Main iPad screen
class MainAppViewController: UIViewController, UITextFieldDelegate, WKNavigationDelegate {

    /// The one shared web view (owned by DisplayController). It sits on the iPad normally
    /// and moves to the monitor while AirPlay mode is ON.
    private var webView: WKWebView { DisplayController.shared.webView }

    var urlTextField: UITextField!

    private var toolbar: UIView!
    private var trackpadContainer: UIView!
    private var trackpadView: UIView!
    private var keyboardTriggerButton: UIButton!
    private var airPlayToggleButton: UIButton!
    private var keyCapture: KeyCaptureView!

    private var isAirPlayModeActive = false
    private var isSoftKeyboardShown = false

    // While AirPlay mode is ON the iPad pointer is locked, so a physical mouse drives the monitor instead.
    override var prefersPointerLocked: Bool { isAirPlayModeActive }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 1. Top toolbar
        toolbar = UIView()
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
        urlTextField.clearButtonMode = .whileEditing
        urlTextField.autocorrectionType = .no
        urlTextField.autocapitalizationType = .none
        urlTextField.keyboardType = .webSearch
        urlTextField.delegate = self

        airPlayToggleButton = createButton(title: "AirPlay: OFF", action: #selector(toggleAirPlayMode))
        airPlayToggleButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        airPlayToggleButton.isHidden = !DisplayController.shared.isExternalDisplayAvailable

        let settingsButton = createButton(title: "⚙️", action: #selector(openSettings))

        let topStack = UIStackView(arrangedSubviews: [backButton, forwardButton, urlTextField, airPlayToggleButton, settingsButton])
        topStack.axis = .horizontal
        topStack.spacing = 8
        topStack.alignment = .center
        topStack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(topStack)

        // 2. Touchpad container (hidden until AirPlay mode is ON)
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
        touchpadLabel.text = "iPad Touchpad Control Area\n(Drag to move, tap to click, two fingers to scroll)"
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

        // 3. Invisible view that receives typing and forwards it to the page on the monitor
        keyCapture = KeyCaptureView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        keyCapture.alpha = 0.01
        keyCapture.onText = { text in DisplayController.shared.typeText(text) }
        keyCapture.onBackspace = { DisplayController.shared.pressBackspace() }
        keyCapture.onKey = { key, code, keyCode in
            DisplayController.shared.pressKey(key, code: code, keyCode: keyCode)
        }
        keyCapture.onResign = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.isAirPlayModeActive else { return }
                // The system keyboard's dismiss button (or the URL bar) took focus:
                // reset the toggle, then take focus back unless the URL bar has it.
                self.setSoftKeyboardShown(false)
                self.focusCaptureIfNeeded()
            }
        }
        view.insertSubview(keyCapture, at: 0)

        // Constraints (the web view is placed separately, see placeWebViewOnIPad)
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

            // The touchpad stops above the on-screen keyboard, so the keyboard button stays reachable.
            trackpadContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            trackpadContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            trackpadContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            trackpadContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

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

        // 4. Shared web view
        webView.navigationDelegate = self
        if DisplayController.shared.isExternalConnected {
            // Already on the monitor (e.g. this controller was rebuilt): keep it there.
            isAirPlayModeActive = true
            trackpadContainer.isHidden = false
        } else {
            placeWebViewOnIPad()
        }
        updateAirPlayButton()

        if webView.url == nil && !webView.isLoading, let url = URL(string: "https://www.google.com") {
            webView.load(URLRequest(url: url))
        }
        urlTextField.text = webView.url?.absoluteString ?? "https://www.google.com"

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalDisplayAvailabilityChanged),
            name: .externalDisplayAvailabilityChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(downloadMessage(_:)),
            name: DownloadManager.message,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateMouseClickBlocking()
        focusCaptureIfNeeded()
    }

    private func createButton(title: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    // MARK: - Touchpad gestures

    private func setupGestures() {
        // Only real finger touches. Mouse clicks are handled separately, so nothing fires twice.
        let fingersOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        // One finger: move the cursor
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.minimumNumberOfTouches = 1
        panGesture.maximumNumberOfTouches = 1
        panGesture.allowedTouchTypes = fingersOnly
        trackpadView.addGestureRecognizer(panGesture)

        // Two fingers: scroll
        let scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll(_:)))
        scrollGesture.minimumNumberOfTouches = 2
        scrollGesture.maximumNumberOfTouches = 2
        scrollGesture.allowedTouchTypes = fingersOnly
        trackpadView.addGestureRecognizer(scrollGesture)

        // Tap: click
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.allowedTouchTypes = fingersOnly
        trackpadView.addGestureRecognizer(tapGesture)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: trackpadView)
        gesture.setTranslation(.zero, in: trackpadView)
        DisplayController.shared.moveCursor(deltaX: translation.x, deltaY: translation.y)
    }

    @objc private func handleTwoFingerScroll(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: trackpadView)
        gesture.setTranslation(.zero, in: trackpadView)
        // Natural scrolling: fingers moving up scroll the page down.
        DisplayController.shared.scroll(deltaX: -translation.x * 2, deltaY: -translation.y * 2)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        DisplayController.shared.performClickAtCursor()
    }

    // MARK: - Navigation

    @objc func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    @objc func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    @objc func openSettings() {
        let alert = UIAlertController(title: "Browser Settings", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "History", style: .default) { [weak self] _ in
            self?.showHistory()
        })
        alert.addAction(UIAlertAction(title: "Downloads", style: .default) { [weak self] _ in
            self?.showDownloads()
        })
        alert.addAction(UIAlertAction(title: "Clear Cache & Cookies", style: .destructive) { [weak self] _ in
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date(timeIntervalSince1970: 0)) {}
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })
        present(alert, animated: true)
    }

    // MARK: - History, downloads and notices

    private func showHistory() {
        let controller = HistoryViewController()
        controller.onSelect = { [weak self] url in
            self?.webView.load(URLRequest(url: url))
        }
        presentLibrary(controller)
    }

    private func showDownloads() {
        presentLibrary(DownloadsViewController())
    }

    private func presentLibrary(_ controller: LibraryViewController) {
        controller.onClose = { [weak self] in
            self?.focusCaptureIfNeeded()
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    @objc private func downloadMessage(_ notification: Notification) {
        if let text = notification.userInfo?["text"] as? String {
            showToast(text)
        }
    }

    /// Small pill at the bottom of the iPad screen that fades away by itself.
    private func showToast(_ text: String) {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.numberOfLines = 2
        label.textAlignment = .center

        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        pill.layer.cornerRadius = 14
        pill.alpha = 0
        pill.addSubview(label)
        view.addSubview(pill)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -90),
            pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48)
        ])

        UIView.animate(withDuration: 0.2, animations: {
            pill.alpha = 1
        }, completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 2.5, options: [], animations: {
                pill.alpha = 0
            }, completion: { _ in
                pill.removeFromSuperview()
            })
        })
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
            webView.load(URLRequest(url: url))
        }
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // Like Safari: tapping the bar selects the whole address, so typing replaces it.
        DispatchQueue.main.async {
            textField.selectAll(nil)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        // Back to typing into the page on the monitor.
        focusCaptureIfNeeded()
    }

    // MARK: - Downloads (links that are files, or pages the server marks as attachments)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased() ?? ""
        let isAttachment = disposition.hasPrefix("attachment")

        if navigationResponse.isForMainFrame && (isAttachment || !navigationResponse.canShowMIMEType) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
    }

    // MARK: - WKNavigationDelegate (keeps the URL bar in sync, including swipes and back/forward)
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

    // MARK: - AirPlay mode

    @objc func toggleAirPlayMode() {
        setAirPlayMode(!isAirPlayModeActive)
    }

    private func setAirPlayMode(_ on: Bool) {
        let display = DisplayController.shared

        if on && display.startExternalPresentation() {
            // The browser is now fullscreen on the monitor; the iPad becomes a touchpad + keyboard.
            isAirPlayModeActive = true
            trackpadContainer.isHidden = false
            setSoftKeyboardShown(false)
            _ = keyCapture.becomeFirstResponder()
        } else {
            // Put the browser back on the iPad. With nothing on the monitor, it mirrors the iPad again.
            isAirPlayModeActive = false
            setSoftKeyboardShown(false)
            _ = keyCapture.resignFirstResponder()
            display.stopExternalPresentation()
            placeWebViewOnIPad()
            trackpadContainer.isHidden = true
        }

        updateAirPlayButton()
        updateMouseClickBlocking()
        setNeedsUpdateOfPrefersPointerLocked()
    }

    /// While AirPlay mode is ON, mouse clicks must only reach the monitor, never an iPad button.
    private func updateMouseClickBlocking() {
        (view.window as? MainWindow)?.ignoresMouseClicks = isAirPlayModeActive
    }

    private func updateAirPlayButton() {
        airPlayToggleButton.setTitle(isAirPlayModeActive ? "AirPlay: ON" : "AirPlay: OFF", for: .normal)
        airPlayToggleButton.setTitleColor(isAirPlayModeActive ? .systemBlue : .systemGray, for: .normal)
    }

    @objc private func externalDisplayAvailabilityChanged() {
        let available = DisplayController.shared.isExternalDisplayAvailable
        airPlayToggleButton.isHidden = !available
        if !available && isAirPlayModeActive {
            // Monitor unplugged while ON: bring the browser back to the iPad.
            setAirPlayMode(false)
        }
    }

    @objc private func appDidBecomeActive() {
        focusCaptureIfNeeded()
    }

    // MARK: - Keyboard

    /// Shows or hides the on-screen keyboard. It types into the page on the monitor, not into the URL bar.
    @objc func triggerKeyboard() {
        setSoftKeyboardShown(!isSoftKeyboardShown)
        if keyCapture.isFirstResponder {
            keyCapture.reloadInputViews()
        } else {
            _ = keyCapture.becomeFirstResponder()
        }
    }

    private func setSoftKeyboardShown(_ shown: Bool) {
        isSoftKeyboardShown = shown
        keyCapture.showsSoftwareKeyboard = shown
        keyboardTriggerButton.setTitle(shown ? "⌨️ Hide Keyboard" : "⌨️ Show Keyboard", for: .normal)
    }

    private func focusCaptureIfNeeded() {
        guard isAirPlayModeActive, view.window != nil, presentedViewController == nil, !urlTextField.isFirstResponder else { return }
        if !keyCapture.isFirstResponder {
            _ = keyCapture.becomeFirstResponder()
        }
    }

    // MARK: - Web view placement

    private func placeWebViewOnIPad() {
        let webView = self.webView
        guard webView.superview !== view else { return }

        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, belowSubview: trackpadContainer)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }
}
