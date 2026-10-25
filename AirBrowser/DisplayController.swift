import UIKit
import WebKit
import Combine
import GameController

extension Notification.Name {
    /// Posted whenever a monitor's external-display scene connects or disconnects.
    static let externalDisplayAvailabilityChanged = Notification.Name("AirBrowser.externalDisplayAvailabilityChanged")
    /// Posted when the page left full screen and the web view may need putting back on the iPad.
    static let webViewNeedsPlacement = Notification.Name("AirBrowser.webViewNeedsPlacement")
    /// Posted when pages are added or closed, or when another page gets the focus.
    static let sessionsChanged = Notification.Name("AirBrowser.sessionsChanged")
}

// MARK: - Tunables (change these if a physical mouse feels off)
/// Seconds without moving before the cursor hides (when auto-hide is switched on).
private let cursorHideDelay: TimeInterval = 10
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

  // Delete the word before the caret (what holding Backspace does on a normal keyboard after a moment).
  function removeWord(el) {
    if (isTextInput(el)) {
      var r = selection(el), v = el.value, a = r[0], b = r[1];
      if (a === b) {
        var i = a;
        while (i > 0 && /\s/.test(v.charAt(i - 1))) { i--; }
        while (i > 0 && !/\s/.test(v.charAt(i - 1))) { i--; }
        a = i;
        if (a === b) { return; }
      }
      setValue(el, v.slice(0, a) + v.slice(b));
      caret(el, a);
      changed(el, 'deleteWordBackward');
    } else if (el.isContentEditable) {
      try { el.ownerDocument.execCommand('deleteWordBackward'); } catch (e) {}
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

  function post(type, text) {
    try { window.webkit.messageHandlers.airbrowser.postMessage({ type: type, text: text }); } catch (e) {}
  }

  function closeMenu() {
    var old = document.getElementById('__ab_menu');
    if (old) { old.remove(); }
  }

  // Small floating menu: used for right click and for the Copy bubble after highlighting text.
  function buildMenu(items, x, y) {
    closeMenu();
    var menu = document.createElement('div');
    menu.id = '__ab_menu';
    menu.style.cssText = 'position:fixed;z-index:2147483647;min-width:170px;padding:6px 0;border-radius:10px;' +
      'background:rgba(40,40,44,0.97);color:#fff;font:15px -apple-system,Helvetica,Arial,sans-serif;' +
      'box-shadow:0 8px 30px rgba(0,0,0,0.5);';

    function close() {
      menu.remove();
      document.removeEventListener('mousedown', outside, true);
      document.removeEventListener('keydown', onKey, true);
    }
    function outside(e) { if (!menu.contains(e.target)) { close(); } }
    function onKey(e) { if (e.key === 'Escape') { close(); } }

    items.forEach(function (item) {
      var row = document.createElement('div');
      row.textContent = item[0];
      row.style.cssText = 'padding:9px 18px;white-space:nowrap;';
      row.addEventListener('click', function (e) { e.stopPropagation(); close(); item[1](); });
      menu.appendChild(row);
    });

    (document.body || document.documentElement).appendChild(menu);
    var width = menu.offsetWidth, height = menu.offsetHeight;
    menu.style.left = Math.max(0, Math.min(x, window.innerWidth - width)) + 'px';
    menu.style.top = Math.max(0, Math.min(y, window.innerHeight - height)) + 'px';

    document.addEventListener('mousedown', outside, true);
    document.addEventListener('keydown', onKey, true);
  }

  // Highlight colour that also shows while the monitor window is not the "active" one.
  function ensureSelectionStyle() {
    if (document.getElementById('__ab_sel_style')) { return; }
    var style = document.createElement('style');
    style.id = '__ab_sel_style';
    style.textContent = '::selection { background: #3a7bff; color: #fff; }';
    (document.head || document.documentElement).appendChild(style);
  }

  function caretAt(x, y) {
    var range = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
    return range ? { node: range.startContainer, offset: range.startOffset } : null;
  }

  window.__ab = {
    // ---- text highlighting with a held press and a slide (like a mouse) ----
    selectStart: function (x, y) {
      closeMenu();
      ensureSelectionStyle();
      window.__abAnchor = null;
      window.__abDragField = null;
      var el = document.elementFromPoint(x, y);
      if (el && isTextInput(el)) {            // dragging inside a text box selects its whole text
        window.__abDragField = el;
        try { el.focus(); } catch (e) {}
        return;
      }
      window.__abAnchor = caretAt(x, y);
    },

    selectMove: function (x, y) {
      if (window.__abDragField) { return; }
      var anchor = window.__abAnchor;
      var here = caretAt(x, y);
      if (!anchor || !here) { return; }
      try {
        window.getSelection().setBaseAndExtent(anchor.node, anchor.offset, here.node, here.offset);
      } catch (e) {}
    },

    selectEnd: function (x, y) {
      if (window.__abDragField) {
        try { window.__abDragField.select(); } catch (e) {}
      }
      var text = window.__ab.selectedText();
      if (text) {
        buildMenu([
          ['Copy', function () { post('copy', text); }],
          ['Select All', function () { window.__ab.selectAll(); }]
        ], x, y + 18);
      }
    },

    selectedText: function () {
      var el = deepActive();
      if (isTextInput(el)) {
        var range = selection(el);
        if (range[0] !== range[1]) { return el.value.slice(range[0], range[1]); }
      }
      var text = '';
      try { text = String(window.getSelection()); } catch (e) {}
      return text;
    },

    selectAll: function () {
      var el = deepActive();
      if (isTextInput(el)) { try { el.select(); } catch (e) {} return; }
      try { document.execCommand('selectAll'); } catch (e) {}
    },

    contextMenu: function (x, y) {
      closeMenu();
      var el = document.elementFromPoint(x, y);
      if (!el) { return; }

      var ev = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 2 });
      if (!el.dispatchEvent(ev)) { return; } // the page showed its own menu (YouTube's player does)

      var link = el.closest ? el.closest('a[href]') : null;
      var image = el.closest ? el.closest('img') : null;
      var field = el.closest ? el.closest('input, textarea, [contenteditable=""], [contenteditable="true"]') : null;
      if (field) { try { field.focus(); } catch (e) {} }

      var selected = window.__ab.selectedText();
      var items = [];
      if (selected) { items.push(['Copy', function () { post('copy', selected); }]); }
      if (field) { items.push(['Paste', function () { post('paste', ''); }]); }
      items.push(['Select All', function () { window.__ab.selectAll(); }]);
      if (link) {
        items.push(['Open Link', function () { window.location.href = link.href; }]);
        items.push(['Copy Link', function () { post('copy', link.href); }]);
      }
      if (image && (image.currentSrc || image.src)) {
        var source = image.currentSrc || image.src;
        items.push(['Open Image', function () { window.location.href = source; }]);
        items.push(['Copy Image Address', function () { post('copy', source); }]);
      }
      items.push(['Back', function () { history.back(); }]);
      items.push(['Forward', function () { history.forward(); }]);
      items.push(['Reload', function () { location.reload(); }]);
      buildMenu(items, x, y);
    },

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
    },

    backspaceWord: function () {
      removeWord(deepActive());
    }
  };
})();
"""#

// MARK: - Full screen on the monitor
/// A page's own full-screen button (YouTube's) normally asks WebKit for a separate full-screen window. That window can
/// open on the iPad's screen instead of the monitor. While AirPlay mode is ON the web view already fills the whole
/// monitor, so full screen is done inside the page instead: the element is stretched over the entire page, and the page
/// is told (fullscreenchange, document.fullscreenElement...) exactly as if it were real full screen.
/// On the iPad (AirPlay OFF) the normal WebKit full screen is used.
private let fullscreenScript = #"""
(function () {
  if (window.__abFS) { return; }

  var ElementProto = Element.prototype;
  var DocProto = Document.prototype;
  var nativeRequest = ElementProto.requestFullscreen || ElementProto.webkitRequestFullscreen || ElementProto.webkitRequestFullScreen;
  var nativeExit = DocProto.exitFullscreen || DocProto.webkitExitFullscreen || DocProto.webkitCancelFullScreen;
  var external = false;
  var current = null;
  var styleTag = null;

  var FILL = 'position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;' +
    'width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;' +
    'margin:0!important;padding:0!important;background:#000!important;z-index:2147483647!important;transform:none!important;';

  function ensureStyle() {
    if (styleTag && styleTag.isConnected) { return; }
    styleTag = document.createElement('style');
    styleTag.textContent = '[data-ab-fullscreen]{' + FILL + '}';
    (document.head || document.documentElement).appendChild(styleTag);
  }

  function announce(el) {
    var target = (el && el.isConnected) ? el : document;
    target.dispatchEvent(new Event('fullscreenchange', { bubbles: true, composed: true }));
    target.dispatchEvent(new Event('webkitfullscreenchange', { bubbles: true, composed: true }));
    setTimeout(function () { window.dispatchEvent(new Event('resize')); }, 0);
  }

  function enter(el) {
    if (current === el) { return; }
    if (current) { current.removeAttribute('data-ab-fullscreen'); }
    ensureStyle();
    current = el;
    el.setAttribute('data-ab-fullscreen', '');
    announce(el);
  }

  function leave() {
    var el = current;
    if (!el) { return; }
    current = null;
    el.removeAttribute('data-ab-fullscreen');
    announce(el);
  }

  function request() {
    if (external) { enter(this); return Promise.resolve(); }
    if (nativeRequest) { return nativeRequest.apply(this, arguments); }
    return Promise.reject(new TypeError('Fullscreen is not available'));
  }

  function exit() {
    if (current) { leave(); return Promise.resolve(); }
    if (nativeExit) { return nativeExit.apply(document, arguments); }
    return Promise.resolve();
  }

  ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'].forEach(function (name) {
    try { Object.defineProperty(ElementProto, name, { value: request, configurable: true, writable: true }); } catch (e) {}
  });
  ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen'].forEach(function (name) {
    try { Object.defineProperty(DocProto, name, { value: exit, configurable: true, writable: true }); } catch (e) {}
  });

  function patchGetter(names, make) {
    names.forEach(function (name) {
      var original = null;
      try {
        var d = Object.getOwnPropertyDescriptor(DocProto, name);
        original = d && d.get;
      } catch (e) {}
      try {
        Object.defineProperty(DocProto, name, {
          configurable: true,
          get: function () { return make(original ? original.call(this) : undefined); }
        });
      } catch (e) {}
    });
  }
  patchGetter(['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'], function (v) {
    return current || (v === undefined ? null : v);
  });
  patchGetter(['fullscreenEnabled', 'webkitFullscreenEnabled'], function (v) {
    return external ? true : !!v;
  });
  patchGetter(['webkitIsFullScreen', 'fullscreen'], function (v) {
    return current ? true : !!v;
  });

  // Esc leaves full screen, like a real browser.
  document.addEventListener('keydown', function (e) {
    if (current && e.key === 'Escape') { leave(); }
  }, true);

  window.__abFS = {
    setExternal: function (on) {
      external = !!on;
      if (!external) { leave(); }
    },
    exit: function () { leave(); }
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

    /// Every open page ("session"). A second one can be added while AirPlay mode is ON.
    private(set) var sessions: [WKWebView]
    private(set) var focusedIndex = 0
    static let maxSessions = 2
    /// The page that has focus. It gets the keyboard, and the iPad's Back / Reload buttons.
    var webView: WKWebView { return sessions[min(max(focusedIndex, 0), sessions.count - 1)] }
    var sessionCount: Int { return sessions.count }
    /// Private browsing shares ONE in-memory store between its pages, so a login works in both.
    private var incognitoStore = WKWebsiteDataStore.nonPersistent()
    /// True while browsing privately: nothing is saved (no history, cookies or site data).
    private(set) var isIncognito = false
    private var incognitoZoomLevels: [String: CGFloat] = [:]
    let cursorView: UIView
    var externalWindow: UIWindow?

    /// True while the monitor is showing the browser (AirPlay mode ON).
    @Published var isExternalConnected: Bool = false
    /// True while a monitor is plugged in and iPadOS has handed us a scene for it.
    @Published private(set) var isExternalDisplayAvailable: Bool = false
    @Published var cursorPosition: CGPoint = .zero

    private weak var externalScene: UIWindowScene?
    private weak var externalController: ExternalBrowserViewController?
    /// The user agent we last gave the web view (reading it back from the web view is not reliable).
    private var appliedAgents: [ObjectIdentifier: String?] = [:]
    private var lastCursorActivity = Date()
    private var cursorWatchTimer: Timer?
    /// False while another app is focused (Split View / Stage Manager). Keyboard keys are then read here.
    var mainWindowIsKey = true
    /// True while the iPad pointer could not be locked (Split View, Slide Over, or the window is not focused).
    /// The pointer then keeps moving on the iPad and stops at the screen edge, so the monitor cursor follows
    /// WHERE the mouse points inside the AirBrowser window instead of how far it moved.
    var usesAbsolutePointer = false
    private var shiftHeld = false
    /// Press-and-slide (highlighting). A press that never moves is a click.
    private var pointerIsDown = false
    private var pointerDragged = false
    private var pointerDownPosition: CGPoint = .zero
    /// Last TV address we reloaded from scratch (stops a reload loop).
    private var lastFreshTV: (from: String, time: Date)?
    private var mouseObserver: NSObjectProtocol?
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    private init() {
        let startingAgent = DisplayController.standardAgent(desktop: DisplayController.loadPrefersDesktopSite())

        let firstWeb = DisplayController.buildWebView(incognito: false, store: nil)
        self.sessions = [firstWeb]
        self.cursorView = DisplayController.makeCursorView()
        self.appliedAgents[ObjectIdentifier(firstWeb)] = .some(startingAgent)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidDisconnect(_:)),
            name: UIScreen.didDisconnectNotification,
            object: nil
        )

        attachObservers(to: firstWeb)
    }

    /// Builds the web view the whole app shares. A private (incognito) one keeps nothing on the device.
    private static func buildWebView(incognito: Bool, store: WKWebsiteDataStore?) -> WKWebView {
        let config = WKWebViewConfiguration()
        if incognito {
            // A store that lives only in memory: cookies, logins and site data vanish with the web view.
            config.websiteDataStore = store ?? WKWebsiteDataStore.nonPersistent()
        }
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Lets a page's own full-screen button work (youtube.com, videos). A web view blocks this unless it is switched on.
        config.preferences.isElementFullscreenEnabled = true

        YouTubeAdBlocker.apply(to: config)

        // Lets the keyboard (iPad or hardware) type into the page that is shown on the monitor.
        config.userContentController.addUserScript(
            WKUserScript(source: keyBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        // Full screen that works on the monitor (see fullscreenScript).
        config.userContentController.addUserScript(
            WKUserScript(source: fullscreenScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        // Ad blocking for YouTube's TV interface (youtube.com/tv). Does nothing on other pages.
        config.userContentController.addUserScript(
            WKUserScript(source: YouTubeTV.adBlockScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        // Keeps youtube.com/tv full-screen and still, and applies the chosen TV quality.
        config.userContentController.addUserScript(
            WKUserScript(source: YouTubeTV.layoutScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        // Makes the solid black / gray boxes of the TV interface see-through (can be switched off in Settings).
        config.userContentController.addUserScript(
            WKUserScript(source: YouTubeTV.transparencyScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        // Records what the TV player does so a report can be copied from Settings.
        config.userContentController.addUserScript(
            WKUserScript(source: YouTubeTV.diagnosticsScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        // Lets the right-click menu in the page ask the iPad to copy text.
        config.userContentController.add(PageMessageHandler(), name: "airbrowser")

        // Location questions are answered on the iPad's screen (see PermissionBridge), never on the monitor.
        config.userContentController.addUserScript(
            WKUserScript(source: PermissionBridge.geolocationScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        config.userContentController.addScriptMessageHandler(PermissionBridge.shared, contentWorld: .page, name: "airbrowserGeo")

        let startsDesktop = DisplayController.loadPrefersDesktopSite()
        config.defaultWebpagePreferences.preferredContentMode = startsDesktop ? .desktop : .mobile

        let web = WKWebView(frame: .zero, configuration: config)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.allowsBackForwardNavigationGestures = true
        // Camera / microphone questions and JavaScript alerts also go to the iPad's screen.
        web.uiDelegate = PermissionBridge.shared
        // The page must fill the whole view, with no extra space reserved for safe areas.
        web.scrollView.contentInsetAdjustmentBehavior = .never

        // iPad: desktop site (macOS Safari identity). iPhone: the normal mobile site.
        web.customUserAgent = DisplayController.standardAgent(desktop: startsDesktop)
        return web
    }

    // History: watch the address and title instead of only page loads, so pages that change
    // without a full load (YouTube videos, for example) are recorded too. Not while incognito.
    private func attachObservers(to web: WKWebView) {
        let fullscreen = web.observe(\.fullscreenState, options: [.new]) { [weak self] changed, _ in
            self?.webViewFullscreenChanged(changed)
        }
        let address = web.observe(\.url, options: [.new]) { [weak self] changed, _ in
            if self?.isIncognito == true { return }
            HistoryStore.shared.record(url: changed.url, title: nil)
        }
        let name = web.observe(\.title, options: [.new]) { [weak self] changed, _ in
            if self?.isIncognito == true { return }
            HistoryStore.shared.record(url: changed.url, title: changed.title)
        }
        observations[ObjectIdentifier(web)] = [fullscreen, address, name]
    }

    private func retire(_ web: WKWebView) {
        observations[ObjectIdentifier(web)] = nil
        appliedAgents[ObjectIdentifier(web)] = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
    }

    // MARK: - AirPlay mode comes back after leaving the app and returning

    /// True when AirPlay mode was ON when the app was left (Home, or another app took focus). It is switched back on
    /// when AirBrowser is opened again. This lives in memory only: closing the app and launching it again starts with
    /// AirPlay OFF.
    var airPlayWanted = false

    // MARK: - Full screen mode

    /// Tells every page whether to do full screen itself (monitor) or use WebKit's (iPad). Call after the monitor
    /// is switched on or off, and again whenever a new page starts (see MainAppViewController.didCommit).
    func syncFullscreenMode() {
        let call = "window.__abFS && window.__abFS.setExternal(\(isExternalConnected ? "true" : "false"));"
        for web in sessions { web.evaluateJavaScript(call) }
    }

    // MARK: - Leaving full screen

    /// When a page leaves full screen WebKit puts the web view back where it was. If that lost the layout (so the page
    /// would be the wrong size), set it up again.
    private func webViewFullscreenChanged(_ web: WKWebView) {
        guard web.fullscreenState == .notInFullscreen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            if self.isExternalConnected {
                self.externalController?.refreshLayout()
            } else {
                NotificationCenter.default.post(name: .webViewNeedsPlacement, object: nil)
            }
        }
    }

    // MARK: - Pages (sessions)

    /// Share of the monitor's width given to the first page (0.2 ... 0.8) while two pages are open.
    var splitRatio: CGFloat = 0.5 {
        didSet {
            let clamped = min(max(splitRatio, 0.2), 0.8)
            if clamped != splitRatio { splitRatio = clamped }
            externalController?.splitRatio = clamped
        }
    }

    private func postSessionsChanged() {
        NotificationCenter.default.post(name: .sessionsChanged, object: nil)
    }

    func index(of web: WKWebView) -> Int? {
        return sessions.firstIndex(where: { $0 === web })
    }

    /// Makes one page the focused one: the keyboard types into it, and the iPad's buttons act on it.
    func focusSession(_ index: Int) {
        guard sessions.indices.contains(index), index != focusedIndex else { return }
        focusedIndex = index
        postSessionsChanged()
    }

    /// Opens a second page next to the first. The caller sets its navigation delegate and loads an address.
    @discardableResult
    func addSession() -> WKWebView? {
        guard sessions.count < DisplayController.maxSessions else { return nil }
        let web = DisplayController.buildWebView(incognito: isIncognito, store: isIncognito ? incognitoStore : nil)
        appliedAgents[ObjectIdentifier(web)] = .some(DisplayController.standardAgent(desktop: prefersDesktopSite))
        attachObservers(to: web)
        sessions.append(web)
        focusedIndex = sessions.count - 1
        externalController?.setWebViews(sessions)
        syncFullscreenMode()
        postSessionsChanged()
        return web
    }

    /// Closes one page. The other one takes the whole monitor.
    func closeSession(at index: Int) {
        guard sessions.count > 1, sessions.indices.contains(index) else { return }
        pointerIsDown = false
        pointerDragged = false
        let old = sessions.remove(at: index)
        retire(old)
        focusedIndex = 0
        externalController?.setWebViews(sessions)
        postSessionsChanged()
    }

    // MARK: - Incognito

    /// Switches between normal and private browsing by swapping in a brand new web view.
    /// The caller puts the new web view on screen and loads a page. Any second page is closed.
    func setIncognito(_ on: Bool) {
        guard on != isIncognito else { return }
        stopExternalPresentation()

        let oldSessions = sessions
        let oldStore = incognitoStore
        let wasPrivate = isIncognito
        isIncognito = on
        incognitoZoomLevels.removeAll()
        if on { incognitoStore = WKWebsiteDataStore.nonPersistent() }

        let fresh = DisplayController.buildWebView(incognito: on, store: on ? incognitoStore : nil)
        sessions = [fresh]
        focusedIndex = 0
        appliedAgents[ObjectIdentifier(fresh)] = .some(DisplayController.standardAgent(desktop: prefersDesktopSite))
        attachObservers(to: fresh)

        for old in oldSessions { retire(old) }
        if wasPrivate {
            // Leaving incognito: erase everything the private session collected.
            oldStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: Date(timeIntervalSince1970: 0)
            ) {}
        }
        postSessionsChanged()
    }

    // MARK: - Page size (zoom), remembered per website

    private static let siteZoomKey = "AirBrowser.siteZoom"
    static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// On this iPad, WebKit's page zoom works backwards: a bigger number made pages smaller. So the number given
    /// to WebKit is flipped (1.25 is handed over as 0.8). If sizes ever go the wrong way again, change this to false.
    private static let invertPageZoom = true

    /// What to hand to WebKit for a size the user chose.
    private static func webKitZoom(for chosen: CGFloat) -> CGFloat {
        return invertPageZoom ? (1.0 / chosen) : chosen
    }

    var currentZoomHost: String? { return webView.url?.host?.lowercased() }

    func zoomLevel(for host: String?) -> CGFloat {
        guard let host = host else { return 1.0 }
        if isIncognito { return incognitoZoomLevels[host] ?? 1.0 }
        let saved = UserDefaults.standard.dictionary(forKey: DisplayController.siteZoomKey) as? [String: Double]
        return CGFloat(saved?[host] ?? 1.0)
    }

    var currentZoom: CGFloat { return zoomLevel(for: currentZoomHost) }

    private func setZoom(_ value: CGFloat) {
        guard let host = currentZoomHost else { return }
        if isIncognito {
            incognitoZoomLevels[host] = value
        } else {
            var all = (UserDefaults.standard.dictionary(forKey: DisplayController.siteZoomKey) as? [String: Double]) ?? [:]
            if abs(value - 1.0) < 0.001 {
                all.removeValue(forKey: host)
            } else {
                all[host] = Double(value)
            }
            UserDefaults.standard.set(all, forKey: DisplayController.siteZoomKey)
        }
        let wanted = DisplayController.webKitZoom(for: value)
        for web in sessions where web.url?.host?.lowercased() == host { web.pageZoom = wanted }
    }

    func zoomIn() {
        let now = currentZoom
        if let next = DisplayController.zoomSteps.first(where: { $0 > now + 0.001 }) { setZoom(next) }
    }

    func zoomOut() {
        let now = currentZoom
        if let previous = DisplayController.zoomSteps.last(where: { $0 < now - 0.001 }) { setZoom(previous) }
    }

    func resetZoom() {
        setZoom(1.0)
    }

    /// Call when a page starts showing: applies the size saved for that website.
    func applyZoomForCurrentPage(for web: WKWebView) {
        let wanted = DisplayController.webKitZoom(for: zoomLevel(for: web.url?.host?.lowercased()))
        if abs(web.pageZoom - wanted) > 0.001 { web.pageZoom = wanted }
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

    private var lastSiteModeRewrite: (from: String, time: Date)?

    /// Makes an address match the chosen mode (desktop or phone). Returns nil when nothing should change.
    ///
    /// YouTube decides between its desktop and phone site with a cookie, not only the user agent, so a
    /// cookie that got stuck on the phone site keeps you there whatever the mode says. Adding
    /// app=desktop (or app=m) with persist_app=1 to the address sets that cookie to match the mode.
    /// Some other sites keep a separate phone address (m.facebook.com...), which is swapped in desktop mode.
    func siteModeAddress(for url: URL?) -> URL? {
        guard let url = url,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased() else { return nil }

        let desktop = prefersDesktopSite
        var changed = false

        if (host == "www.youtube.com" || host == "youtube.com" || host == "m.youtube.com")
            && !YouTubeTV.isTVAddress(url) {
            let wanted = desktop ? "desktop" : "m"
            var items = parts.queryItems ?? []
            let current = items.first(where: { $0.name == "app" })?.value
            if current != wanted {
                items.removeAll { $0.name == "app" || $0.name == "persist_app" }
                items.append(URLQueryItem(name: "app", value: wanted))
                items.append(URLQueryItem(name: "persist_app", value: "1"))
                parts.queryItems = items
                changed = true
            }
            if desktop && host == "m.youtube.com" {
                parts.host = "www.youtube.com"
                changed = true
            }
        } else if desktop {
            var replacement: String?
            switch host {
            case "m.facebook.com", "mbasic.facebook.com":
                replacement = "www.facebook.com"
            case "mobile.twitter.com":
                replacement = "twitter.com"
            default:
                if host.hasSuffix(".m.wikipedia.org") {
                    replacement = host.replacingOccurrences(of: ".m.wikipedia.org", with: ".wikipedia.org")
                }
            }
            if let newHost = replacement {
                parts.host = newHost
                changed = true
            }
        }

        guard changed else { return nil }

        // Never loop: if the site sent us straight back to this address, leave it alone.
        if let last = lastSiteModeRewrite,
           last.from == url.absoluteString,
           Date().timeIntervalSince(last.time) < 10 {
            return nil
        }

        guard let result = parts.url else { return nil }
        lastSiteModeRewrite = (from: url.absoluteString, time: Date())
        return result
    }

    /// YouTube TV's page remembers the device it was first loaded as. A cached copy from an earlier visit
    /// (for example with another identity) made it start as the wrong device until you reloaded.
    /// Returns a "ignore the cache" copy of the request when entering YouTube TV, otherwise nil.
    /// Moving around inside the TV app only changes the part after "#", which is never reloaded.
    func freshTVRequest(for request: URLRequest, current: URL?) -> URLRequest? {
        guard let url = request.url, YouTubeTV.isTVAddress(url) else { return nil }
        if request.cachePolicy == .reloadIgnoringLocalCacheData { return nil }

        func withoutFragment(_ address: URL?) -> String? {
            guard let address = address, var parts = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            return parts.url?.absoluteString
        }
        if YouTubeTV.isTVAddress(current), withoutFragment(current) == withoutFragment(url) { return nil }

        if let last = lastFreshTV, last.from == url.absoluteString, Date().timeIntervalSince(last.time) < 5 { return nil }
        lastFreshTV = (from: url.absoluteString, time: Date())

        var fresh = request
        fresh.cachePolicy = .reloadIgnoringLocalCacheData
        return fresh
    }

    static let iPhoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    /// The identity for normal (non-TV) pages. On an iPhone the built-in mobile identity is already right;
    /// an iPad has to pretend to be an iPhone to be given the phone version of a site.
    private static func standardAgent(desktop: Bool) -> String? {
        if desktop { return desktopUserAgent }
        return UIDevice.current.userInterfaceIdiom == .pad ? iPhoneUserAgent : nil
    }

    /// Picks the user agent and page layout for a navigation. Returns true if the web view's user agent
    /// had to change; the caller must then load the request again so the new one is actually sent.
    func prepareIdentity(for request: URLRequest, preferences: WKWebpagePreferences, webView web: WKWebView) -> Bool {
        let isTV = YouTubeTV.isTVAddress(request.url)
        let desktop = prefersDesktopSite

        let agent: String?
        if isTV {
            agent = YouTubeTV.currentProfile.userAgent
        } else {
            agent = DisplayController.standardAgent(desktop: desktop)
        }

        preferences.preferredContentMode = (isTV || desktop) ? .desktop : .mobile

        // Compare with what we set ourselves. Once it matches, the request goes through,
        // so this can never turn into an endless reload loop.
        let known: String? = appliedAgents[ObjectIdentifier(web)] ?? nil
        if known != agent {
            appliedAgents[ObjectIdentifier(web)] = .some(agent)
            web.customUserAgent = agent
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

        // The monitor may be running at a low resolution (YouTube then only offers low video quality).
        // Switch it to the best mode it supports before any window is attached to it.
        if let best = DisplayController.bestMode(for: scene.screen), scene.screen.currentMode != best {
            scene.screen.currentMode = best
        }

        // The view controller pulls the web view and cursor out of the iPad UI and pins them fullscreen.
        let controller = ExternalBrowserViewController(webViews: sessions, cursorView: cursorView, ratio: splitRatio)
        controller.loadViewIfNeeded()
        externalController = controller

        // A window created from the scene gets the monitor's exact size.
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.isHidden = false // not makeKeyAndVisible: the iPad keeps keyboard focus

        externalWindow = window
        cursorPosition = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        cursorView.center = cursorPosition
        isExternalConnected = true

        startMouseCapture()
        startCursorWatch()
        startKeyboardForwarding()
        nudgeLayout()
        syncFullscreenMode()

        // Short notice so it is obvious what the monitor is running at.
        let size = scene.screen.currentMode?.size ?? window.bounds.size
        NotificationCenter.default.post(
            name: DownloadManager.message,
            object: nil,
            userInfo: ["text": "Monitor: \(Int(size.width)) x \(Int(size.height))"]
        )
        return true
    }

    /// The sharpest mode the monitor offers that keeps its own shape (so there are no black bars), up to 4K.
    private static func bestMode(for screen: UIScreen) -> UIScreenMode? {
        let modes = screen.availableModes
        guard !modes.isEmpty else { return nil }

        var candidates = modes
        if let preferred = screen.preferredMode, preferred.size.height > 0 {
            let shape = preferred.size.width / preferred.size.height
            let sameShape = modes.filter { mode in
                mode.size.height > 0 && abs(mode.size.width / mode.size.height - shape) < 0.02
            }
            if !sameShape.isEmpty { candidates = sameShape }
        }

        let upTo4K = candidates.filter { $0.size.width <= 3840 }
        let pool = upTo4K.isEmpty ? candidates : upTo4K
        return pool.max { first, second in
            first.size.width * first.size.height < second.size.width * second.size.height
        }
    }

    /// The page changes size when it moves between the iPad and the monitor. Some pages (YouTube TV)
    /// only re-measure when told, so announce the new size a few times.
    private func nudgeLayout() {
        for delay in [0.2, 0.8, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                for web in self?.sessions ?? [] {
                    web.evaluateJavaScript("window.dispatchEvent(new Event('resize'));")
                }
            }
        }
    }

    /// Takes the browser off the monitor. The caller puts the web view back on the iPad.
    /// With no window left on the monitor, iPadOS goes back to mirroring the iPad.
    func stopExternalPresentation() {
        guard let window = externalWindow else { return }

        stopMouseCapture()
        stopCursorWatch()
        stopKeyboardForwarding()

        for web in sessions { web.removeFromSuperview() }
        cursorView.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil

        externalScene?.screen.overscanCompensation = UIScreen.OverscanCompensation.scale

        externalWindow = nil
        externalController = nil
        isExternalConnected = false
        usesAbsolutePointer = false
        nudgeLayout()
        syncFullscreenMode()
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
        cursorActivity()

        if pointerIsDown { pointerDragUpdate() }
    }

    /// Puts the monitor cursor where the mouse points inside the AirBrowser window, as a fraction (0...1) of the
    /// window. Used when the iPad pointer cannot be locked. There is no "ceiling": the top of the window is the top
    /// of the monitor.
    func placeCursor(fractionX: CGFloat, fractionY: CGFloat) {
        guard let window = externalWindow else { return }

        let x = max(0, min(1, fractionX)) * window.bounds.width
        let y = max(0, min(1, fractionY)) * window.bounds.height
        cursorPosition = CGPoint(x: x, y: y)
        cursorView.center = cursorPosition
        cursorActivity()

        if pointerIsDown { pointerDragUpdate() }
    }

    // MARK: - Keyboard while another app is focused (Split View / Stage Manager)

    private static let letterForKey: [GCKeyCode: String] = [
        .keyA: "a",
        .keyB: "b",
        .keyC: "c",
        .keyD: "d",
        .keyE: "e",
        .keyF: "f",
        .keyG: "g",
        .keyH: "h",
        .keyI: "i",
        .keyJ: "j",
        .keyK: "k",
        .keyL: "l",
        .keyM: "m",
        .keyN: "n",
        .keyO: "o",
        .keyP: "p",
        .keyQ: "q",
        .keyR: "r",
        .keyS: "s",
        .keyT: "t",
        .keyU: "u",
        .keyV: "v",
        .keyW: "w",
        .keyX: "x",
        .keyY: "y",
        .keyZ: "z"
    ]

    private static let digitForKey: [GCKeyCode: String] = [
        .one: "1",
        .two: "2",
        .three: "3",
        .four: "4",
        .five: "5",
        .six: "6",
        .seven: "7",
        .eight: "8",
        .nine: "9",
        .zero: "0"
    ]

    /// Hardware keys go to the focused app only. When AirBrowser is in the background (another app has focus),
    /// its own key handling does not run, so the keyboard is read here and typed into the page on the monitor.
    /// While AirBrowser is focused this does nothing, so a key is never typed twice.
    private func startKeyboardForwarding() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            DispatchQueue.main.async {
                self?.forwardHardwareKey(keyCode, pressed: pressed)
            }
        }
    }

    private func stopKeyboardForwarding() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        shiftHeld = false
    }

    private func forwardHardwareKey(_ keyCode: GCKeyCode, pressed: Bool) {
        if keyCode == .leftShift || keyCode == .rightShift {
            shiftHeld = pressed
            return
        }
        guard isExternalConnected, !mainWindowIsKey, pressed else { return }

        if let letter = DisplayController.letterForKey[keyCode] {
            typeText(shiftHeld ? letter.uppercased() : letter)
        } else if let digit = DisplayController.digitForKey[keyCode] {
            typeText(digit)
        } else if keyCode == .spacebar {
            typeText(" ")
        } else if keyCode == .returnOrEnter {
            pressKey("Enter", code: "Enter", keyCode: 13)
        } else if keyCode == .deleteOrBackspace {
            pressBackspace()
        } else if keyCode == .tab {
            pressKey("Tab", code: "Tab", keyCode: 9)
        } else if keyCode == .escape {
            pressKey("Escape", code: "Escape", keyCode: 27)
        } else if keyCode == .upArrow {
            pressKey("ArrowUp", code: "ArrowUp", keyCode: 38)
        } else if keyCode == .downArrow {
            pressKey("ArrowDown", code: "ArrowDown", keyCode: 40)
        } else if keyCode == .leftArrow {
            pressKey("ArrowLeft", code: "ArrowLeft", keyCode: 37)
        } else if keyCode == .rightArrow {
            pressKey("ArrowRight", code: "ArrowRight", keyCode: 39)
        }
    }

    // MARK: - Hide the cursor when it has not moved for a while

    private static let autoHideKey = "AirBrowser.autoHideCursor"

    /// When on, the cursor on the monitor fades away after 10 seconds without moving, and comes back on any
    /// movement or click. When off, it always stays visible. Saved between launches.
    var autoHideCursor: Bool {
        get { return UserDefaults.standard.bool(forKey: DisplayController.autoHideKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: DisplayController.autoHideKey)
            cursorActivity()
        }
    }

    /// Call whenever the cursor moves or clicks: shows it and restarts the countdown.
    func cursorActivity() {
        lastCursorActivity = Date()
        if cursorView.alpha < 1 { cursorView.alpha = 1 }
    }

    private func startCursorWatch() {
        cursorWatchTimer?.invalidate()
        lastCursorActivity = Date()
        cursorView.alpha = 1
        cursorWatchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let idle = Date().timeIntervalSince(self.lastCursorActivity)
            if self.autoHideCursor && idle >= cursorHideDelay {
                if self.cursorView.alpha > 0 {
                    UIView.animate(withDuration: 0.3) { self.cursorView.alpha = 0 }
                }
            } else if self.cursorView.alpha < 1 {
                self.cursorView.alpha = 1
            }
        }
    }

    private func stopCursorWatch() {
        cursorWatchTimer?.invalidate()
        cursorWatchTimer = nil
        cursorView.alpha = 1
    }

    // MARK: - Which page is under the cursor

    /// The page under a point on the monitor (the nearest one, if the point is on the black line between two pages),
    /// and where that point is inside the page.
    private func target(at point: CGPoint) -> (index: Int, web: WKWebView, local: CGPoint)? {
        guard !sessions.isEmpty else { return nil }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, web) in sessions.enumerated() {
            let frame = web.frame
            if frame.width <= 0 || frame.height <= 0 { continue }
            let distance = max(frame.minX - point.x, 0, point.x - frame.maxX)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        let web = sessions[best]
        return (best, web, local(point, in: web))
    }

    private func local(_ point: CGPoint, in web: WKWebView) -> CGPoint {
        return CGPoint(x: point.x - web.frame.origin.x, y: point.y - web.frame.origin.y)
    }

    // MARK: - Press and slide to highlight text

    /// The page the current press started on (a press and slide stays inside that page).
    private weak var pressedWeb: WKWebView?

    /// The button went down (mouse button, the Left Click button, or a press-and-hold on the touchpad).
    func pointerDown() {
        guard isExternalConnected, !pointerIsDown, let hit = target(at: cursorPosition) else { return }
        focusSession(hit.index)
        pressedWeb = hit.web
        pointerIsDown = true
        pointerDragged = false
        pointerDownPosition = cursorPosition
    }

    private func pointerDragUpdate() {
        guard let web = pressedWeb else { return }
        let moved = hypot(cursorPosition.x - pointerDownPosition.x, cursorPosition.y - pointerDownPosition.y)
        if !pointerDragged {
            if moved < 6 { return } // a little wobble is still a click
            pointerDragged = true
            let start = local(pointerDownPosition, in: web)
            web.evaluateJavaScript("window.__ab && window.__ab.selectStart(\(start.x), \(start.y));")
        }
        let now = local(cursorPosition, in: web)
        web.evaluateJavaScript("window.__ab && window.__ab.selectMove(\(now.x), \(now.y));")
    }

    /// The button came up: finish the highlight, or, if nothing was dragged, click.
    func pointerUp() {
        guard pointerIsDown else { return }
        pointerIsDown = false
        if pointerDragged {
            pointerDragged = false
            if let web = pressedWeb {
                let end = local(cursorPosition, in: web)
                web.evaluateJavaScript("window.__ab && window.__ab.selectEnd(\(end.x), \(end.y));")
            }
        } else {
            performClickAtCursor()
        }
        pressedWeb = nil
    }

    // MARK: - Copy / select all (also used by Cmd+C and Cmd+A on a keyboard)

    func copySelection() {
        webView.evaluateJavaScript("window.__ab ? window.__ab.selectedText() : ''") { result, _ in
            if let text = result as? String, !text.isEmpty {
                UIPasteboard.general.string = text
                NotificationCenter.default.post(name: DownloadManager.message, object: nil, userInfo: ["text": "Copied"])
            }
        }
    }

    func selectAllInPage() {
        webView.evaluateJavaScript("window.__ab && window.__ab.selectAll();")
    }

    /// button: 0 = left click, 2 = right click. The page under the cursor gets the click and the keyboard focus.
    func performClickAtCursor(button: Int = 0) {
        guard isExternalConnected, let hit = target(at: cursorPosition) else { return }
        cursorActivity()
        focusSession(hit.index)

        if button == 2 {
            hit.web.evaluateJavaScript("window.__ab && window.__ab.contextMenu(\(hit.local.x), \(hit.local.y));")
            return
        }

        let js = """
        (function(x, y, button) {
            var el = document.elementFromPoint(x, y);
            if (!el) { return; }
            var inMenu = el.closest ? el.closest('#__ab_menu') : null;
            if (!inMenu) { try { window.getSelection().removeAllRanges(); } catch (e) {} }
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
        })(\(hit.local.x), \(hit.local.y), \(button));
        """
        hit.web.evaluateJavaScript(js)
    }

    /// Scrolls the scrollable thing under the cursor (inner scroller first, then the page).
    /// Positive deltaY scrolls the page down.
    func scroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard isExternalConnected, deltaX != 0 || deltaY != 0, let hit = target(at: cursorPosition) else { return }
        // The TV page is not meant to scroll; moving it is what exposed black bars.
        if YouTubeTV.isTVAddress(hit.web.url) { return }

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
        })(\(hit.local.x), \(hit.local.y), \(deltaX), \(deltaY));
        """
        hit.web.evaluateJavaScript(js)
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

    func pressBackspaceWord() {
        callBridge("backspaceWord()")
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
                // When the iPad pointer is not locked, its position drives the cursor instead (see placeCursor).
                guard let self = self, !self.usesAbsolutePointer else { return }
                self.moveCursor(deltaX: CGFloat(dx), deltaY: CGFloat(dy) * mouseVerticalSign, speed: mouseSpeed)
            }
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            DispatchQueue.main.async {
                if pressed { self?.pointerDown() } else { self?.pointerUp() }
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
        pointerIsDown = false
        pointerDragged = false
    }
}

/// Receives messages from the page (for example "Copy Link" in the right-click menu).
final class PageMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        if type == "copy", let text = body["text"] as? String, !text.isEmpty {
            UIPasteboard.general.string = text
            NotificationCenter.default.post(name: DownloadManager.message, object: nil, userInfo: ["text": "Copied"])
        } else if type == "paste" {
            if let text = UIPasteboard.general.string, !text.isEmpty {
                DisplayController.shared.typeText(text)
            }
        }
    }
}
