import Foundation

struct YouTubeAdBlocker {
    static func getScript() -> String {
        return #"""
        (function() {
            function skipAds() {
                var skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot');
                if (skipBtn) {
                    skipBtn.click();
                }

                var video = document.querySelector('video');
                var adShowing = document.querySelector('.ad-showing, .ad-interrupting, .ytp-ad-player-overlay');
                if (video && adShowing) {
                    video.muted = true;
                    video.playbackRate = 16.0;
                    if (!isNaN(video.duration) && video.duration > 0) {
                        video.currentTime = video.duration;
                    }
                }

                var overlayAds = document.querySelectorAll('.ytp-ad-overlay-container, ytd-action-companion-ad-renderer, #player-ads');
                for (var i = 0; i < overlayAds.length; i++) {
                    overlayAds[i].remove();
                }
            }

            setInterval(skipAds, 500);
        })();
        """#
    }
}
