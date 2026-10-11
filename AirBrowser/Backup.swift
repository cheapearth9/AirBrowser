import UIKit
import WebKit
import UniformTypeIdentifiers

/// One saved cookie (this is what keeps you signed in to Google, YouTube and so on).
struct StoredCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
    var sameSite: String?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
        sameSite = cookie.sameSitePolicy?.rawValue
    }

    func makeCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path
        ]
        if let expires = expires { properties[.expires] = expires }
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite = sameSite { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)
    }
}

struct BackupFile: Codable {
    var version: Int
    var created: Date
    var history: [HistoryEntry]
    var cookies: [StoredCookie]
    var desktopSite: Bool
    var tvProfile: Int
}

/// Saves logins, history and settings to a file you keep in the Files app, and loads them back.
/// Useful when the app is reinstalled or updated in a way that wipes its private storage.
final class BackupManager: NSObject, UIDocumentPickerDelegate {
    static let shared = BackupManager()

    private var isImporting = false

    private override init() {
        super.init()
    }

    private func say(_ text: String) {
        NotificationCenter.default.post(name: DownloadManager.message, object: nil, userInfo: ["text": text])
    }

    // MARK: Back up

    func exportBackup(from presenter: UIViewController) {
        let cookieStore = DisplayController.shared.webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { [weak self, weak presenter] cookies in
            DispatchQueue.main.async {
                guard let self = self, let presenter = presenter else { return }

                let now = Date()
                let backup = BackupFile(
                    version: 1,
                    created: now,
                    history: HistoryStore.shared.entries,
                    cookies: cookies
                        .filter { ($0.expiresDate ?? Date.distantFuture) > now }
                        .map { StoredCookie($0) },
                    desktopSite: DisplayController.shared.prefersDesktopSite,
                    tvProfile: YouTubeTV.profileIndex
                )

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                guard let data = try? encoder.encode(backup) else {
                    self.say("Backup failed")
                    return
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let fileName = "AirBrowser Backup " + formatter.string(from: now) + ".json"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    self.say("Backup failed")
                    return
                }

                self.isImporting = false
                let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                picker.delegate = self
                presenter.present(picker, animated: true)
            }
        }
    }

    // MARK: Restore

    func importBackup(from presenter: UIViewController) {
        isImporting = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.json], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if isImporting {
            isImporting = false
            guard let url = urls.first else { return }
            restore(from: url)
        } else {
            say("Backup saved")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        isImporting = false
    }

    private func restore(from url: URL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: url),
              let backup = try? decoder.decode(BackupFile.self, from: data) else {
            say("That file is not an AirBrowser backup")
            return
        }

        HistoryStore.shared.merge(backup.history)
        DisplayController.shared.prefersDesktopSite = backup.desktopSite
        YouTubeTV.profileIndex = backup.tvProfile

        let cookieStore = DisplayController.shared.webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        var count = 0

        for stored in backup.cookies {
            guard let cookie = stored.makeCookie() else { continue }
            count += 1
            group.enter()
            cookieStore.setCookie(cookie) {
                group.leave()
            }
        }

        let restoredCookies = count
        let restoredHistory = backup.history.count
        group.notify(queue: .main) { [weak self] in
            DisplayController.shared.webView.reload()
            self?.say("Restored \(restoredCookies) cookies and \(restoredHistory) history entries")
        }
    }
}
