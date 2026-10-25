import UIKit
import WebKit
import CoreLocation

/// Handles every question a website can ask (location, camera / microphone, JavaScript alert / confirm / prompt)
/// and shows it on the IPAD, never on the monitor.
///
/// A question that WebKit shows by itself opens on the screen the page is on. While AirPlay mode is ON that is the
/// monitor, where nothing can be tapped. So:
///  - location is answered here (the page's `navigator.geolocation` is replaced by `geolocationScript`),
///  - camera / microphone and JavaScript dialogs come through the web view's UI delegate,
/// and all of them are shown as a normal alert on the iPad's own screen.
final class PermissionBridge: NSObject, WKUIDelegate, WKScriptMessageHandlerWithReply, CLLocationManagerDelegate {
    static let shared = PermissionBridge()

    /// The iPad's main view controller. Alerts are shown on top of it.
    weak var presenter: UIViewController?
    /// Called after any alert is closed (so the iPad can take keyboard focus back).
    var onDialogFinished: (() -> Void)?

    // MARK: - Showing alerts on the iPad (one at a time)

    private var jobs: [() -> Void] = []
    private var busy = false

    private func topPresenter() -> UIViewController? {
        guard var top = presenter, top.viewIfLoaded?.window != nil else { return nil }
        while let next = top.presentedViewController { top = next }
        return top
    }

    /// buttons: (title, style, what to do). The text typed into the field (if there is one) is passed along.
    /// `onUnavailable` runs instead if the iPad has nothing to show the alert on, so a page is never left waiting.
    private func show(
        title: String,
        message: String?,
        textDefault: String? = nil,
        buttons: [(String, UIAlertAction.Style, (String?) -> Void)],
        onUnavailable: @escaping () -> Void
    ) {
        jobs.append { [weak self] in
            guard let self = self else { return }
            guard let top = self.topPresenter() else {
                onUnavailable()
                self.finishedDialog()
                return
            }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            if let text = textDefault {
                alert.addTextField { field in field.text = text }
            }
            for button in buttons {
                let handler = button.2
                alert.addAction(UIAlertAction(title: button.0, style: button.1) { [weak self, weak alert] _ in
                    handler(alert?.textFields?.first?.text)
                    self?.finishedDialog()
                })
            }
            top.present(alert, animated: true)
        }
        pump()
    }

    private func pump() {
        guard !busy, !jobs.isEmpty else { return }
        busy = true
        let job = jobs.removeFirst()
        job()
    }

    private func finishedDialog() {
        busy = false
        onDialogFinished?()
        DispatchQueue.main.async { [weak self] in self?.pump() }
    }

    private func siteName(_ host: String?) -> String {
        if let host = host, !host.isEmpty { return host }
        return "This page"
    }

    // MARK: - JavaScript alert / confirm / prompt (WKUIDelegate)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        show(
            title: siteName(frame.securityOrigin.host),
            message: message,
            buttons: [("OK", .default, { _ in completionHandler() })],
            onUnavailable: { completionHandler() }
        )
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        show(
            title: siteName(frame.securityOrigin.host),
            message: message,
            buttons: [
                ("Cancel", .cancel, { _ in completionHandler(false) }),
                ("OK", .default, { _ in completionHandler(true) })
            ],
            onUnavailable: { completionHandler(false) }
        )
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        show(
            title: siteName(frame.securityOrigin.host),
            message: prompt,
            textDefault: defaultText ?? "",
            buttons: [
                ("Cancel", .cancel, { _ in completionHandler(nil) }),
                ("OK", .default, { text in completionHandler(text ?? "") })
            ],
            onUnavailable: { completionHandler(nil) }
        )
    }

    // MARK: - Camera / microphone (WKUIDelegate)

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let what: String
        switch type {
        case .camera: what = "your camera"
        case .microphone: what = "your microphone"
        default: what = "your camera and microphone"
        }
        show(
            title: "Allow " + siteName(origin.host) + " to use " + what + "?",
            message: "This question is shown on the iPad so you can answer it while the page is on the monitor.",
            buttons: [
                ("Don't Allow", .cancel, { _ in decisionHandler(.deny) }),
                ("Allow", .default, { _ in decisionHandler(.grant) })
            ],
            onUnavailable: { decisionHandler(.deny) }
        )
    }

    // MARK: - Location

    /// Replaces `navigator.geolocation` in every page and frame. The page's request goes to `userContentController`
    /// below (a reply is sent back to the page), so WebKit's own question - which would open on the monitor - never happens.
    static let geolocationScript = #"""
