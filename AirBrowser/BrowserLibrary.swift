import UIKit
import WebKit
import QuickLook

// MARK: - History

struct HistoryEntry: Codable, Equatable {
    let id: UUID
    var title: String
    var url: String
    var date: Date
}

/// Remembers visited pages (saved on the device, newest first).
final class HistoryStore {
    static let shared = HistoryStore()

    private let storageKey = "AirBrowser.history.v1"
    private let maxEntries = 1000

    private(set) var entries: [HistoryEntry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    /// Call whenever the page address or title changes. Repeats of the same page are merged.
    func record(url: URL?, title: String?) {
        guard let url = url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }

        let address = url.absoluteString
        let cleanTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if let first = entries.first, first.url == address {
            if !cleanTitle.isEmpty && first.title != cleanTitle {
                entries[0].title = cleanTitle
                save()
            }
            return
        }

        entries.insert(HistoryEntry(id: UUID(), title: cleanTitle, url: address, date: Date()), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Adds entries from a backup, skipping ones that are already here.
    func merge(_ imported: [HistoryEntry]) {
        let known = Set(entries.map { $0.id })
        let additions = imported.filter { !known.contains($0.id) }
        guard !additions.isEmpty else { return }

        entries = (entries + additions).sorted { $0.date > $1.date }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Downloads

final class DownloadItem {
    enum State {
        case downloading
        case failed
    }

    var fileName: String
    var fileURL: URL?
    var fraction: Double = 0
    var state: State = .downloading
    var observation: NSKeyValueObservation?

    init(fileName: String) {
        self.fileName = fileName
    }
}

/// Saves files the web view downloads into Documents/Downloads.
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    /// Posted (throttled) whenever the list or a progress value changes.
    static let didChange = Notification.Name("AirBrowser.downloadsChanged")
    /// Posted with userInfo["text"] for short on-screen messages.
    static let message = Notification.Name("AirBrowser.downloadMessage")

    /// Downloads that are running or failed in this session (finished ones live on disk).
    private(set) var items: [DownloadItem] = []

    private var itemsByDownload: [ObjectIdentifier: DownloadItem] = [:]
    private var changePending = false

    private override init() {
        super.init()
    }

    var folder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Called by the web view when a navigation turns into a download.
    func adopt(_ download: WKDownload) {
        download.delegate = self

        let name = download.originalRequest?.url?.lastPathComponent ?? "Download"
        let item = DownloadItem(fileName: name.isEmpty ? "Download" : name)
        itemsByDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)

        item.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self, weak item] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async {
                item?.fraction = value
                self?.changed()
            }
        }

        post(message: "Downloading " + item.fileName)
        changed()
    }

    /// Files already saved, newest first.
    func savedFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        let inProgress = items.compactMap { $0.fileURL?.standardizedFileURL }
        let finished = urls.filter { !inProgress.contains($0.standardizedFileURL) }

        return finished.sorted { first, second in
            let firstDate = (try? first.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            let secondDate = (try? second.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            return firstDate > secondDate
        }
    }

    func remove(_ item: DownloadItem) {
        items.removeAll { $0 === item }
        changed()
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let destination = uniqueURL(for: suggestedFilename)
        if let item = itemsByDownload[ObjectIdentifier(download)] {
            item.fileName = destination.lastPathComponent
            item.fileURL = destination
        }
        changed()
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, success: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, success: false)
    }

    // MARK: Helpers

    private func finish(_ download: WKDownload, success: Bool) {
        guard let item = itemsByDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.observation = nil

        if success {
            items.removeAll { $0 === item }
            post(message: "Saved " + item.fileName + " to Downloads")
        } else {
            item.state = .failed
            if let url = item.fileURL {
                try? FileManager.default.removeItem(at: url)
            }
            post(message: "Download failed: " + item.fileName)
        }
        changed()
    }

    private func uniqueURL(for suggestedFilename: String) -> URL {
        var name = suggestedFilename.replacingOccurrences(of: "/", with: "-")
        if name.isEmpty { name = "download" }

        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension

        var number = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }

    private func post(message: String) {
        NotificationCenter.default.post(name: DownloadManager.message, object: nil, userInfo: ["text": message])
    }

    private func changed() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.changePending = false
            NotificationCenter.default.post(name: DownloadManager.didChange, object: nil)
        }
    }
}

// MARK: - Screens

