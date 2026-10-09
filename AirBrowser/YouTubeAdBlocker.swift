import Foundation

struct YouTubeAdBlocker {
    static func getScript() -> String {
        return """
        (function() {
            function skipAds() {
                // 1. Standard & Mobile YouTube Skip Buttons
                const skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot');
                if (skipBtn) {
                    skipBtn.click();
                }

                // 2. Fast-forward video ad for both standard and YouTube TV Leanback DOM
                const video = document.querySelector('video');
                const adShowing = document.querySelector('.ad-showing, .ad-interrupting, [class*="ad-created"], .ytp-ad-player-overlay');
                if (video && adShowing) {
                    video.muted = true;
                    video.playbackRate = 16.0;
                    if (!isNaN(video.duration) && video.duration > 0) {
                        video.currentTime = video.duration;
                    }
                }

                // 3. Remove banner / overlay ads
                const overlayAds = document.querySelectorAll('.ytp-ad-overlay-container, ytd-action-companion-ad-renderer, #player-ads');
                overlayAds.forEach(ad => ad.remove());
            }

            // Run check loop every 500ms
            setInterval(skipAds, 500);
        })();
        """
    }
}
