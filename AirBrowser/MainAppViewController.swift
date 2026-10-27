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
    var onCopy: (() -> Void)?
    var onBackspaceWord: (() -> Void)?
    var onSelectAll: (() -> Void)?

    /// false = no on-screen keyboard (a hardware keyboard still works). true = show it.
    var showsSoftwareKeyboard = false

    private let emptyInputView = UIView(frame: .zero)

    override var canBecomeFirstResponder: Bool { true }

    // An empty input view keeps the on-screen keyboard hidden while hardware keys still arrive.
    override var inputView: UIView? { showsSoftwareKeyboard ? nil : emptyInputView }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        stopRepeating()
        onResign?()
        return result
    }

    // MARK: UIKeyInput (letters, numbers, space, backspace)
    var hasText: Bool { true }

    private var lastReturnPress = Date.distantPast
    private var lastDeleteTime = Date.distantPast
    private var deleteStreak = 0

    func insertText(_ text: String) {
        // Return is handled in pressesBegan below; ignore the same key arriving here a moment later.
        if text == "\n" && Date().timeIntervalSince(lastReturnPress) < 0.2 { return }
        onText?(text)
    }

    /// Holding Backspace repeats this call. After about a second of holding, it switches from one letter
    /// to a whole word per repeat, like a real keyboard. Works for the on-screen and a hardware keyboard.
    func deleteBackward() {
        let now = Date()
        if now.timeIntervalSince(lastDeleteTime) < 0.25 {
            deleteStreak += 1
        } else {
            deleteStreak = 0
        }
        lastDeleteTime = now

        if deleteStreak >= 8 {
            onBackspaceWord?()
        } else {
            onBackspace?()
        }
    }

    // MARK: Keys that don't produce text (arrows, escape, enter, tab, page up/down, ...)
    private var repeatTimer: Timer?

    private func domKey(for usage: UIKeyboardHIDUsage) -> (String, String, Int)? {
        switch usage {
        case .keyboardUpArrow: return ("ArrowUp", "ArrowUp", 38)
        case .keyboardDownArrow: return ("ArrowDown", "ArrowDown", 40)
        case .keyboardLeftArrow: return ("ArrowLeft", "ArrowLeft", 37)
        case .keyboardRightArrow: return ("ArrowRight", "ArrowRight", 39)
        case .keyboardEscape: return ("Escape", "Escape", 27)
        case .keyboardReturnOrEnter, .keypadEnter: return ("Enter", "Enter", 13)
        case .keyboardTab: return ("Tab", "Tab", 9)
        case .keyboardPageUp: return ("PageUp", "PageUp", 33)
        case .keyboardPageDown: return ("PageDown", "PageDown", 34)
        case .keyboardHome: return ("Home", "Home", 36)
        case .keyboardEnd: return ("End", "End", 35)
        case .keyboardDeleteForward: return ("Delete", "Delete", 46)
        default: return nil
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()

        for press in presses {
            if let key = press.key,
               !key.modifierFlags.contains(.command),
               let name = domKey(for: key.keyCode) {
                if name.0 == "Enter" { lastReturnPress = Date() }
                onKey?(name.0, name.1, name.2)
                startRepeating(name)
            } else {
                unhandled.insert(press)
            }
        }

        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeating()
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeating()
        super.pressesCancelled(presses, with: event)
    }

    /// Holding an arrow key or Page Up/Down keeps sending it, like a normal keyboard.
    private func startRepeating(_ name: (String, String, Int)) {
        stopRepeating()
        let repeatable = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown"]
        guard repeatable.contains(name.0) else { return }

        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.onKey?(name.0, name.1, name.2)
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: Cmd+V
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return action == #selector(paste(_:)) || action == #selector(copy(_:)) || action == #selector(selectAll(_:))
    }

    override func copy(_ sender: Any?) {
        onCopy?()
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            onText?(text)
        }
    }
}

// MARK: - Small helper views

/// A view that tells its owner every time it has been laid out (used to keep the split handle on the touchpad).
final class LayoutCallbackView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// The bar that decides how wide each of the two pages is. A thin line with a square (not round) grip.
/// Only the grip reacts to touches, so the buttons under the line keep working.
final class SplitHandleView: UIView {
    private let line = UIView()
    private let grip = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        line.backgroundColor = UIColor.systemGray3
        line.isUserInteractionEnabled = false
        addSubview(line)

        grip.backgroundColor = UIColor.systemGray
        grip.layer.cornerRadius = 3
        grip.layer.borderWidth = 2
        grip.layer.borderColor = UIColor.systemBackground.cgColor
        grip.isUserInteractionEnabled = false
        addSubview(grip)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(x: bounds.midX - 1.5, y: 0, width: 3, height: bounds.height)
        grip.frame = CGRect(x: bounds.midX - 9, y: bounds.midY - 36, width: 18, height: 72)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return grip.frame.insetBy(dx: -18, dy: -18).contains(point)
    }
}

// MARK: - Main iPad screen
class MainAppViewController: UIViewController, UITextFieldDelegate, WKNavigationDelegate, UIPointerInteractionDelegate {

    /// The one shared web view (owned by DisplayController). It sits on the iPad normally
    /// and moves to the monitor while AirPlay mode is ON.
    private var webView: WKWebView { DisplayController.shared.webView }

    var urlTextField: UITextField!
    /// The address bar of the second page (only shown while two pages are open).
    var urlTextField2: UITextField!

    private var toolbar: UIView!
    private var trackpadContainer: UIView!
    private var trackpadView: UIView!
    private var keyboardTriggerButton: UIButton!
    private var airPlayToggleButton: UIButton!
    private var reloadButton: UIButton!
    private var reloadButton2: UIButton!
    /// Right-hand column in AirPlay mode: the "Add a second session" button.
    private var sessionPanel: UIView!
    private var addSessionButton: UIButton!
    private var resizeMiddleButton: UIButton!
    private var screenshotButton: UIButton!
    private var splitHandle: SplitHandleView!
    private var autoHideButton: UIButton!
    private var toolbarLeadingConstraint: NSLayoutConstraint?
    private var focusObserversAdded = false
    private var keyCapture: KeyCaptureView!