/// Shared base for the History and Downloads sheets: a Close button and a "sheet was closed" callback.
class LibraryViewController: UITableViewController, UIAdaptivePresentationControllerDelegate {
    var onClose: (() -> Void)?

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
        navigationController?.presentationController?.delegate = self
    }

    @objc private func closeTapped() {
        dismiss(animated: true) { [weak self] in
            self?.onClose?()
        }
    }

    // Swiping the sheet down
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onClose?()
    }

    func makeEmptyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 16)
        return label
    }
}

final class HistoryViewController: LibraryViewController, UISearchResultsUpdating {
    var onSelect: ((URL) -> Void)?

    private var sections: [(title: String, entries: [HistoryEntry])] = []
    private var query = ""
    private let cellID = "HistoryCell"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "History"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearTapped))

        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        navigationItem.searchController = search
        definesPresentationContext = true

        reload()
    }

    private func reload() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = HistoryStore.shared.entries.filter { entry in
            needle.isEmpty || entry.title.lowercased().contains(needle) || entry.url.lowercased().contains(needle)
        }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: matching) { calendar.startOfDay(for: $0.date) }
        sections = grouped.keys.sorted(by: >).map { day in
            (title: HistoryViewController.heading(for: day), entries: grouped[day] ?? [])
        }

        tableView.backgroundView = sections.isEmpty
            ? makeEmptyLabel(needle.isEmpty ? "No history yet" : "No matches")
            : nil
        tableView.reloadData()
    }

    private static func heading(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        reload()
    }

    @objc private func clearTapped() {
        let alert = UIAlertController(title: "Clear History", message: "Remove all browsing history?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Clear All", style: .destructive) { [weak self] _ in
            HistoryStore.shared.clear()
            self?.reload()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].entries.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellID)
        let entry = sections[indexPath.section].entries[indexPath.row]

        cell.textLabel?.text = entry.title.isEmpty ? (URL(string: entry.url)?.host ?? entry.url) : entry.title
        cell.textLabel?.numberOfLines = 1
        cell.detailTextLabel?.text = entry.url
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 1
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let url = URL(string: sections[indexPath.section].entries[indexPath.row].url) else { return }
        dismiss(animated: true) { [weak self] in
            self?.onSelect?(url)
            self?.onClose?()
        }
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let entry = sections[indexPath.section].entries[indexPath.row]
        HistoryStore.shared.remove(id: entry.id)
        reload()
    }
}

final class DownloadsViewController: LibraryViewController, QLPreviewControllerDataSource {
    private enum Row {
        case item(DownloadItem)
        case file(URL)
    }

    private var rows: [Row] = []
    private var previewURL: URL?
    private let cellID = "DownloadCell"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: DownloadManager.didChange, object: nil)
        refresh()
    }

    @objc private func refresh() {
        let manager = DownloadManager.shared
        rows = manager.items.map { Row.item($0) } + manager.savedFiles().map { Row.file($0) }
        tableView.backgroundView = rows.isEmpty ? makeEmptyLabel("No downloads yet") : nil
        tableView.reloadData()
    }

    private static func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var parts: [String] = []
        if let size = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let date = values?.contentModificationDate {
            parts.append(dateFormatter.string(from: date))
        }
        return parts.joined(separator: " - ")
    }

    // MARK: Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellID)

        switch rows[indexPath.row] {
        case .item(let item):
            cell.textLabel?.text = item.fileName
            switch item.state {
            case .downloading:
                cell.detailTextLabel?.text = "Downloading... \(Int(item.fraction * 100))%"
            case .failed:
                cell.detailTextLabel?.text = "Failed - swipe to remove"
            }
            cell.selectionStyle = .none
        case .file(let url):
            cell.textLabel?.text = url.lastPathComponent
            cell.detailTextLabel?.text = DownloadsViewController.describe(url)
            cell.selectionStyle = .default
        }

        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .file(let url) = rows[indexPath.row] else { return }

        previewURL = url
        let preview = QLPreviewController()
        preview.dataSource = self
        present(preview, animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        switch rows[indexPath.row] {
        case .item(let item):
            return item.state == .failed
        case .file:
            return true
        }
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        switch rows[indexPath.row] {
        case .item(let item):
            DownloadManager.shared.remove(item)
        case .file(let url):
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
    }

    // MARK: Preview

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
    }
}
