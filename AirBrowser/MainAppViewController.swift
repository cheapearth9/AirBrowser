override func viewDidLoad() {
    super.viewDidLoad()
    
    // Listen for HDMI / AirPlay connection
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(screenDidConnect),
        name: UIScreen.didConnectNotification,
        object: nil
    )
    
    // Check if monitor is ALREADY plugged in when app launches
    if UIScreen.screens.count > 1 {
        setupExternalScreen(UIScreen.screens[1])
    }
}

@objc func screenDidConnect(notification: Notification) {
    guard let externalScreen = notification.object as? UIScreen else { return }
    setupExternalScreen(externalScreen)
}

func setupExternalScreen(_ screen: UIScreen) {
    let externalWindow = UIWindow(frame: screen.bounds)
    externalWindow.screen = screen
    externalWindow.rootViewController = DisplayController()
    externalWindow.isHidden = false
    // Store reference so it stays alive
    self.externalWindow = externalWindow
}
