import UIKit
import WebKit
import Combine
import GameController

extension Notification.Name {
    /// Posted whenever a monitor's external-display scene connects or disconnects.
    static let externalDisplayAvailabilityChanged = Notification.Name("AirBrowser.externalDisplayAvailabilityChanged")
}

// MARK: - Tunables (change these if a physical mouse feels off)
/// Pointer speed for a physical mouse / trackpad.
private let mouseSpeed: CGFloat = 2.0
/// Pixels scrolled per unit of wheel movement.
private let mouseScrollSpeed: CGFloat = 30.0
/// Every wheel event scrolls at least this many pixels, so slow wheel clicks are not lost.
private let mouseScrollMinStep: CGFloat = 6.0
/// ...and at most this many, so a fast spin does not fling the page.
private let mouseScrollMaxStep: CGFloat = 300.0
/// GCMouse reports "up" as positive. If the cursor moves vertically backwards, change -1.0 to 1.0.
private let mouseVerticalSign: CGFloat = -1.0
/// Windows-style: rolling the wheel toward you scrolls the page down.
/// For the macOS-style opposite, change -1.0 to 1.0.
private let mouseScrollSign: CGFloat = -1.0

/// Turns one raw wheel value into a number of pixels to scroll.
private func mouseScrollStep(_ value: Float) -> CGFloat {
    if value == 0 { return 0 }
    let size = min(max(abs(CGFloat(value)) * mouseScrollSpeed, mouseScrollMinStep), mouseScrollMaxStep)
    return (value < 0 ? -size : size) * mouseScrollSign
}

