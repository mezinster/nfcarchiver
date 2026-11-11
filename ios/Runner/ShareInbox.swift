import Flutter
import Foundation

/// `com.nfcarchiver/share_in`: hands Dart the photo or file the share
/// extension left in the App Group inbox.
///
/// Inbox contract (written by `ShareViewController`):
/// `<group container>/ShareInbox/<uuid>/` holds the item under its name plus
/// `meta.json` `{"name": String, "uti": String, "isImage": Bool, "count": Int}`.
///
/// `take` copies the item into `Caches/share_in/<uuid>/` (the directory
/// path_provider's `getTemporaryDirectory()` returns, which Dart sweeps on the
/// next launch), deletes the item from the inbox, and replies
/// `{path, name, isImage, count}`, or nil when there is nothing — including
/// when the App Group is unavailable (a free-team build). A second `take`
/// therefore returns nil.
///
/// All file work runs on a serial background queue; replies are posted on the
/// main queue. Errors never carry a name or path: diagnostics must not log them.
final class ShareInbox {
  private static let channelName = "com.nfcarchiver/share_in"
  private static let inboxName = "ShareInbox"
  private static let stagingPrefix = ".\(inboxName)-"
  private static let outputDirName = "share_in"
  private static let fallbackName = "shared"
  private static let maxNameChars = 200
  /// The extension builds the next inbox in a staging directory and moves it
  /// into place. One left behind (the extension was killed mid-copy) is
  /// deleted once it is this old, so a share still being written is spared.
  private static let staleStagingAge: TimeInterval = 10 * 60

  private let queue = DispatchQueue(label: "com.nfcarchiver.share_in", qos: .userInitiated)
  private var channel: FlutterMethodChannel?

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: ShareInbox.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "take" else {
        return result(FlutterMethodNotImplemented)
      }
      self.queue.async {
        let reply = self.take()
        DispatchQueue.main.async { result(reply) }
      }
    }
    self.channel = channel
  }

  /// Tells Dart a share may have arrived while the app is running.
  func notifyAvailable() {
    DispatchQueue.main.async { self.channel?.invokeMethod("onShareAvailable", arguments: nil) }
  }

  // MARK: - Taking (runs on `queue`)

  private func take() -> Any? {
    guard
      let group = Bundle.main.object(forInfoDictionaryKey: "NFARAppGroup") as? String,
      !group.isEmpty,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    else { return nil }

    let fm = FileManager.default
    sweepStaleStaging(in: container)

    let inbox = container.appendingPathComponent(Self.inboxName, isDirectory: true)
    guard
      let items = try? fm.contentsOfDirectory(
        at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
      let item = items.first(where: { $0.hasDirectoryPath })
    else { return nil }

    // Only this item is deleted, never the whole inbox: a share swapped in
    // while we read lives under a new uuid and is kept for the next take.
    defer { try? fm.removeItem(at: item) }

    guard
      let data = try? Data(contentsOf: item.appendingPathComponent("meta.json")),
      let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let storedName = meta["name"] as? String,
      // Must name a file inside the item directory, nothing above it.
      !storedName.isEmpty, storedName != ".", storedName != "..",
      !storedName.contains("/")
    else { return unreadable() }

    let source = item.appendingPathComponent(storedName)
    guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return unreadable()
    }
    let outDir = caches
      .appendingPathComponent(Self.outputDirName, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let name = Self.sanitise(storedName) ?? Self.fallbackName
    let output = outDir.appendingPathComponent(name)
    do {
      try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
      try fm.copyItem(at: source, to: output)
    } catch {
      try? fm.removeItem(at: outDir)
      return unreadable()
    }

    return [
      "path": output.path,
      "name": name,
      "isImage": meta["isImage"] as? Bool ?? false,
      "count": max(meta["count"] as? Int ?? 1, 1),
    ] as [String: Any]
  }

  private func sweepStaleStaging(in container: URL) {
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(
        at: container, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
    else { return }
    let cutoff = Date().addingTimeInterval(-Self.staleStagingAge)
    for entry in entries where entry.lastPathComponent.hasPrefix(Self.stagingPrefix) {
      let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      if modified < cutoff { try? fm.removeItem(at: entry) }
    }
  }

  private func unreadable() -> FlutterError {
    FlutterError(
      code: "share_unreadable", message: "The shared item could not be read.", details: nil)
  }

  /// The last path component only, with no separators, control characters or
  /// dot names; nil when nothing usable is left.
  static func sanitise(_ raw: String) -> String? {
    let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    let cleaned = String(String.UnicodeScalarView(
      last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
      .trimmingCharacters(in: .whitespaces)
    let name = String(cleaned.prefix(maxNameChars))
    return name.isEmpty || name == "." || name == ".." ? nil : name
  }
}
