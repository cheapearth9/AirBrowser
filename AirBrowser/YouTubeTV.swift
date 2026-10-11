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
            name: "Xbox Series X",
            userAgent: "Mozilla/5.0 (Windows NT 10.0; Xbox; Xbox Series X) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.0.0"
        ),
        Profile(
            name: "Samsung TV",
            userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/537.36 (KHTML, like Gecko) 76.0.3809.146/6.0 TV Safari/537.36"
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

    // MARK: Quality (1080p / 1440p / 4K)

    struct Quality {
        let name: String
        /// Pretend display height in pixels. 0 = Auto (change nothing).
        let height: Int
    }

    static let qualities: [Quality] = [
        Quality(name: "Auto", height: 0),
        Quality(name: "1080p", height: 1080),
        Quality(name: "1440p", height: 1440),
        Quality(name: "4K", height: 2160)
    ]

    private static let qualityKey = "AirBrowser.youtubeTVQuality"

    /// Name of the setting the page reads (stored in the page's own localStorage).
    static let pageQualityKey = "__ab_tv_res"

    static var qualityIndex: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: qualityKey)
            return min(max(saved, 0), qualities.count - 1)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: qualityKey)
        }
    }

    static var currentQuality: Quality {
        return qualities[qualityIndex]
    }

    static func nextQuality() {
        qualityIndex = (qualityIndex + 1) % qualities.count
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

    /// Makes the TV page fill the screen and stay put, and (if chosen in Settings) makes it report a
    /// bigger display so YouTube offers higher video quality. Runs only on youtube.com/tv.
    static let layoutScript = #"""
(function () {
  if (location.hostname.indexOf('youtube.com') === -1) { return; }
  if (location.pathname !== '/tv' && location.pathname.indexOf('/tv/') !== 0) { return; }
  if (window.__abTVLayout) { return; }
  window.__abTVLayout = true;

  // 0. YouTube's TV app has feature switches. On TVs it thinks are weak it turns on a flat "lightweight"
  //    look (solid boxes instead of see-through ones) and lower video quality. Force the full-featured set.
  var forcedFlags = {
    enableAnimations: true,
    enableListAnimations: true,
    enableRoundedProgressBar: true,
    enableLiveChat: true,
    isLimitedMemory: false,
    enableLightweightTimely: false
  };

  function lockFlags(switches) {
    Object.keys(forcedFlags).forEach(function (name) {
      try {
        Object.defineProperty(switches, name, {
          get: function () { return forcedFlags[name]; },
          set: function () {},
          configurable: true,
          enumerable: true
        });
      } catch (e) {}
    });
  }

  function patchConfig(config) {
    if (!config || typeof config !== 'object') { return config; }
    var current = config.featureSwitches;
    if (!current || typeof current !== 'object') { current = {}; }
    lockFlags(current);
    try {
      Object.defineProperty(config, 'featureSwitches', {
        get: function () { return current; },
        set: function (value) {
          current = (value && typeof value === 'object') ? value : {};
          lockFlags(current);
        },
        configurable: true,
        enumerable: true
      });
    } catch (e) {}
    return config;
  }

  // The page creates window.tectonicConfig itself, so watch for it being assigned and patch it then.
  var holder = patchConfig(window.tectonicConfig || {});
  try {
    Object.defineProperty(window, 'tectonicConfig', {
      get: function () { return holder; },
      set: function (value) { holder = patchConfig(value); },
      configurable: true,
      enumerable: true
    });
  } catch (e) {}

  // 1. The page must never scroll: scrolling slid the picture and showed black bars.
  var style = document.createElement('style');
  style.textContent = 'html, body { margin: 0 !important; padding: 0 !important; width: 100% !important; ' +
    'height: 100% !important; overflow: hidden !important; overscroll-behavior: none !important; ' +
    'background: #000 !important; }';
  (document.head || document.documentElement).appendChild(style);

  // 2. Report a bigger display when 1080p / 1440p / 4K is chosen in Settings.
  var target = 0;
  try { target = parseInt(localStorage.getItem('__ab_tv_res') || '0', 10) || 0; } catch (e) {}
  if (target > 0) {
    var viewHeight = window.innerHeight || 1080;
    var ratio = target / viewHeight;
    var wide = Math.round(target * 16 / 9);
    try {
      Object.defineProperty(window, 'devicePixelRatio', { get: function () { return ratio; }, configurable: true });
    } catch (e) {}
    ['width', 'availWidth'].forEach(function (name) {
      try { Object.defineProperty(window.screen, name, { get: function () { return wide; }, configurable: true }); } catch (e) {}
    });
    ['height', 'availHeight'].forEach(function (name) {
      try { Object.defineProperty(window.screen, name, { get: function () { return target; }, configurable: true }); } catch (e) {}
    });
  }
})();
"""#
}
