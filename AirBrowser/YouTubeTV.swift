import Foundation

/// Support for YouTube's TV interface at youtube.com/tv ("Leanback").
/// YouTube only serves it to smart TVs and game consoles and sends everything else back to the normal
/// site, so on that address the browser pretends to be a TV. Everywhere else it behaves as usual.
enum YouTubeTV {

    struct Profile {
        let name: String
        let userAgent: String
    }

    /// The only identity: the PlayStation 4 one that a known "YouTube for TV 4K" browser extension uses
    /// to get 4K in the TV interface. (Xbox and Samsung TV identities were removed: they misbehaved.)
    static let profiles: [Profile] = [
        Profile(
            name: "PlayStation 4 (4K)",
            userAgent: "Mozilla/5.0 (PS4; Leanback Shell) Gecko/20100101 Firefox/65.0 LeanbackShell/01.00.01.75 Sony PS4/ (PS4, , no, CH)"
        )
    ]

    /// New key (".v3"): a saved old choice (or a restored backup) can no longer leave you on another device.
    private static let profileKey = "AirBrowser.youtubeTVProfile.v3"

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

    // MARK: Quality (Auto / 1080p / 1440p / 4K)

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

    /// Names of the settings the page reads (stored in the page's own localStorage).
    static let pageQualityKey = "__ab_tv_res"
    static let pageAdBlockKey = "__ab_tv_adblock"

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

    // MARK: Ad blocking on/off

    private static let adBlockKey = "AirBrowser.youtubeTVAdBlock"