(function () {
  if (window.__abGeo) { return; }
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.airbrowserGeo;
  if (!handler) { return; }
  window.__abGeo = true;

  function makeError(r) {
    return {
      code: (r && r.code) || 2,
      message: (r && r.message) || 'Position unavailable',
      PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3
    };
  }

  function orNull(value) { return (value === undefined || value === null) ? null : value; }

  function makePosition(r) {
    return {
      coords: {
        latitude: r.lat, longitude: r.lon, accuracy: r.acc,
        altitude: orNull(r.alt), altitudeAccuracy: orNull(r.altAcc),
        heading: orNull(r.heading), speed: orNull(r.speed)
      },
      timestamp: r.ts
    };
  }

  function ask(success, failure) {
    var reply;
    try { reply = handler.postMessage({}); } catch (e) { reply = null; }
    if (!reply || !reply.then) { if (failure) { failure(makeError(null)); } return; }
    reply.then(function (r) {
      if (r && r.ok) { if (success) { success(makePosition(r)); } }
      else if (failure) { failure(makeError(r)); }
    }, function () {
      if (failure) { failure(makeError(null)); }
    });
  }

  var watches = {};
  var counter = 0;

  var geo = {
    getCurrentPosition: function (success, failure) { ask(success, failure); },
    watchPosition: function (success, failure) {
      counter += 1;
      var id = counter;
      watches[id] = true;
      function tick() {
        if (!watches[id]) { return; }
        ask(function (p) {
          if (!watches[id]) { return; }
          if (success) { success(p); }
          setTimeout(tick, 10000);
        }, function (e) {
          if (failure) { failure(e); }
          if (watches[id] && e.code !== 1) { setTimeout(tick, 15000); }
        });
      }
      tick();
      return id;
    },
    clearWatch: function (id) { delete watches[id]; }
  };

  try {
    Object.defineProperty(Navigator.prototype, 'geolocation', { get: function () { return geo; }, configurable: true });
  } catch (e) {
    try { Object.defineProperty(navigator, 'geolocation', { get: function () { return geo; }, configurable: true }); } catch (e2) {}
  }
})();
"""#

    /// Sites already answered during this run (so a page asking again is not asked again).
    private var allowedHosts = Set<String>()
    private var deniedHosts: [String: Date] = [:]

    private static func failure(code: Int, text: String) -> [String: Any] {
        return ["ok": false, "code": code, "message": text]
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let host = message.webView?.url?.host ?? message.frameInfo.securityOrigin.host
        askLocationPermission(host: host) { [weak self] allowed in
            guard allowed, let self = self else {
                replyHandler(PermissionBridge.failure(code: 1, text: "User denied Geolocation"), nil)
                return
            }
            self.locate { result in replyHandler(result, nil) }
        }
    }

    private func askLocationPermission(host: String, completion: @escaping (Bool) -> Void) {
        if allowedHosts.contains(host) { completion(true); return }
        if let when = deniedHosts[host], Date().timeIntervalSince(when) < 120 { completion(false); return }

        show(
            title: "Allow " + siteName(host) + " to use your location?",
            message: "This question is shown on the iPad so you can answer it while the page is on the monitor.",
            buttons: [
                ("Don't Allow", .cancel, { [weak self] _ in
                    self?.deniedHosts[host] = Date()
                    completion(false)
                }),
                ("Allow", .default, { [weak self] _ in
                    self?.allowedHosts.insert(host)
                    completion(true)
                })
            ],
            onUnavailable: { completion(false) }
        )
    }

    // The device's own location, asked for only after the person said yes above.
    private lazy var manager: CLLocationManager = {
        let created = CLLocationManager()
        created.delegate = self
        created.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return created
    }()
    private var waiters: [(id: Int, done: ([String: Any]) -> Void)] = []
    private var nextWaiterID = 0

    private func locate(_ done: @escaping ([String: Any]) -> Void) {
        nextWaiterID += 1
        let id = nextWaiterID
        waiters.append((id: id, done: done))

        // Never leave a page waiting forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.finish(id, PermissionBridge.failure(code: 3, text: "Timed out"))
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finishAll(PermissionBridge.failure(code: 1, text: "Location is turned off for this app"))
        default:
            manager.requestLocation()
        }
    }

    private func finish(_ id: Int, _ result: [String: Any]) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.done(result)
    }

    private func finishAll(_ result: [String: Any]) {
        let all = waiters
        waiters.removeAll()
        for waiter in all { waiter.done(result) }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !waiters.isEmpty else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finishAll(PermissionBridge.failure(code: 1, text: "Location is turned off for this app"))
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        var result: [String: Any] = [
            "ok": true,
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
            "acc": location.horizontalAccuracy,
            "ts": location.timestamp.timeIntervalSince1970 * 1000
        ]
        if location.verticalAccuracy >= 0 {
            result["alt"] = location.altitude
            result["altAcc"] = location.verticalAccuracy
        }
        if location.course >= 0 { result["heading"] = location.course }
        if location.speed >= 0 { result["speed"] = location.speed }
        finishAll(result)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        finishAll(PermissionBridge.failure(code: denied ? 1 : 2, text: error.localizedDescription))
    }
}
