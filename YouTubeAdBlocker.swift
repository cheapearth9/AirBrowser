import WebKit

final class YouTubeAdBlocker {
    static let videoAdSkipScript = """
    (function() {
        if (window.__ytAdBlockInjected) return;
        window.__ytAdBlockInjected = true;

        function autoSkip() {
            const skipButtons = document.querySelectorAll(
                '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot'
            );
            skipButtons.forEach(btn => btn.click());

            const video = document.querySelector('video');
            const adInterrupt = document.querySelector('.ad-interrupting, .html5-ad-pipeline');
            if (video && adInterrupt) {
                video.muted = true;
                video.playbackRate = 16.0;
                if (isFinite(video.duration)) {
                    video.currentTime = video.duration;
                }
            }
        }

        setInterval(autoSkip, 250);
    })();
    """

    static func apply(to configuration: WKWebViewConfiguration) {
        let userScript = WKUserScript(
            source: videoAdSkipScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)
    }
}