    private var isAirPlayModeActive = false
    private var isSoftKeyboardShown = false
    private var lastWindowed: Bool?
    private var shownPointerNotice = false
    private var pointerHider: UIPointerInteraction?
    private var webViewConstraints: [NSLayoutConstraint] = []

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

        // Refresh button inside the bar, on the right. While you type, the X (clear) button takes its place.
        reloadButton = UIButton(type: .system)
        reloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        reloadButton.frame = CGRect(x: 0, y: 0, width: 36, height: 30)
        reloadButton.addTarget(self, action: #selector(reloadTapped(_:)), for: .touchUpInside)
        urlTextField = makeURLField(reload: reloadButton)

        // Second address bar: hidden until a second session is added (the bar is then cut in half).
        reloadButton2 = UIButton(type: .system)
        reloadButton2.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        reloadButton2.frame = CGRect(x: 0, y: 0, width: 36, height: 30)
        reloadButton2.addTarget(self, action: #selector(reloadTapped(_:)), for: .touchUpInside)
        urlTextField2 = makeURLField(reload: reloadButton2)
        urlTextField2.isHidden = true

        airPlayToggleButton = createButton(title: "AirPlay: OFF", action: #selector(toggleAirPlayMode))
        airPlayToggleButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        airPlayToggleButton.isHidden = !(DisplayController.shared.isExternalDisplayAvailable || UIScreen.screens.count > 1)

        let settingsButton = createButton(title: "⚙️", action: #selector(openSettings))

        // Keep AirPlay and the other buttons whole when the window is narrow (Split View). The address bar gives way first.
        airPlayToggleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        backButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        forwardButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        urlTextField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        urlTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topStack = UIStackView(arrangedSubviews: [backButton, forwardButton, urlTextField, urlTextField2, airPlayToggleButton, settingsButton])
        topStack.axis = .horizontal
        topStack.spacing = 8
        topStack.alignment = .center
        topStack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(topStack)

        // 2. Touchpad container (hidden until AirPlay mode is ON)
        let container = LayoutCallbackView()
        container.onLayout = { [weak self] in self?.layoutSplitHandle() }
        trackpadContainer = container
        trackpadContainer.translatesAutoresizingMaskIntoConstraints = false
        trackpadContainer.isHidden = true
        view.addSubview(trackpadContainer)

        // Right-hand column (about 20 %): where a second session is added or closed.
        sessionPanel = UIView()
        sessionPanel.translatesAutoresizingMaskIntoConstraints = false
        sessionPanel.isHidden = true
        view.addSubview(sessionPanel)

        addSessionButton = makeClickButton(title: "Add a second session", action: #selector(sessionButtonTapped))
        addSessionButton.translatesAutoresizingMaskIntoConstraints = false
        addSessionButton.titleLabel?.numberOfLines = 0
        addSessionButton.titleLabel?.textAlignment = .center
        addSessionButton.titleLabel?.lineBreakMode = .byWordWrapping
        addSessionButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        addSessionButton.titleLabel?.adjustsFontSizeToFitWidth = true
        addSessionButton.titleLabel?.minimumScaleFactor = 0.7

        // Under it (two pages only): puts the split bar back in the middle.
        resizeMiddleButton = makeClickButton(title: "Resize back to middle", action: #selector(resizeBackToMiddle))
        resizeMiddleButton.translatesAutoresizingMaskIntoConstraints = false
        resizeMiddleButton.titleLabel?.numberOfLines = 0
        resizeMiddleButton.titleLabel?.textAlignment = .center
        resizeMiddleButton.titleLabel?.lineBreakMode = .byWordWrapping
        resizeMiddleButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        resizeMiddleButton.titleLabel?.adjustsFontSizeToFitWidth = true
        resizeMiddleButton.titleLabel?.minimumScaleFactor = 0.7
        resizeMiddleButton.isHidden = true

        // Always last: saves a picture of the monitor (only the monitor) to Photos.
        screenshotButton = makeClickButton(title: "Take a screenshot", action: #selector(screenshotTapped))
        screenshotButton.translatesAutoresizingMaskIntoConstraints = false
        screenshotButton.titleLabel?.numberOfLines = 0
        screenshotButton.titleLabel?.textAlignment = .center
        screenshotButton.titleLabel?.lineBreakMode = .byWordWrapping
        screenshotButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        screenshotButton.titleLabel?.adjustsFontSizeToFitWidth = true
        screenshotButton.titleLabel?.minimumScaleFactor = 0.7

        // The column: Add / Close a session, then (two pages only) Resize back to middle, then Take a screenshot.
        let sessionStack = UIStackView(arrangedSubviews: [addSessionButton, resizeMiddleButton, screenshotButton])
        sessionStack.axis = .vertical
        sessionStack.spacing = 12
        sessionStack.alignment = .fill
        sessionStack.distribution = .fill
        sessionStack.translatesAutoresizingMaskIntoConstraints = false
        sessionPanel.addSubview(sessionStack)

        trackpadView = UIView()
        trackpadView.translatesAutoresizingMaskIntoConstraints = false
        trackpadView.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.5)
        trackpadView.layer.cornerRadius = 12
        trackpadView.layer.borderWidth = 1
        trackpadView.layer.borderColor = UIColor.separator.cgColor
        trackpadContainer.addSubview(trackpadView)

        let touchpadLabel = UILabel()
        touchpadLabel.translatesAutoresizingMaskIntoConstraints = false
        touchpadLabel.text = "iPad Touchpad Control Area\n(Drag to move, tap to click, two fingers to scroll, two-finger tap to right click)"
        touchpadLabel.numberOfLines = 0
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
        keyboardTriggerButton.titleLabel?.adjustsFontSizeToFitWidth = true
        keyboardTriggerButton.titleLabel?.minimumScaleFactor = 0.7

        // Bottom row: Show Keyboard takes the left half, Esc and Enter share the right half
        let escButton = makeClickButton(title: "Esc", action: #selector(escTapped))
        let enterButton = makeClickButton(title: "Enter", action: #selector(enterTapped))
        let bottomRow = UIStackView(arrangedSubviews: [keyboardTriggerButton, escButton, enterButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 12
        bottomRow.distribution = .fill
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        trackpadContainer.addSubview(bottomRow)

        // Arrow keys in the top-right corner of the touchpad (up on top, left / down / right below)
        let upButton = makeArrowButton(symbol: "arrow.up", tag: 1)
        let downButton = makeArrowButton(symbol: "arrow.down", tag: 2)
        let leftButton = makeArrowButton(symbol: "arrow.left", tag: 3)
        let rightButton = makeArrowButton(symbol: "arrow.right", tag: 4)
        let arrowPad = UIView()
        arrowPad.translatesAutoresizingMaskIntoConstraints = false
        for arrow in [upButton, downButton, leftButton, rightButton] {
            arrow.translatesAutoresizingMaskIntoConstraints = false
            arrowPad.addSubview(arrow)
        }
        trackpadView.addSubview(arrowPad)

        // Top-left corner of the touchpad: hide the monitor's cursor after 10 seconds without moving it
        autoHideButton = UIButton(type: .system)
        autoHideButton.translatesAutoresizingMaskIntoConstraints = false
        autoHideButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        autoHideButton.titleLabel?.numberOfLines = 2
        autoHideButton.titleLabel?.adjustsFontSizeToFitWidth = true
        autoHideButton.titleLabel?.minimumScaleFactor = 0.6
        autoHideButton.titleLabel?.textAlignment = .center
        autoHideButton.layer.cornerRadius = 12
        autoHideButton.layer.borderWidth = 1
        autoHideButton.addTarget(self, action: #selector(toggleAutoHideCursor), for: .touchUpInside)
        trackpadView.addSubview(autoHideButton)
        updateAutoHideButton()

        // Left / right click buttons under the touchpad, like a laptop
        let leftClickButton = makeClickButton(title: "Left Click", action: #selector(leftClickUp))
        // Hold it and slide a finger on the touchpad to highlight text, like holding a laptop's button.
        leftClickButton.addTarget(self, action: #selector(leftClickDown), for: .touchDown)
        leftClickButton.addTarget(self, action: #selector(leftClickUp), for: [.touchUpOutside, .touchCancel])
        let rightClickButton = makeClickButton(title: "Right Click", action: #selector(rightClickTapped))
        let clickStack = UIStackView(arrangedSubviews: [leftClickButton, rightClickButton])
        clickStack.axis = .horizontal
        clickStack.spacing = 12
        clickStack.distribution = .fillEqually
        clickStack.translatesAutoresizingMaskIntoConstraints = false
        trackpadContainer.addSubview(clickStack)

        // 3. Invisible view that receives typing and forwards it to the page on the monitor
        keyCapture = KeyCaptureView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        keyCapture.alpha = 0.01
        keyCapture.onText = { text in DisplayController.shared.typeText(text) }
        keyCapture.onBackspace = { DisplayController.shared.pressBackspace() }
        keyCapture.onBackspaceWord = { DisplayController.shared.pressBackspaceWord() }
        keyCapture.onKey = { key, code, keyCode in
            DisplayController.shared.pressKey(key, code: code, keyCode: keyCode)
        }
        keyCapture.onCopy = { DisplayController.shared.copySelection() }
        keyCapture.onSelectAll = { DisplayController.shared.selectAllInPage() }
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

        // Leading edge of the toolbar: moved in when the window is not full screen (see viewDidLayoutSubviews)
        toolbarLeadingConstraint = topStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12)

        // Constraints (the web view is placed separately, see placeWebViewOnIPad)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 50),

            topStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbarLeadingConstraint!,
            topStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),

            backButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            airPlayToggleButton.widthAnchor.constraint(equalToConstant: 90),
            settingsButton.widthAnchor.constraint(equalToConstant: 36),

            // The touchpad stops above the on-screen keyboard, so the keyboard button stays reachable.
            trackpadContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            trackpadContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            trackpadContainer.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, multiplier: 0.8),

            sessionPanel.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            sessionPanel.leadingAnchor.constraint(equalTo: trackpadContainer.trailingAnchor),
            sessionPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            sessionPanel.bottomAnchor.constraint(equalTo: trackpadContainer.bottomAnchor),

            sessionStack.topAnchor.constraint(equalTo: sessionPanel.topAnchor, constant: 16),
            sessionStack.leadingAnchor.constraint(equalTo: sessionPanel.leadingAnchor),
            sessionStack.trailingAnchor.constraint(equalTo: sessionPanel.trailingAnchor, constant: -16),
            addSessionButton.heightAnchor.constraint(equalToConstant: 76),
            resizeMiddleButton.heightAnchor.constraint(equalToConstant: 76),
            screenshotButton.heightAnchor.constraint(equalToConstant: 76),

            urlTextField2.widthAnchor.constraint(equalTo: urlTextField.widthAnchor).withPriority(999),
            trackpadContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            trackpadView.topAnchor.constraint(equalTo: trackpadContainer.topAnchor, constant: 16),
            trackpadView.leadingAnchor.constraint(equalTo: trackpadContainer.leadingAnchor, constant: 16),
            trackpadView.trailingAnchor.constraint(equalTo: trackpadContainer.trailingAnchor, constant: -16),
            trackpadView.bottomAnchor.constraint(equalTo: clickStack.topAnchor, constant: -12),

            clickStack.leadingAnchor.constraint(equalTo: trackpadContainer.leadingAnchor, constant: 16),
            clickStack.trailingAnchor.constraint(equalTo: trackpadContainer.trailingAnchor, constant: -16),
            clickStack.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -12),
            clickStack.heightAnchor.constraint(equalToConstant: 48),

            touchpadLabel.centerXAnchor.constraint(equalTo: trackpadView.centerXAnchor),
            touchpadLabel.centerYAnchor.constraint(equalTo: trackpadView.centerYAnchor),

            // Bottom row: keyboard button is twice as wide as Esc, and Esc as wide as Enter
            bottomRow.leadingAnchor.constraint(equalTo: trackpadContainer.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: trackpadContainer.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: trackpadContainer.bottomAnchor, constant: -16),
            bottomRow.heightAnchor.constraint(equalToConstant: 44),
            escButton.widthAnchor.constraint(equalTo: enterButton.widthAnchor),
            keyboardTriggerButton.widthAnchor.constraint(equalTo: escButton.widthAnchor, multiplier: 2),

            // Cursor auto-hide toggle, top-left corner of the touchpad
            autoHideButton.topAnchor.constraint(equalTo: trackpadView.topAnchor, constant: 10),
            autoHideButton.leadingAnchor.constraint(equalTo: trackpadView.leadingAnchor, constant: 10),
            autoHideButton.widthAnchor.constraint(equalToConstant: 150).withPriority(750),
            autoHideButton.trailingAnchor.constraint(lessThanOrEqualTo: arrowPad.leadingAnchor, constant: -8),
            autoHideButton.heightAnchor.constraint(equalToConstant: 52),

            // Arrow keys, top-right corner of the touchpad
            arrowPad.topAnchor.constraint(equalTo: trackpadView.topAnchor, constant: 10),
            arrowPad.trailingAnchor.constraint(equalTo: trackpadView.trailingAnchor, constant: -10),
            arrowPad.widthAnchor.constraint(equalToConstant: 168),
            arrowPad.heightAnchor.constraint(equalToConstant: 110),
            upButton.topAnchor.constraint(equalTo: arrowPad.topAnchor),
            upButton.centerXAnchor.constraint(equalTo: downButton.centerXAnchor),
            leftButton.leadingAnchor.constraint(equalTo: arrowPad.leadingAnchor),
            leftButton.bottomAnchor.constraint(equalTo: arrowPad.bottomAnchor),
            downButton.leadingAnchor.constraint(equalTo: leftButton.trailingAnchor, constant: 6),
            downButton.bottomAnchor.constraint(equalTo: arrowPad.bottomAnchor),
            rightButton.leadingAnchor.constraint(equalTo: downButton.trailingAnchor, constant: 6),
            rightButton.bottomAnchor.constraint(equalTo: arrowPad.bottomAnchor)
        ])

        for arrow in [upButton, downButton, leftButton, rightButton] {
            NSLayoutConstraint.activate([
                arrow.widthAnchor.constraint(equalToConstant: 52),
                arrow.heightAnchor.constraint(equalToConstant: 52)
            ])
        }

        setupGestures()
        setupPointerHandling()

        // The bar that sets how wide each of the two pages is (sits on top of the touchpad, only its grip takes touches).
        splitHandle = SplitHandleView()
        splitHandle.isHidden = true
        trackpadContainer.addSubview(splitHandle)
        let handlePan = UIPanGestureRecognizer(target: self, action: #selector(handleSplitPan(_:)))
        handlePan.maximumNumberOfTouches = 1
        splitHandle.addGestureRecognizer(handlePan)

        // Website questions (location, camera, JavaScript alerts) are shown here on the iPad, not on the monitor.
        PermissionBridge.shared.presenter = self
        PermissionBridge.shared.onDialogFinished = { [weak self] in
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        }

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
        updateSessionUI()

        if webView.url == nil && !webView.isLoading, let url = URL(string: "https://www.google.com") {
            webView.load(URLRequest(url: url))
        }
        urlTextField.text = webView.url?.absoluteString ?? "https://www.google.com"
        urlTextField2.text = ""

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneActivationChanged),
            name: UIScene.didActivateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pointerLockChanged),
            name: UIPointerLockState.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(webViewNeedsPlacement),
            name: .webViewNeedsPlacement,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionsChanged),
            name: .sessionsChanged,
            object: nil
        )
    }

    /// One address bar. Used twice, so the bar can be cut in half when there are two pages.
    private func makeURLField(reload: UIButton) -> UITextField {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.borderStyle = .roundedRect
        field.placeholder = "Enter URL or search..."
        field.font = .systemFont(ofSize: 14)
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.keyboardType = .webSearch
        field.delegate = self
        field.rightView = reload
        field.rightViewMode = .unlessEditing
        field.layer.cornerRadius = 6
        field.layer.borderColor = UIColor.systemBlue.cgColor
        field.layer.borderWidth = 0
        return field
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutSplitHandle()
        // iPadOS draws its window controls (the ••• bubble) over the top-left corner of a split or floating window,
        // which covered Back and Forward. Move the toolbar in when the window is not full screen.
        guard let window = view.window, let windowScene = window.windowScene else { return }
        let windowed = window.frame.width < windowScene.coordinateSpace.bounds.width - 1
        toolbarLeadingConstraint?.constant = windowed ? 64 : 12

        // Entering or leaving Split View decides whether the iPad pointer can be locked.
        if lastWindowed != windowed {
            lastWindowed = windowed
            refreshPointerLock()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !focusObserversAdded {
            focusObserversAdded = true
            observeWindowFocus()
        }
        updateMouseClickBlocking()
        focusCaptureIfNeeded()
        resumeAirPlayIfWanted()
        refreshPointerLock()
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

        // Tap with two fingers: right click
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        rightTap.numberOfTouchesRequired = 2
        rightTap.allowedTouchTypes = fingersOnly
        trackpadView.addGestureRecognizer(rightTap)

        // Press and hold, then slide: highlight text (like holding the mouse button down)
        let holdGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldDrag(_:)))
        holdGesture.minimumPressDuration = 0.45
        holdGesture.allowableMovement = 10
        holdGesture.numberOfTouchesRequired = 1
        holdGesture.allowedTouchTypes = fingersOnly
        trackpadView.addGestureRecognizer(holdGesture)
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

    private var holdLastPoint: CGPoint = .zero

    @objc private func handleHoldDrag(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: trackpadView)
        switch gesture.state {
        case .began:
            holdLastPoint = point
            DisplayController.shared.pointerDown()
        case .changed:
            DisplayController.shared.moveCursor(deltaX: point.x - holdLastPoint.x, deltaY: point.y - holdLastPoint.y)
            holdLastPoint = point
        case .ended, .cancelled, .failed:
            DisplayController.shared.pointerUp()
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        DisplayController.shared.performClickAtCursor()
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        DisplayController.shared.performClickAtCursor(button: 2)
    }

    private func makeClickButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.separator.cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeArrowButton(symbol: String, tag: Int) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold), forImageIn: .normal)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 12
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.separator.cgColor
        button.tag = tag
        button.addTarget(self, action: #selector(arrowPressed(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(arrowReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    @objc private func toggleAutoHideCursor() {
        DisplayController.shared.autoHideCursor.toggle()
        updateAutoHideButton()
        showToast(DisplayController.shared.autoHideCursor ? "Cursor hides after 10 seconds" : "Cursor always visible")
    }

    private func updateAutoHideButton() {
        let on = DisplayController.shared.autoHideCursor
        autoHideButton.setTitle(on ? "Auto-hide cursor\nON (10 s)" : "Auto-hide cursor\nOFF", for: .normal)
        autoHideButton.setTitleColor(on ? .systemBlue : .secondaryLabel, for: .normal)
        autoHideButton.backgroundColor = on ? UIColor.systemBlue.withAlphaComponent(0.12) : .systemBackground
        autoHideButton.layer.borderColor = (on ? UIColor.systemBlue : UIColor.separator).cgColor
    }

    // Keys sent to the page on the monitor (for YouTube TV and any page that uses the keyboard)
    private let arrowKeys: [Int: (String, Int)] = [
        1: ("ArrowUp", 38), 2: ("ArrowDown", 40), 3: ("ArrowLeft", 37), 4: ("ArrowRight", 39)
    ]
    private var arrowRepeatTimer: Timer?

    /// Pressing an arrow sends it at once; holding it keeps sending it, fast (to scroll through YouTube TV).
    @objc private func arrowPressed(_ sender: UIButton) {
        guard let key = arrowKeys[sender.tag] else { return }
        stopArrowRepeat()
        DisplayController.shared.pressKey(key.0, code: key.0, keyCode: key.1)
        arrowRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.arrowRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
                DisplayController.shared.pressKey(key.0, code: key.0, keyCode: key.1)
            }
        }
    }

    @objc private func arrowReleased() {
        stopArrowRepeat()
    }

    private func stopArrowRepeat() {
        arrowRepeatTimer?.invalidate()
        arrowRepeatTimer = nil
    }

    @objc private func escTapped() { DisplayController.shared.pressKey("Escape", code: "Escape", keyCode: 27) }
    @objc private func enterTapped() { DisplayController.shared.pressKey("Enter", code: "Enter", keyCode: 13) }

    // MARK: - Reload / stop (the button inside the URL bar)

    @objc private func reloadTapped(_ sender: UIButton) {
        let sessions = DisplayController.shared.sessions
        let index = (sender === reloadButton2) ? 1 : 0
        guard sessions.indices.contains(index) else { return }
        let web = sessions[index]
        DisplayController.shared.focusSession(index)
        if web.isLoading {
            web.stopLoading()
        } else {
            web.reload()
        }
        updateReloadButton()
    }

    private func updateReloadButton() {
        let sessions = DisplayController.shared.sessions
        let buttons: [UIButton] = [reloadButton, reloadButton2]
        for (index, button) in buttons.enumerated() where index < sessions.count {
            let name = sessions[index].isLoading ? "xmark" : "arrow.clockwise"
            button.setImage(UIImage(systemName: name), for: .normal)
        }
    }

    @objc private func leftClickDown() {
        DisplayController.shared.pointerDown()
    }

    @objc private func leftClickUp() {
        DisplayController.shared.pointerUp()
    }

    @objc private func rightClickTapped() {
        DisplayController.shared.performClickAtCursor(button: 2)
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
        alert.addAction(UIAlertAction(
            title: DisplayController.shared.prefersDesktopSite ? "Request Mobile Site" : "Request Desktop Site",
            style: .default
        ) { [weak self] _ in
            DisplayController.shared.prefersDesktopSite.toggle()
            self?.webView.reload()
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })
        alert.addAction(UIAlertAction(title: "Page size... (" + String(Int((DisplayController.shared.currentZoom * 100).rounded())) + "%)", style: .default) { [weak self] _ in
            self?.showPageSize()
        })
        alert.addAction(UIAlertAction(
            title: "Incognito mode: " + (DisplayController.shared.isIncognito ? "On" : "Off") + " (tap to switch)",
            style: .default
        ) { [weak self] _ in
            self?.toggleIncognito()
        })
        if YouTubeTV.isTVAddress(webView.url) {
            alert.addAction(UIAlertAction(title: "YouTube TV options...", style: .default) { [weak self] _ in
                self?.showTVOptions()
            })
        }
        alert.addAction(UIAlertAction(title: "Backup & Restore", style: .default) { [weak self] _ in
            self?.showBackupMenu()
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

    // MARK: - Page size and incognito

    private func showPageSize() {
        let controller = PageSizeViewController()
        controller.onClose = { [weak self] in
            self?.focusCaptureIfNeeded()
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    /// Switches private browsing on or off. This starts a fresh browser (the current page is closed), and
    /// leaving incognito erases everything the private session saved.
    private func toggleIncognito() {
        let display = DisplayController.shared
        let turningOn = !display.isIncognito
        let wasAirPlay = isAirPlayModeActive
        if wasAirPlay { setAirPlayMode(false, remember: false) } // bring the page back to the iPad first

        display.setIncognito(turningOn)
        webView.navigationDelegate = self
        placeWebViewOnIPad()
        applyIncognitoLook()
        urlTextField.text = ""
        urlTextField2.text = ""
        if let url = URL(string: "https://www.google.com") {
            webView.load(URLRequest(url: url))
        }
        showToast(turningOn ? "Incognito on: nothing is saved" : "Incognito off: private session erased")
        updateReloadButton()

        if wasAirPlay { setAirPlayMode(true, remember: false) }
    }

    /// A darker toolbar while browsing privately, so you can always tell.
    private func applyIncognitoLook() {
        let on = DisplayController.shared.isIncognito
        toolbar.backgroundColor = on ? UIColor(white: 0.17, alpha: 1) : .secondarySystemBackground
        for field in [urlTextField!, urlTextField2!] {
            field.overrideUserInterfaceStyle = on ? .dark : .unspecified
            field.placeholder = on ? "Incognito: enter URL or search..." : "Enter URL or search..."
        }
    }

    // MARK: - YouTube TV options

    private func showTVOptions() {
        let alert = UIAlertController(
            title: "YouTube TV options",
            message: "Auto and 1080p use H.264 video (most stable). 1440p and 4K also allow VP9. If something breaks, turn on Diagnostics recording, reload, repeat it, then Copy diagnostics.",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Quality: " + YouTubeTV.currentQuality.name + " (tap to change)", style: .default) { [weak self] _ in
            YouTubeTV.nextQuality()
            self?.showToast("YouTube TV quality: " + YouTubeTV.currentQuality.name)
            self?.applyTVSettings()
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })

        alert.addAction(UIAlertAction(title: "Ad blocking: " + (YouTubeTV.adBlockEnabled ? "On" : "Off") + " (tap to toggle)", style: .default) { [weak self] _ in
            YouTubeTV.adBlockEnabled.toggle()
            self?.showToast("YouTube TV ad blocking: " + (YouTubeTV.adBlockEnabled ? "On" : "Off"))
            self?.applyTVSettings()
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })

        alert.addAction(UIAlertAction(title: "See-through boxes: " + (YouTubeTV.transparencyFixEnabled ? "On" : "Off") + " (tap to toggle)", style: .default) { [weak self] _ in
            YouTubeTV.transparencyFixEnabled.toggle()
            self?.showToast("See-through boxes: " + (YouTubeTV.transparencyFixEnabled ? "On" : "Off"))
            self?.applyTVSettings()
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })

        alert.addAction(UIAlertAction(title: "Auto-retry errors: " + (YouTubeTV.autoRetryEnabled ? "On" : "Off") + " (tap to toggle)", style: .default) { [weak self] _ in
            YouTubeTV.autoRetryEnabled.toggle()
            self?.showToast("Auto-retry errors: " + (YouTubeTV.autoRetryEnabled ? "On" : "Off"))
            self?.applyTVSettings()
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })

        alert.addAction(UIAlertAction(title: "Diagnostics recording: " + (YouTubeTV.diagnosticsEnabled ? "On" : "Off") + " (tap to toggle)", style: .default) { [weak self] _ in
            YouTubeTV.diagnosticsEnabled.toggle()
            self?.showToast("Diagnostics recording: " + (YouTubeTV.diagnosticsEnabled ? "On" : "Off"))
            self?.applyTVSettings()
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })

        alert.addAction(UIAlertAction(title: "Copy diagnostics", style: .default) { [weak self] _ in
            self?.webView.evaluateJavaScript("window.__abReport ? window.__abReport() : 'No data yet. Open youtube.com/tv and play a video first.'") { result, _ in
                UIPasteboard.general.string = (result as? String) ?? "No data"
                self?.showToast("Diagnostics copied. Paste them into the chat.")
            }
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })
        present(alert, animated: true)
    }

    /// The TV page reads its settings when it starts, so store them in the page, then reload it.
    private func applyTVSettings() {
        let script = "try { " +
            "localStorage.setItem('" + YouTubeTV.pageQualityKey + "', '" + String(YouTubeTV.currentQuality.height) + "'); " +
            "localStorage.setItem('" + YouTubeTV.pageAdBlockKey + "', '" + (YouTubeTV.adBlockEnabled ? "1" : "0") + "'); " +
            "localStorage.setItem('" + YouTubeTV.pageClearKey + "', '" + (YouTubeTV.transparencyFixEnabled ? "1" : "0") + "'); " +
            "localStorage.setItem('" + YouTubeTV.pageRetryKey + "', '" + (YouTubeTV.autoRetryEnabled ? "1" : "0") + "'); " +
            "localStorage.setItem('" + YouTubeTV.pageDiagKey + "', '" + (YouTubeTV.diagnosticsEnabled ? "1" : "0") + "'); " +
            "} catch (e) {}"
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            self?.webView.reload()
        }
    }

    private func showBackupMenu() {
        if DisplayController.shared.isIncognito {
            showToast("Backup is not available in incognito")
            return
        }
        let alert = UIAlertController(
            title: "Backup & Restore",
            message: "Saves your logins (Google, YouTube...), history and settings to a file in the Files app. Restore it after reinstalling. Keep the file private: it can sign in as you. Downloads are not included.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Back Up to Files", style: .default) { [weak self] _ in
            guard let self = self else { return }
            BackupManager.shared.exportBackup(from: self)
        })
        alert.addAction(UIAlertAction(title: "Restore from File", style: .default) { [weak self] _ in
            guard let self = self else { return }
            BackupManager.shared.importBackup(from: self)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
        })
        present(alert, animated: true)
    }

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
        label.numberOfLines = 0
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
            let sessions = DisplayController.shared.sessions
            let index = (textField === urlTextField2) ? 1 : 0
            (sessions.indices.contains(index) ? sessions[index] : webView).load(URLRequest(url: url))
        }
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // The page whose address bar you tap becomes the focused one (it gets the keyboard and Back / Reload).
        DisplayController.shared.focusSession(textField === urlTextField2 ? 1 : 0)
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        // Desktop / mobile / YouTube TV: if the browser has to change its identity for this address
        // (for example when opening youtube.com/tv), load it again so the new identity is really sent.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame, DisplayController.shared.prepareIdentity(for: navigationAction.request, preferences: preferences, webView: webView) {
            let request: URLRequest = {
                var copy = navigationAction.request
                if YouTubeTV.isTVAddress(copy.url) { copy.cachePolicy = .reloadIgnoringLocalCacheData }
                return copy
            }()
            decisionHandler(.cancel, preferences)
            DispatchQueue.main.async {
                webView.load(request)
            }
            return
        }

        // Entering YouTube TV: load it from scratch, never from an old cached copy.
        if isMainFrame, let fresh = DisplayController.shared.freshTVRequest(for: navigationAction.request, current: webView.url) {
            decisionHandler(.cancel, preferences)
            DispatchQueue.main.async {
                webView.load(fresh)
            }
            return
        }

        // Desktop / phone mode: make the address match it (this is what fixes YouTube staying on the phone site).
        if isMainFrame, let matchedURL = DisplayController.shared.siteModeAddress(for: navigationAction.request.url) {
            decisionHandler(.cancel, preferences)
            DispatchQueue.main.async {
                webView.load(URLRequest(url: matchedURL))
            }
            return
        }

        decisionHandler(.allow, preferences)
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
        DisplayController.shared.applyZoomForCurrentPage(for: webView)
        DisplayController.shared.syncFullscreenMode()
        if let urlString = webView.url?.absoluteString {
            field(for: webView)?.text = urlString
        }
    }

