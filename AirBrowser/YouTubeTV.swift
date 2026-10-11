import Foundation

/// Support for YouTube's TV interface at youtube.com/tv ("Leanback").
/// YouTube only serves it to smart TVs and game consoles and sends everything else back to the normal
/// site, so on that address the browser pretends to be a TV. Everywhere else it behaves as usual.
enum YouTubeTV {

    struct Profile {
        let name: String
        let userAgent: String
    }

    /// Different TVs YouTube may accept. If one stops working, Settings can switch to the next.
    static let profiles: [Profile] = [
        Profile(
            name: "Samsung TV",
            userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/537.36 (KHTML, like Gecko) 76.0.3809.146/6.0 TV Safari/537.36"
        ),
        Profile(
            name: "Xbox Series X",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Xbox; Xbox Series X) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.0.0"
        ),
        Profile(
            name: "Samsung TV (older)",
            userAgent: "Mozilla/5.0 (Linux; Tizen 2.3; SmartHub; SMART-TV; SmartTV; U; Maple2012) AppleWebKit/538.1+ (KHTML, like Gecko) TV Safari/538.1+"
        )
    ]

    private static let profileKey = "AirBrowser.youtubeTVProfile"

    static var profileIndex: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: profileKey)
            return min(max(saved, 0), profiles.count - 1)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: profileKey)
        }
    }

    static var currentProfile: Profile {
        return profiles[profileIndex]
    }

    static func nextProfile() {
        profileIndex = (profileIndex + 1) % profiles.count
    }

    /// True for youtube.com/tv (including youtube.com/tv#/watch?v=...).
    static func isTVAddress(_ url: URL?) -> Bool {
        guard let url = url, let host = url.host?.lowercased() else { return false }
        guard host == "youtube.com" || host == "www.youtube.com" else { return false }
        let path = url.path.lowercased()
        return path == "/tv" || path.hasPrefix("/tv/")
    }

    /// Removes ads from the data YouTube's TV app receives, before the app reads it.
    /// Runs only on youtube.com/tv; every other page ignores it.
    static let adBlockScript = #"""
(function () {
  if (location.hostname.indexOf('youtube.com') === -1) { return; }
  if (location.pathname !== '/tv' && location.pathname.indexOf('/tv/') !== 0) { return; }
  if (window.__abTVAdBlock) { return; }
  window.__abTVAdBlock = true;

  function strip(obj) {
    if (!obj || typeof obj !== 'object') { return; }
    if (obj.adPlacements !== undefined) { obj.adPlacements = []; }
    if (obj.playerAds !== undefined) { obj.playerAds = false; }
    if (obj.adSlots !== undefined) { obj.adSlots = []; }
    if (obj.adBreakHeartbeatParams !== undefined) { delete obj.adBreakHeartbeatParams; }
  }

  function clean(value) {
    try {
      if (Array.isArray(value)) {
        for (var i = 0; i < value.length; i++) {
          if (value[i]) { strip(value[i]); strip(value[i].playerResponse); }
        }
      } else if (value && typeof value === 'object') {
        strip(value);
        strip(value.playerResponse);
      }
    } catch (e) {}
    return value;
  }

  var originalParse = JSON.parse;
  JSON.parse = function () {
    return clean(originalParse.apply(this, arguments));
  };

  if (window.Response && Response.prototype.json) {
    var originalJson = Response.prototype.json;
    Response.prototype.json = function () {
      return originalJson.apply(this, arguments).then(clean);
    };
  }
})();
"""#
}