    static var adBlockEnabled: Bool {
        get { return (UserDefaults.standard.object(forKey: adBlockKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: adBlockKey) }
    }

    // MARK: Transparency fix and auto-retry on/off

    static let pageClearKey = "__ab_tv_clear"
    static let pageRetryKey = "__ab_tv_retry"
    private static let clearBoxesKey = "AirBrowser.youtubeTVClearBoxes"
    private static let autoRetryKey = "AirBrowser.youtubeTVAutoRetry"

    /// Turns the solid black / gray boxes of the TV interface see-through.
    static var transparencyFixEnabled: Bool {
        get { return (UserDefaults.standard.object(forKey: clearBoxesKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: clearBoxesKey) }
    }

    /// Presses "Try again" by itself when the TV app shows "Something went wrong". Off by default.
    static var autoRetryEnabled: Bool {
        get { return (UserDefaults.standard.object(forKey: autoRetryKey) as? Bool) ?? false }
        set { UserDefaults.standard.set(newValue, forKey: autoRetryKey) }
    }

    /// True for youtube.com/tv (including youtube.com/tv#/watch?v=...).
    static func isTVAddress(_ url: URL?) -> Bool {
        guard let url = url, let host = url.host?.lowercased() else { return false }
        guard host == "youtube.com" || host == "www.youtube.com" else { return false }
        let path = url.path.lowercased()
        return path == "/tv" || path.hasPrefix("/tv/")
    }

    // MARK: Page scripts (all of them run only on youtube.com/tv)

    /// Removes ads from the data YouTube's TV app receives, before the app reads it.
    static let adBlockScript = #"""
(function () {
  if (location.hostname.indexOf('youtube.com') === -1) { return; }
  if (location.pathname !== '/tv' && location.pathname.indexOf('/tv/') !== 0) { return; }
  try { if (localStorage.getItem('__ab_tv_adblock') === '0') { return; } } catch (e) {}
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

    /// Makes the TV page fill the screen and stay put, forces its full-featured mode, chooses which video
    /// formats it may use, and (if chosen in Settings) makes it report a bigger display.
    static let layoutScript = #"""
(function () {
  if (location.hostname.indexOf('youtube.com') === -1) { return; }
  if (location.pathname !== '/tv' && location.pathname.indexOf('/tv/') !== 0) { return; }
  if (window.__abTVLayout) { return; }
  window.__abTVLayout = true;

  // Safari does not report device memory, so apps may assume a weak device and switch to a plain look.
  try {
    if (navigator.deviceMemory === undefined) {
      Object.defineProperty(Navigator.prototype, 'deviceMemory', { get: function () { return 8; }, configurable: true });
    }
  } catch (e) {}

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

  // 3. Video formats. Videos that played fine for a minute and then died ("Something went wrong") were
  //    most likely switching to a format this device cannot really decode. AV1 is never offered.
  //    VP9 (needed for 1440p and 4K) is only offered when 1440p or 4K was chosen; otherwise H.264 only.
  var allowVP9 = target >= 1440;

  function blocked(type) {
    var text = String(type || '').toLowerCase();
    if (text.indexOf('av01') !== -1) { return true; }
    if (!allowVP9 && (text.indexOf('vp9') !== -1 || text.indexOf('vp09') !== -1)) { return true; }
    return false;
  }

  try {
    if (window.MediaSource && MediaSource.isTypeSupported) {
      var realSupported = MediaSource.isTypeSupported.bind(MediaSource);
      window.__abRealIsTypeSupported = realSupported;
      MediaSource.isTypeSupported = function (type) { return blocked(type) ? false : realSupported(type); };
    }
  } catch (e) {}

  try {
    if (window.ManagedMediaSource && ManagedMediaSource.isTypeSupported) {
      var realManaged = ManagedMediaSource.isTypeSupported.bind(ManagedMediaSource);
      ManagedMediaSource.isTypeSupported = function (type) { return blocked(type) ? false : realManaged(type); };
    }
  } catch (e) {}

  try {
    var mediaProto = HTMLMediaElement.prototype;
    var realCanPlay = mediaProto.canPlayType;
    mediaProto.canPlayType = function (type) { return blocked(type) ? '' : realCanPlay.call(this, type); };
  } catch (e) {}

  try {
    if (navigator.mediaCapabilities && navigator.mediaCapabilities.decodingInfo) {
      var realDecoding = navigator.mediaCapabilities.decodingInfo.bind(navigator.mediaCapabilities);
      navigator.mediaCapabilities.decodingInfo = function (config) {
        var type = config && config.video && config.video.contentType;
        if (type && blocked(type)) {
          return Promise.resolve({ supported: false, smooth: false, powerEfficient: false });
        }
        return realDecoding(config);
      };
    }
  } catch (e) {}
})();
"""#

    /// Makes the video player's overlay look like the real YouTube TV: no solid black box behind the title and
    /// times, no black panel behind the related videos (a soft fade instead), and softer gray buttons.
    ///
    /// It only works while a video is playing full-size, so the home page keeps its normal dark look. Small
    /// badges sitting on thumbnails (the duration, "4K") keep their boxes, and side panels (comments, quality)
    /// are never touched. A box is fixed the instant it appears or its look changes, so nothing flashes.
    /// It can be switched off in the YouTube TV options.
    static let transparencyScript = #"""
(function () {
  if (location.hostname.indexOf('youtube.com') === -1) { return; }
  if (location.pathname !== '/tv' && location.pathname.indexOf('/tv/') !== 0) { return; }
  try { if (localStorage.getItem('__ab_tv_clear') === '0') { return; } } catch (e) {}
  if (window.__abTVClear) { return; }
  window.__abTVClear = true;

  var style = document.createElement('style');
  style.textContent =
    '[data-ab-clear="black"] { background-color: transparent !important; ' +
      'text-shadow: 0 0 8px rgba(0,0,0,1), 0 0 3px rgba(0,0,0,1), 0 1px 3px rgba(0,0,0,1) !important; }' +
    '[data-ab-clear="panel"] { background: linear-gradient(to bottom, rgba(0,0,0,0) 0%, ' +
      'rgba(0,0,0,0.6) 40%, rgba(0,0,0,0.88) 100%) !important; }' +
    '[data-ab-clear="gray"] { background-color: rgba(40,40,40,0.3) !important; }';
  (document.head || document.documentElement).appendChild(style);

  var playerOn = false;

  // The player is "on" while a video fills most of the screen.
  function evaluatePlayer() {
    var video = document.querySelector('video');
    if (!video) { playerOn = false; return; }
    var r = video.getBoundingClientRect();
    playerOn = r.width > window.innerWidth * 0.6 && r.height > window.innerHeight * 0.5;
  }

  function parseColor(text) {
    var match = /rgba?\(([^)]+)\)/.exec(text || '');
    if (!match) { return null; }
    var parts = match[1].split(',').map(parseFloat);
    return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
  }

  // The colour an element is heading for (not the half-way colour of a running fade).
  function finalBackground(el) {
    var value = getComputedStyle(el).backgroundColor;
    try {
      var animations = el.getAnimations ? el.getAnimations() : [];
      for (var i = 0; i < animations.length; i++) {
        var animation = animations[i];
        if (animation.transitionProperty === 'background-color' && animation.effect && animation.effect.getKeyframes) {
          var frames = animation.effect.getKeyframes();
          var last = frames[frames.length - 1];
          if (last && last.backgroundColor) { value = last.backgroundColor; }
        }
      }
    } catch (e) {}
    return value;
  }

  // A small label that sits on top of a much bigger picture is a thumbnail badge (duration...): keep it.
  function overlapsThumbnail(el, box) {
    var parent = el.parentElement;
    for (var depth = 0; parent && depth < 3; depth++, parent = parent.parentElement) {
      var pictures = parent.querySelectorAll('img, [style*="background-image"]');
      for (var i = 0; i < pictures.length && i < 8; i++) {
        var r = pictures[i].getBoundingClientRect();
        if (r.width * r.height < box.width * box.height * 6) { continue; }
        var across = Math.min(box.right, r.right) - Math.max(box.left, r.left);
        var down = Math.min(box.bottom, r.bottom) - Math.max(box.top, r.top);
        if (across > 0 && down > 0 && across * down >= box.width * box.height * 0.8) { return true; }
      }
    }
    return false;
  }

  // Side panels (comments, quality, ...) are left exactly as the app draws them.
  function insideSidePanel(el) {
    var vw = window.innerWidth, vh = window.innerHeight;
    var node = el;
    for (var depth = 0; node && depth < 10; depth++, node = node.parentElement) {
      var r = node.getBoundingClientRect();
      if (r.width > vw * 0.25 && r.width < vw * 0.5 && r.height > vh * 0.6 && r.left > vw * 0.45) { return true; }
    }
    return false;
  }

  function consider(el, final) {
    if (!playerOn || !el || el.nodeType !== 1 || !el.hasAttribute) { return; }
    if (el.hasAttribute('data-ab-clear')) { return; }
    if (typeof SVGElement !== 'undefined' && el instanceof SVGElement) { return; }
    var tag = el.tagName;
    if (tag === 'VIDEO' || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'IMG' || tag === 'CANVAS' || tag === 'SOURCE') { return; }
    if (el.closest && el.closest('#__ab_menu')) { return; }

    var color = parseColor(final ? finalBackground(el) : getComputedStyle(el).backgroundColor);
    if (!color || color.a < 0.97) { return; }
    var isBlack = Math.max(color.r, color.g, color.b) < 24 && Math.abs(color.r - color.b) < 4;
    var isGray = Math.abs(color.r - color.g) < 4 && Math.abs(color.g - color.b) < 4 && color.r >= 24 && color.r <= 100;
    if (!isBlack && !isGray) { return; }

    var box = el.getBoundingClientRect();
    if (box.width < 4 || box.height < 20) { return; }
    var vw = window.innerWidth, vh = window.innerHeight;

    // A wide black panel (the related videos shelf) fades in instead of being a solid block.
    var isPanel = isBlack && box.width >= vw * 0.6 && box.width <= vw * 0.97 && box.height >= 100;
    if (!isPanel && (box.width > vw * 0.6 || box.height > vh * 0.5)) { return; }

    if (el.querySelector && el.querySelector('video')) { return; }
    if (insideSidePanel(el)) { return; }
    if (!isPanel && overlapsThumbnail(el, box)) { return; }

    el.setAttribute('data-ab-clear', isPanel ? 'panel' : (isBlack ? 'black' : 'gray'));
  }

  function scanTree(root, limit) {
    if (!playerOn || !root || root.nodeType !== 1) { return 0; }
    var count = 1;
    consider(root, false);
    var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
    for (var i = 0; i < all.length && i < limit; i++) { consider(all[i], false); count++; }
    return count;
  }

  // Something's look is changing (for example it got highlighted): show the app's own look, work out where
  // it is heading, and fix it again straight away, before anything is drawn.
  function refresh(el) {
    if (!el || el.nodeType !== 1) { return; }
    if (el.hasAttribute('data-ab-clear')) { el.removeAttribute('data-ab-clear'); }
    consider(el, true);
    var marked = el.querySelectorAll ? el.querySelectorAll('[data-ab-clear]') : [];
    for (var i = 0; i < marked.length && i < 80; i++) {
      marked[i].removeAttribute('data-ab-clear');
      consider(marked[i], true);
    }
  }

  function scanLater(node, delay) {
    setTimeout(function () {
      if (!node.isConnected) { return; }
      evaluatePlayer();
      scanTree(node, 800);
    }, delay);
  }

  var observer = new MutationObserver(function (records) {
    evaluatePlayer();
    var budget = 1500;
    records.forEach(function (record) {
      if (budget <= 0) { return; }
      if (record.type === 'childList') {
        record.addedNodes.forEach(function (node) {
          if (node.nodeType !== 1) { return; }
          budget -= scanTree(node, 800);
          scanLater(node, 80);   // layout may not be ready yet: look again a moment later
          scanLater(node, 400);
        });
      } else if (record.type === 'attributes') {
        refresh(record.target);
        budget -= 1;
      }
    });
  });
  observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });

  // Safety net for anything that was missed.
  setInterval(function () {
    evaluatePlayer();
    if (playerOn && document.body) { scanTree(document.body, 2500); }
  }, 1200);
})();
"""#

    /// Records what is happening in the player so a report can be copied from Settings.
    static let diagnosticsScript = #"""
(function () {
  if (location.hostname.indexOf('youtube.com') === -1) { return; }
  if (location.pathname !== '/tv' && location.pathname.indexOf('/tv/') !== 0) { return; }
  if (window.__abDiag) { return; }
  window.__abDiag = true;
  window.__abLog = [];

  function log(text) {
    window.__abLog.push(new Date().toISOString().substr(11, 8) + ' ' + text);
    if (window.__abLog.length > 60) { window.__abLog.shift(); }
  }

  // Remember which qualities and codecs YouTube offers for the current video.
  function summarize(value) {
    try {
      var data = value && (value.streamingData || (value.playerResponse && value.playerResponse.streamingData));
      if (!data || !data.adaptiveFormats) { return; }
      var heights = {}, codecs = {};
      data.adaptiveFormats.forEach(function (format) {
        if (format.height) { heights[format.height] = true; }
        var part = String(format.mimeType || '').split('codecs=')[1];
        if (part) { codecs[part.replace(/["']/g, '').split('.')[0]] = true; }
      });
      var list = Object.keys(heights).map(Number).sort(function (a, b) { return a - b; });
      window.__abFormats = 'heights ' + list.join(',') + ' | codecs ' + Object.keys(codecs).join(',');
    } catch (e) {}
  }

  var parse = JSON.parse;
  JSON.parse = function () {
    var value = parse.apply(this, arguments);
    summarize(value);
    return value;
  };

  if (window.MediaSource && MediaSource.prototype.addSourceBuffer) {
    var addSourceBuffer = MediaSource.prototype.addSourceBuffer;
    MediaSource.prototype.addSourceBuffer = function (type) {
      log('addSourceBuffer ' + type);
      return addSourceBuffer.apply(this, arguments);
    };
  }

  document.addEventListener('error', function (event) {
    var target = event.target;
    if (target && target.tagName === 'VIDEO') {
      var error = target.error;
      log('VIDEO ERROR code=' + (error ? error.code : '?') + ' ' + (error && error.message ? error.message : ''));
    }
  }, true);

  window.addEventListener('error', function (event) { log('error: ' + event.message); });

  function shortUrl(url) {
    try {
      var parsed = new URL(url, location.href);
      return parsed.host + parsed.pathname.substr(0, 40);
    } catch (e) { return String(url).substr(0, 60); }
  }

  // Failed requests are the most useful clue when a video dies ("HTTP 403 ...googlevideo.com/videoplayback").
  if (window.fetch) {
    var realFetch = window.fetch;
    window.fetch = function (input) {
      var url = '';
      try { url = typeof input === 'string' ? input : ((input && input.url) || ''); } catch (e) {}
      return realFetch.apply(this, arguments).then(function (response) {
        if (response && response.status >= 400) { log('HTTP ' + response.status + ' ' + shortUrl(url)); }
        return response;
      }, function (error) {
        log('NETWORK FAIL ' + shortUrl(url) + ' ' + error);
        throw error;
      });
    };
  }

  if (window.XMLHttpRequest) {
    var realOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      var self = this;
      this.__abUrl = url;
      this.addEventListener('loadend', function () {
        if (self.status >= 400 || self.status === 0) { log('XHR ' + self.status + ' ' + shortUrl(self.__abUrl)); }
      });
      return realOpen.apply(this, arguments);
    };
  }

  var realConsoleError = console.error;
  console.error = function () {
    try { log('console.error: ' + Array.prototype.slice.call(arguments).map(String).join(' ').substr(0, 200)); } catch (e) {}
    return realConsoleError.apply(console, arguments);
  };

  window.addEventListener('unhandledrejection', function (event) {
    log('promise rejected: ' + String(event.reason).substr(0, 160));
  });

  // When the app shows "Something went wrong", press its Try again button (already highlighted) for you.
  var retries = 0, lastRetry = 0, waiting = false;
  function errorShowing() {
    try {
      var nodes = document.querySelectorAll('div, span, h1, h2, h3, p');
      for (var i = 0; i < nodes.length && i < 4000; i++) {
        var node = nodes[i];
        if (node.children.length === 0 && node.textContent.trim() === 'Something went wrong' && node.getClientRects().length > 0) { return true; }
      }
    } catch (e) {}
    return false;
  }
  setInterval(function () {
    var enabled = false;
    try { enabled = localStorage.getItem('__ab_tv_retry') === '1'; } catch (e) {}
    if (!enabled || waiting || !errorShowing()) { return; }
    if (Date.now() - lastRetry > 120000) { retries = 0; }
    if (retries >= 3) { return; }
    waiting = true;
    setTimeout(function () {
      waiting = false;
      if (!errorShowing()) { return; }
      retries += 1;
      lastRetry = Date.now();
      log('auto-retry ' + retries);
      if (window.__ab && window.__ab.key) { window.__ab.key('Enter', 'Enter', 13); }
    }, 1500);
  }, 2000);

  window.__abReport = function () {
    var lines = [];
    lines.push('UA: ' + navigator.userAgent);
    lines.push('Window: ' + window.innerWidth + 'x' + window.innerHeight + ' @' + window.devicePixelRatio +
      ' | screen ' + window.screen.width + 'x' + window.screen.height);
    lines.push('Settings: res=' + (localStorage.getItem('__ab_tv_res') || 'auto') +
      ' adblock=' + (localStorage.getItem('__ab_tv_adblock') || '1'));

    var real = window.__abRealIsTypeSupported || MediaSource.isTypeSupported.bind(MediaSource);
    var probes = [
      ['H.264 1080p', 'video/mp4; codecs="avc1.640028"'],
      ['H.264 4K', 'video/mp4; codecs="avc1.640033"'],
      ['VP9', 'video/webm; codecs="vp9"'],
      ['VP9 4K', 'video/webm; codecs="vp09.00.51.08"'],
      ['AV1', 'video/mp4; codecs="av01.0.12M.08"']
    ];
    probes.forEach(function (probe) {
      var ok;
      try { ok = real(probe[1]); } catch (e) { ok = 'error'; }
      lines.push('Device supports ' + probe[0] + ': ' + ok);
    });

    lines.push('Offered: ' + (window.__abFormats || 'nothing yet (play a video first)'));
    lines.push('--- recent events ---');
    return lines.concat(window.__abLog.slice(-30)).join('\n');
  };
})();
"""#
}