    /// The address bar that belongs to a page.
    private func field(for web: WKWebView) -> UITextField? {
        guard let index = DisplayController.shared.index(of: web) else { return nil }
        return index == 0 ? urlTextField : urlTextField2
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let urlString = webView.url?.absoluteString {
            field(for: webView)?.text = urlString
        }
        updateReloadButton()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateReloadButton()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateReloadButton()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateReloadButton()
    }

    /// If the page's process crashes (the page goes blank), reload it instead of leaving it dead.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - AirPlay mode

    @objc func toggleAirPlayMode() {
        setAirPlayMode(!isAirPlayModeActive)
    }

    /// `remember` is true when the person chose this (button), false when the app does it by itself
    /// (the monitor went away or came back). Only a real choice changes what is brought back next time.
    private func setAirPlayMode(_ on: Bool, remember: Bool = true) {
        stopArrowRepeat()
        let display = DisplayController.shared

        if on && display.startExternalPresentation() {
            // The browser is now fullscreen on the monitor; the iPad becomes a touchpad + keyboard.
            isAirPlayModeActive = true
            trackpadContainer.isHidden = false
            setSoftKeyboardShown(false)
            _ = keyCapture.becomeFirstResponder()
            if remember { display.airPlayWanted = true }
        } else {
            // Put the browser back on the iPad. With nothing on the monitor, it mirrors the iPad again.
            isAirPlayModeActive = false
            setSoftKeyboardShown(false)
            _ = keyCapture.resignFirstResponder()
            display.stopExternalPresentation()
            placeWebViewOnIPad()
            trackpadContainer.isHidden = true
            if remember && !on { display.airPlayWanted = false }
        }

        updateAirPlayButton()
        updateSessionUI()
        updateMouseClickBlocking()
        pointerHider?.invalidate()
        refreshPointerLock()
    }