// MARK: - JavaScript helper injected into every page (types text / keys into whatever is focused)
private let keyBridgeScript = #"""
(function () {
  if (window.__ab) { return; }

  function deepActive() {
    var el = document.activeElement;
    while (el && el.tagName === 'IFRAME') {
      var inner = null;
      try { inner = el.contentDocument && el.contentDocument.activeElement; } catch (e) { inner = null; }
      if (!inner) { break; }
      el = inner;
    }
    return el || document.body;
  }

  function win(el) {
    return (el.ownerDocument && el.ownerDocument.defaultView) || window;
  }

  function isTextInput(el) {
    if (!el) { return false; }
    if (el.tagName === 'TEXTAREA') { return true; }
    if (el.tagName !== 'INPUT') { return false; }
    var t = (el.type || 'text').toLowerCase();
    return ['text', 'search', 'url', 'tel', 'email', 'password', 'number'].indexOf(t) !== -1;
  }

  function editable(el) {
    return isTextInput(el) || !!el.isContentEditable;
  }

  function fire(el, type, init) {
    var opts = Object.assign({ bubbles: true, cancelable: true, composed: true }, init || {});
    var ev = new (win(el).KeyboardEvent)(type, opts);
    if (opts.keyCode) {
      // keyCode/which are read-only on real events, and TV apps (YouTube TV) look at them.
      try {
        Object.defineProperty(ev, 'keyCode', { get: function () { return opts.keyCode; } });
        Object.defineProperty(ev, 'which', { get: function () { return opts.keyCode; } });
      } catch (e) {}
    }
    return el.dispatchEvent(ev);
  }

  function setValue(el, value) {
    var w = win(el);
    var proto = el.tagName === 'TEXTAREA' ? w.HTMLTextAreaElement.prototype : w.HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
  }

  function selection(el) {
    var n = el.value.length, s = n, e = n;
    try {
      if (el.selectionStart !== null) { s = el.selectionStart; e = el.selectionEnd; }
    } catch (x) {}
    return [s, e];
  }

  function caret(el, a, b) {
    try { el.setSelectionRange(a, b === undefined ? a : b); } catch (x) {}
  }

  function changed(el, inputType, data) {
    var opts = { bubbles: true, composed: true, inputType: inputType, data: data === undefined ? null : data };
    el.dispatchEvent(new (win(el).InputEvent)('input', opts));
  }

  function insert(el, text) {
    if (isTextInput(el)) {
      var r = selection(el), v = el.value;
      setValue(el, v.slice(0, r[0]) + text + v.slice(r[1]));
      caret(el, r[0] + text.length);
      changed(el, 'insertText', text);
    } else if (el.isContentEditable) {
      el.ownerDocument.execCommand('insertText', false, text);
    }
  }

  function remove(el, forward) {
    if (isTextInput(el)) {
      var r = selection(el), v = el.value, a = r[0], b = r[1];
      if (a === b) {
        if (forward) { if (b >= v.length) { return; } b += 1; }
        else { if (a <= 0) { return; } a -= 1; }
      }
      setValue(el, v.slice(0, a) + v.slice(b));
      caret(el, a);
      changed(el, forward ? 'deleteContentForward' : 'deleteContentBackward');
    } else if (el.isContentEditable) {
      el.ownerDocument.execCommand(forward ? 'forwardDelete' : 'delete');
    }
  }

  function focusNext(el) {
    var list = Array.prototype.filter.call(
      document.querySelectorAll('a[href], button, input, select, textarea, [tabindex]'),
      function (n) { return !n.disabled && n.tabIndex >= 0 && n.offsetParent !== null; }
    );
    if (!list.length) { return; }
    var i = list.indexOf(el);
    list[(i + 1) % list.length].focus();
  }

  window.__ab = {
    key: function (key, code, keyCode) {
      var el = deepActive();
      var init = { key: key, code: code, keyCode: keyCode, which: keyCode };
      if (fire(el, 'keydown', init)) {
        var page = window.innerHeight * 0.85;
        if (key === 'Enter') {
          if (el.tagName === 'TEXTAREA') {
            insert(el, '\n');
          } else if (el.tagName === 'INPUT' && el.form) {
            if (el.form.requestSubmit) { el.form.requestSubmit(); } else { el.form.submit(); }
          } else if (el.isContentEditable) {
            el.ownerDocument.execCommand('insertParagraph');
          } else if (el.tagName === 'A' || el.tagName === 'BUTTON') {
            el.click();
          }
        } else if (key === 'Backspace') {
          remove(el, false);
        } else if (key === 'Delete') {
          remove(el, true);
        } else if (key === 'Tab') {
          focusNext(el);
        } else if (isTextInput(el)) {
          var r = selection(el), n = el.value.length;
          if (key === 'ArrowLeft') { caret(el, r[0] !== r[1] ? r[0] : Math.max(0, r[0] - 1)); }
          else if (key === 'ArrowRight') { caret(el, r[0] !== r[1] ? r[1] : Math.min(n, r[1] + 1)); }
          else if (key === 'Home') { caret(el, 0); }
          else if (key === 'End') { caret(el, n); }
        } else if (!el.isContentEditable) {
          if (key === 'ArrowDown') { window.scrollBy(0, 60); }
          else if (key === 'ArrowUp') { window.scrollBy(0, -60); }
          else if (key === 'ArrowLeft') { window.scrollBy(-60, 0); }
          else if (key === 'ArrowRight') { window.scrollBy(60, 0); }
          else if (key === 'PageDown' || key === ' ') { window.scrollBy(0, page); }
          else if (key === 'PageUp') { window.scrollBy(0, -page); }
          else if (key === 'Home') { window.scrollTo(0, 0); }
          else if (key === 'End') { window.scrollTo(0, document.documentElement.scrollHeight); }
        }
      }
      fire(el, 'keyup', init);
    },

    text: function (t) {
      if (t === '\n' || t === '\r') { window.__ab.key('Enter', 'Enter', 13); return; }
      if (t === '\t') { window.__ab.key('Tab', 'Tab', 9); return; }
      var el = deepActive();
      if (editable(el)) {
        var single = t.length === 1;
        var init = { key: t };
        if (single && !fire(el, 'keydown', init)) { return; }
        insert(el, t);
        if (single) { fire(el, 'keyup', init); }
      } else if (t.length === 1) {
        var up = t.toUpperCase();
        var code = t === ' ' ? 'Space' : (/[a-z]/i.test(t) ? 'Key' + up : (/[0-9]/.test(t) ? 'Digit' + t : ''));
        window.__ab.key(t, code, up.charCodeAt(0));
      }
    },

    backspace: function () {
      window.__ab.key('Backspace', 'Backspace', 8);
    }
  };
})();
"""#

/// Owns the ONE shared web view and decides where it is shown:
///  - on the iPad (default), or
///  - fullscreen on the monitor (AirPlay mode ON).
///
/// The monitor is driven only by its UIWindowScene (handed over by SceneDelegate).
/// No legacy `UIWindow.screen` windows are created, so two windows can never fight over the web view.
final class DisplayController: ObservableObject {
    static let shared = DisplayController()

    let webView: WKWebView
    let cursorView: UIView
    var externalWindow: UIWindow?

    /// True while the monitor is showing the browser (AirPlay mode ON).
    @Published var isExternalConnected: Bool = false
    /// True while a monitor is plugged in and iPadOS has handed us a scene for it.
    @Published private(set) var isExternalDisplayAvailable: Bool = false
    @Published var cursorPosition: CGPoint = .zero

    private weak var externalScene: UIWindowScene?
    private var mouseObserver: NSObjectProtocol?
    private var urlObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?

    private init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        YouTubeAdBlocker.apply(to: config)

        // Lets the keyboard (iPad or hardware) type into the page that is shown on the monitor.
        config.userContentController.addUserScript(
            WKUserScript(source: keyBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        // Ad blocking for YouTube's TV interface (youtube.com/tv). Does nothing on other pages.
        config.userContentController.addUserScript(
            WKUserScript(source: YouTubeTV.adBlockScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let startsDesktop = DisplayController.loadPrefersDesktopSite()
        config.defaultWebpagePreferences.preferredContentMode = startsDesktop ? .desktop : .mobile

        let web = WKWebView(frame: .zero, configuration: config)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.allowsBackForwardNavigationGestures = true

        // iPad: desktop site (macOS Safari identity). iPhone: the normal mobile site.
        // "Request Desktop Site" in Settings changes this.
        web.customUserAgent = startsDesktop ? DisplayController.desktopUserAgent : nil

        self.webView = web
        self.cursorView = DisplayController.makeCursorView()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidDisconnect(_:)),
            name: UIScreen.didDisconnectNotification,
            object: nil
        )

        // History: watch the address and title instead of only page loads, so pages that change
        // without a full load (YouTube videos, for example) are recorded too.
        urlObservation = web.observe(\.url, options: [.new]) { webView, _ in
            HistoryStore.shared.record(url: webView.url, title: nil)
        }
        titleObservation = web.observe(\.title, options: [.new]) { webView, _ in
            HistoryStore.shared.record(url: webView.url, title: webView.title)
        }
    }

    // MARK: - Site identity (desktop / mobile / YouTube TV)

    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    private static let desktopSiteKey = "AirBrowser.desktopSite"

    /// Saved choice, or the default: iPad = desktop site, iPhone = mobile site.
    private static func loadPrefersDesktopSite() -> Bool {
        if let saved = UserDefaults.standard.object(forKey: desktopSiteKey) as? Bool {
            return saved
        }
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    var prefersDesktopSite: Bool {
        get { return DisplayController.loadPrefersDesktopSite() }
        set { UserDefaults.standard.set(newValue, forKey: DisplayController.desktopSiteKey) }
    }

    /// Picks the user agent and page layout for a navigation. Returns true if the web view's user agent
    /// had to change; the caller must then load the request again so the new one is actually sent.
    func prepareIdentity(for request: URLRequest, preferences: WKWebpagePreferences) -> Bool {
        let isTV = YouTubeTV.isTVAddress(request.url)
        let desktop = prefersDesktopSite

        let agent: String?
        if isTV {
            agent = YouTubeTV.currentProfile.userAgent
        } else {
            agent = desktop ? DisplayController.desktopUserAgent : nil
        }

        preferences.preferredContentMode = (isTV || desktop) ? .desktop : .mobile

        if webView.customUserAgent != agent {
            webView.customUserAgent = agent
            return true
        }
        return false
    }

    private static func makeCursorView() -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        view.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        view.layer.cornerRadius = 11
        view.layer.borderColor = UIColor.white.cgColor
        view.layer.borderWidth = 2.5
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowRadius = 4
        view.layer.shadowOpacity = 0.5
        view.isUserInteractionEnabled = false
        return view
    }

    // MARK: - Monitor scene bookkeeping (called from SceneDelegate)

    func externalSceneDidConnect(_ scene: UIWindowScene) {
        externalScene = scene
        isExternalDisplayAvailable = true
        NotificationCenter.default.post(name: .externalDisplayAvailabilityChanged, object: nil)
    }

    func externalSceneDidDisconnect(_ scene: UIWindowScene) {
        // Ignore a stale scene that disconnects after a newer one already took over (quick replug).
        if let current = externalScene, current !== scene { return }
        tearDownExternalScene()
    }

    @objc private func screenDidDisconnect(_ notification: Notification) {
        guard let screen = notification.object as? UIScreen,
              let scene = externalScene,
              scene.screen === screen else { return }
        tearDownExternalScene()
    }

    private func tearDownExternalScene() {
        stopExternalPresentation()
        externalScene = nil
        isExternalDisplayAvailable = false
        NotificationCenter.default.post(name: .externalDisplayAvailabilityChanged, object: nil)
    }

    // MARK: - Showing / hiding the browser on the monitor

    /// Moves the shared web view onto the monitor. Returns false if no monitor scene exists.
    @discardableResult
    func startExternalPresentation() -> Bool {
        if externalWindow != nil { return true }
        guard let scene = externalScene else { return false }

        // By default iPadOS shrinks the picture a little to dodge TV overscan, which leaves black borders
        // on all four sides. Turn that off so the page uses every pixel of the monitor.
        scene.screen.overscanCompensation = UIScreen.OverscanCompensation.none

        // The view controller pulls the web view and cursor out of the iPad UI and pins them fullscreen.
        let controller = ExternalBrowserViewController(webView: webView, cursorView: cursorView)
        controller.loadViewIfNeeded()

        // A window created from the scene gets the monitor's exact size.
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.isHidden = false // not makeKeyAndVisible: the iPad keeps keyboard focus

        externalWindow = window
        cursorPosition = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        cursorView.center = cursorPosition
        isExternalConnected = true

        startMouseCapture()
        return true
    }

    /// Takes the browser off the monitor. The caller puts the web view back on the iPad.
    /// With no window left on the monitor, iPadOS goes back to mirroring the iPad.
    func stopExternalPresentation() {
        guard let window = externalWindow else { return }

        stopMouseCapture()

        webView.removeFromSuperview()
        cursorView.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil

        externalScene?.screen.overscanCompensation = UIScreen.OverscanCompensation.scale

        externalWindow = nil
        isExternalConnected = false
    }

    // Kept so older call sites still compile; the monitor is now driven by its scene.
    func attachToExternalScreen(_ screen: UIScreen) {
        startExternalPresentation()
    }

    func detachExternalScreen() {
        stopExternalPresentation()
    }

    // MARK: - Cursor, click and scroll

    func moveCursor(deltaX: CGFloat, deltaY: CGFloat, speed: CGFloat = 1.5) {
        guard let window = externalWindow else { return }

        var newX = cursorPosition.x + (deltaX * speed)
        var newY = cursorPosition.y + (deltaY * speed)

        newX = max(0, min(window.bounds.width, newX))
        newY = max(0, min(window.bounds.height, newY))

        cursorPosition = CGPoint(x: newX, y: newY)
        cursorView.center = cursorPosition
    }

    /// button: 0 = left click, 2 = right click
    func performClickAtCursor(button: Int = 0) {
        guard isExternalConnected else { return }

        let js = """
        (function(x, y, button) {
            var el = document.elementFromPoint(x, y);
            if (!el) { return; }
            var opts = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: button };
            el.dispatchEvent(new MouseEvent('mousedown', opts));
            el.dispatchEvent(new MouseEvent('mouseup', opts));
            if (button === 2) {
                el.dispatchEvent(new MouseEvent('contextmenu', opts));
                return;
            }
            var field = el.closest('input, textarea, select, [contenteditable=""], [contenteditable="true"]');
            if (field) { field.focus(); }
            el.click();
        })(\(cursorPosition.x), \(cursorPosition.y), \(button));
        """
        webView.evaluateJavaScript(js)
    }

    /// Scrolls the scrollable thing under the cursor (inner scroller first, then the page).
    /// Positive deltaY scrolls the page down.
    func scroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard isExternalConnected, deltaX != 0 || deltaY != 0 else { return }

        let js = """
        (function(x, y, dx, dy) {
            var el = document.elementFromPoint(x, y);
            while (el && el !== document.body && el !== document.documentElement) {
                var s = getComputedStyle(el);
                var canY = dy !== 0 && /(auto|scroll|overlay)/.test(s.overflowY) && el.scrollHeight > el.clientHeight &&
                    ((dy > 0 && el.scrollTop + el.clientHeight < el.scrollHeight - 1) || (dy < 0 && el.scrollTop > 0));
                var canX = dx !== 0 && /(auto|scroll|overlay)/.test(s.overflowX) && el.scrollWidth > el.clientWidth &&
                    ((dx > 0 && el.scrollLeft + el.clientWidth < el.scrollWidth - 1) || (dx < 0 && el.scrollLeft > 0));
                if (canY || canX) { el.scrollBy(dx, dy); return; }
                el = el.parentElement;
            }
            window.scrollBy(dx, dy);
        })(\(cursorPosition.x), \(cursorPosition.y), \(deltaX), \(deltaY));
        """
        webView.evaluateJavaScript(js)
    }

    func performScroll(deltaY: CGFloat) {
        scroll(deltaX: 0, deltaY: deltaY * 2.5)
    }

    // MARK: - Keyboard -> page on the monitor

    func typeText(_ text: String) {
        callBridge("text(\(jsLiteral(text)))")
    }

    func pressBackspace() {
        callBridge("backspace()")
    }

    func pressKey(_ key: String, code: String, keyCode: Int) {
        callBridge("key(\(jsLiteral(key)), \(jsLiteral(code)), \(keyCode))")
    }

    private func callBridge(_ call: String) {
        webView.evaluateJavaScript("window.__ab && window.__ab.\(call);")
    }

    /// Turns any string into a safe JavaScript string literal (quotes included).
    private func jsLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string], options: []),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    // MARK: - Physical mouse / trackpad (only while AirPlay mode is ON)

    private func startMouseCapture() {
        for mouse in GCMouse.mice() { attachMouse(mouse) }
        guard mouseObserver == nil else { return }
        mouseObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let mouse = notification.object as? GCMouse { self?.attachMouse(mouse) }
        }
    }

    private func stopMouseCapture() {
        if let observer = mouseObserver {
            NotificationCenter.default.removeObserver(observer)
            mouseObserver = nil
        }
        for mouse in GCMouse.mice() { detachMouse(mouse) }
    }

    private func attachMouse(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }

        input.mouseMovedHandler = { [weak self] _, dx, dy in
            DispatchQueue.main.async {
                self?.moveCursor(deltaX: CGFloat(dx), deltaY: CGFloat(dy) * mouseVerticalSign, speed: mouseSpeed)
            }
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed {
                DispatchQueue.main.async { self?.performClickAtCursor() }
            }
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed {
                DispatchQueue.main.async { self?.performClickAtCursor(button: 2) }
            }
        }
        input.scroll.valueChangedHandler = { [weak self] _, vertical, horizontal in
            // iPadOS reports the VERTICAL wheel in the first value and the HORIZONTAL one in the second
            // (negative = wheel up / left, positive = wheel down / right).
            let deltaY = mouseScrollStep(vertical)
            let deltaX = mouseScrollStep(horizontal)
            DispatchQueue.main.async {
                self?.scroll(deltaX: deltaX, deltaY: deltaY)
            }
        }
    }

    private func detachMouse(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil
        input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil
        input.scroll.valueChangedHandler = nil
    }
}
