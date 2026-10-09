import UIKit
import Combine

class MainAppViewController: UIViewController, UITextFieldDelegate {

    private let urlBar = UITextField()
    private let trackpadView = UIView()
    private let keyboardTriggerButton = UIButton(type: .system)
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupGestureRecognizers()
        bindDisplayState()

        if let url = URL(string: "https://www.youtube.com") {
            DisplayController.shared.webView.load(URLRequest(url: url))
        }
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground

        urlBar.borderStyle = .roundedRect
        urlBar.placeholder = "Enter URL or Search YouTube..."
        urlBar.autocapitalizationType = .none
        urlBar.autocorrectionType = .no
        urlBar.keyboardType = .URL
        urlBar.returnKeyType = .go
        urlBar.delegate = self
        urlBar.translatesAutoresizingMaskIntoConstraints = false

        trackpadView.backgroundColor = .secondarySystemBackground
        trackpadView.layer.cornerRadius = 16
        trackpadView.layer.borderWidth = 1
        trackpadView.layer.borderColor = UIColor.separator.cgColor
        trackpadView.translatesAutoresizingMaskIntoConstraints = false

        keyboardTriggerButton.setTitle("Show Keyboard", for: .normal)
        keyboardTriggerButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        keyboardTriggerButton.addTarget(self, action: #selector(toggleKeyboard), for: .touchUpInside)
        keyboardTriggerButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(urlBar)
        view.addSubview(trackpadView)
        view.addSubview(keyboardTriggerButton)

        NSLayoutConstraint.activate([
            urlBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            urlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            urlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            trackpadView.topAnchor.constraint(equalTo: urlBar.bottomAnchor, constant: 16),
            trackpadView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            trackpadView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            trackpadView.bottomAnchor.constraint(equalTo: keyboardTriggerButton.topAnchor, constant: -12),

            keyboardTriggerButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            keyboardTriggerButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    private func bindDisplayState() {
        DisplayController.shared.$isExternalConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.updateLayoutForDisplayMode(isExternalConnected: isConnected)
            }
            .store(in: &cancellables)
    }

    private func updateLayoutForDisplayMode(isExternalConnected: Bool) {
        if isExternalConnected {
            DisplayController.shared.webView.removeFromSuperview()
            trackpadView.isHidden = false
            keyboardTriggerButton.isHidden = false
        } else {
            trackpadView.isHidden = true
            keyboardTriggerButton.isHidden = true
            
            let webView = DisplayController.shared.webView
            webView.frame = .zero
            webView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(webView)

            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: urlBar.bottomAnchor, constant: 12),
                webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
    }

    private func setupGestureRecognizers() {
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        trackpadView.addGestureRecognizer(panGesture)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        trackpadView.addGestureRecognizer(tapGesture)

        let scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollGesture.minimumNumberOfTouches = 2
        scrollGesture.maximumNumberOfTouches = 2
        trackpadView.addGestureRecognizer(scrollGesture)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: trackpadView)
        DisplayController.shared.moveCursor(deltaX: translation.x, deltaY: translation.y)
        gesture.setTranslation(.zero, in: trackpadView)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        DisplayController.shared.performClickAtCursor()
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: trackpadView)
        DisplayController.shared.performScroll(deltaY: -translation.y)
        gesture.setTranslation(.zero, in: trackpadView)
    }

    @objc private func toggleKeyboard() {
        if urlBar.isFirstResponder {
            urlBar.resignFirstResponder()
        } else {
            urlBar.becomeFirstResponder()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        guard let text = textField.text, !text.isEmpty else { return true }
        
        var urlString = text
        if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
            urlString = "https://" + urlString
        }

        if let url = URL(string: urlString) {
            DisplayController.shared.webView.load(URLRequest(url: url))
        }
        return true
    }
}