    /// Brings AirPlay mode back by itself if it was ON before: after the app was closed and opened again,
    /// after the monitor was unplugged and plugged in, or after another app (Split View) had the monitor.
    private func resumeAirPlayIfWanted() {
        let display = DisplayController.shared
        guard display.airPlayWanted, !isAirPlayModeActive, display.isExternalDisplayAvailable, view.window != nil else { return }
        setAirPlayMode(true, remember: false)
        if isAirPlayModeActive { showToast("AirPlay resumed") }
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
        // Keep the button while a monitor is still connected, even if the browser's monitor scene is briefly
        // reported as gone (this happens when another app takes focus in Split View).
        airPlayToggleButton.isHidden = !(available || UIScreen.screens.count > 1)

        if available {
            resumeAirPlayIfWanted()
        } else if isAirPlayModeActive {
            // The monitor scene went away. Put the page back on the iPad so it is never lost. "AirPlay wanted" is kept,
            // so the page moves back to the monitor by itself as soon as iPadOS hands the monitor over again.
            setAirPlayMode(false, remember: false)
            showToast(UIScreen.screens.count > 1
                ? "iPadOS took the monitor back (another app has focus). AirPlay resumes when AirBrowser is focused again."
                : "Monitor disconnected. AirPlay resumes when it is plugged in again.")
        }
    }

    /// Split View / Stage Manager: this window is only the key one while it has focus. Track that, so typing
    /// goes to the page on the monitor when another app is focused, and the window takes keys back when focused.
    private func observeWindowFocus() {
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: UIWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: UIWindow.didResignKeyNotification, object: nil)
    }

    @objc private func windowFocusChanged(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === view.window else { return }
        let focused = notification.name == UIWindow.didBecomeKeyNotification
        DisplayController.shared.mainWindowIsKey = focused
        if focused {
            updateMouseClickBlocking()
            focusCaptureIfNeeded()
            resumeAirPlayIfWanted()
        }
        refreshPointerLock()
    }

    @objc private func appDidBecomeActive() {
        focusCaptureIfNeeded()
        resumeAirPlayIfWanted()
        refreshPointerLock()
    }

    @objc private func sceneActivationChanged() {
        refreshPointerLock()
    }

    @objc private func pointerLockChanged() {
        refreshPointerMode(announce: false)
    }

    @objc private func webViewNeedsPlacement() {
        guard !isAirPlayModeActive else { return }
        placeWebViewOnIPad()
    }

    // MARK: - External mouse: pointer lock, and what to do when iPadOS will not lock it

    private func setupPointerHandling() {
        // Where the mouse points inside this window (used only while the pointer cannot be locked).
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        view.addGestureRecognizer(hover)

        // Hides the iPad's own gray pointer while AirPlay mode is ON. The monitor has its own cursor.
        let hider = UIPointerInteraction(delegate: self)
        view.addInteraction(hider)
        pointerHider = hider
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        return isAirPlayModeActive ? UIPointerStyle.hidden() : nil
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard isAirPlayModeActive, DisplayController.shared.usesAbsolutePointer else { return }
        guard gesture.state == .began || gesture.state == .changed else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let point = gesture.location(in: view)
        DisplayController.shared.placeCursor(fractionX: point.x / size.width, fractionY: point.y / size.height)
    }

    /// iPadOS only locks the iPad pointer while this scene is full screen, active and focused. Ask it to look again
    /// whenever one of those could have changed, then decide how the monitor cursor is driven.
    private func refreshPointerLock() {
        setNeedsUpdateOfPrefersPointerLocked()
        refreshPointerMode(announce: false)
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.setNeedsUpdateOfPrefersPointerLocked()
                self?.refreshPointerMode(announce: delay > 1)
            }
        }
    }

    /// Pointer locked: the mouse's movement drives the monitor cursor (no edges).
    /// Not locked: the iPad pointer's position inside this window drives it (the top of the window is the top of the monitor).
    private func refreshPointerMode(announce: Bool) {
        let display = DisplayController.shared
        let locked = view.window?.windowScene?.pointerLockState?.isLocked ?? false
        display.usesAbsolutePointer = isAirPlayModeActive && !locked

        if announce, display.usesAbsolutePointer, !shownPointerNotice, view.window != nil {
            shownPointerNotice = true
            showToast("iPadOS can't lock the mouse in Split View or while another app is focused, so the monitor cursor follows where the mouse points in this window. Full screen gives normal mouse movement.")
        }
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
        guard isAirPlayModeActive, view.window != nil, presentedViewController == nil, !urlTextField.isFirstResponder, !urlTextField2.isFirstResponder else { return }
        if !keyCapture.isFirstResponder {
            _ = keyCapture.becomeFirstResponder()
        }
    }

    // MARK: - Second session (two pages on the monitor)

    @objc private func sessionsChanged() {
        updateSessionUI()
    }

    /// Shows the right address bars, the split bar and the right button for the pages that are open.
    private func updateSessionUI() {
        let display = DisplayController.shared
        let split = isAirPlayModeActive && display.sessionCount == 2

        // Two pages on the monitor: the bar is cut in half. Otherwise only the page that is shown has a bar.
        urlTextField.isHidden = !(split || display.focusedIndex == 0)
        urlTextField2.isHidden = !(split || display.focusedIndex == 1)

        // The page that gets the keyboard has a blue outline on its address bar.
        urlTextField.layer.borderWidth = (split && display.focusedIndex == 0) ? 2 : 0
        urlTextField2.layer.borderWidth = (split && display.focusedIndex == 1) ? 2 : 0

        sessionPanel.isHidden = !isAirPlayModeActive
        splitHandle.isHidden = !split
        resizeMiddleButton.isHidden = !split
        addSessionButton.setTitle(display.sessionCount >= DisplayController.maxSessions ? "Close a session..." : "Add a second session", for: .normal)

        syncURLFields()
        updateReloadButton()
        layoutSplitHandle()
    }

    /// Writes each page's address into its bar (except the bar being typed in).
    private func syncURLFields() {
        let fields: [UITextField] = [urlTextField, urlTextField2]
        let sessions = DisplayController.shared.sessions
        for (index, web) in sessions.enumerated() where index < fields.count {
            if fields[index].isFirstResponder { continue }
            if let address = web.url?.absoluteString { fields[index].text = address }
        }
    }

    @objc private func sessionButtonTapped() {
        let display = DisplayController.shared
        guard isAirPlayModeActive else { return }

        if display.sessionCount < DisplayController.maxSessions {
            guard let web = display.addSession() else { return }
            web.navigationDelegate = self
            if let url = URL(string: "https://www.google.com") { web.load(URLRequest(url: url)) }
            updateSessionUI()
            showToast("Second session added. Click a page with the mouse to choose which one gets the keyboard.")
        } else {
            let alert = UIAlertController(title: "Close a session", message: "Which page do you want to close?", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Close left page", style: .destructive) { [weak self] _ in
                self?.closeSession(at: 0)
            })
            alert.addAction(UIAlertAction(title: "Close right page", style: .destructive) { [weak self] _ in
                self?.closeSession(at: 1)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                DispatchQueue.main.async { self?.focusCaptureIfNeeded() }
            })
            present(alert, animated: true)
        }
    }

    private func closeSession(at index: Int) {
        DisplayController.shared.closeSession(at: index)
        webView.navigationDelegate = self
        updateSessionUI()
        DispatchQueue.main.async { [weak self] in self?.focusCaptureIfNeeded() }
    }

    /// Keeps the split bar where the ratio says: that share of the touchpad's width.
    private func layoutSplitHandle() {
        guard let handle = splitHandle, let pad = trackpadView, pad.frame.width > 0 else { return }
        let ratio = DisplayController.shared.splitRatio
        let centerX = pad.frame.minX + pad.frame.width * ratio
        handle.frame = CGRect(x: centerX - 30, y: pad.frame.minY, width: 60, height: pad.frame.height)
    }

    // MARK: - Screenshot of the monitor

    @objc private func screenshotTapped() {
        guard isAirPlayModeActive, let image = DisplayController.shared.monitorSnapshot() else {
            showToast("Turn AirPlay on first: the screenshot is of the monitor.")
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(screenshotSaved(_:didFinishSavingWithError:contextInfo:)), nil)
        lastScreenshot = image
    }

    private var lastScreenshot: UIImage?

    @objc private func screenshotSaved(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if error == nil {
            showToast("Screenshot of the monitor saved to Photos")
            lastScreenshot = nil
            return
        }
        // Photos said no (for example the permission was refused). Offer the share sheet, which can save or send it.
        showToast("Could not save to Photos. Allow Photos for AirBrowser in Settings, or use the share sheet.")
        guard let picture = lastScreenshot else { return }
        let sheet = UIActivityViewController(activityItems: [picture], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = screenshotButton
        sheet.popoverPresentationController?.sourceRect = screenshotButton.bounds
        present(sheet, animated: true)
    }

    /// Puts the split bar back in the middle: both pages get half of the monitor.
    @objc private func resizeBackToMiddle() {
        DisplayController.shared.splitRatio = 0.5
        layoutSplitHandle()
    }

    @objc private func handleSplitPan(_ gesture: UIPanGestureRecognizer) {
        guard trackpadView.frame.width > 0 else { return }
        let x = gesture.location(in: trackpadContainer).x
        DisplayController.shared.splitRatio = (x - trackpadView.frame.minX) / trackpadView.frame.width
        layoutSplitHandle()
    }

    // MARK: - Web view placement

    private func placeWebViewOnIPad() {
        let webView = self.webView
        // Already in place with its layout rules intact: nothing to do.
        if webView.superview === view, !webViewConstraints.isEmpty, webViewConstraints.allSatisfy({ $0.isActive }) { return }

        NSLayoutConstraint.deactivate(webViewConstraints)
        if webView.superview !== view {
            webView.removeFromSuperview()
            view.insertSubview(webView, belowSubview: trackpadContainer)
        }
        webView.translatesAutoresizingMaskIntoConstraints = false

        webViewConstraints = [
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ]
        NSLayoutConstraint.activate(webViewConstraints)
    }
}


private extension NSLayoutConstraint {
    func withPriority(_ value: Float) -> NSLayoutConstraint {
        priority = UILayoutPriority(value)
        return self
    }
}
