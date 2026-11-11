import UIKit
import UniformTypeIdentifiers

/// Receives one shared photo or file and leaves it in the App Group inbox for
/// the app to pick up.
///
/// Inbox contract (read by the app): `<group container>/ShareInbox/<uuid>/`
/// holds the item under its original name plus `meta.json`
/// `{"name": String, "uti": String, "isImage": Bool, "count": Int}`, where
/// `count` is how many items were shared. Only the first item is written, and
/// it replaces whatever the inbox held, so only the latest share is kept.
///
/// No UI of its own: the system share sheet is all the user sees.
final class ShareViewController: UIViewController {
  private static let inboxName = "ShareInbox"
  private static let hostURL = URL(string: "nfcarchiver-share://shared")!

  private var started = false

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true

    let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
    guard let first = attachments.first else {
      fail(ShareError.nothingShared)
      return
    }
    receive(first, count: attachments.count) { [weak self] error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error {
          self.fail(error)
          return
        }
        self.openHostApp()
        self.extensionContext?.completeRequest(returningItems: nil)
      }
    }
  }

  // MARK: - Receiving

  private func receive(
    _ provider: NSItemProvider, count: Int, completion: @escaping (Error?) -> Void
  ) {
    let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
    if let image = types.first(where: { $0.conforms(to: .image) }) {
      loadFile(provider, type: image, isImage: true, count: count, completion: completion)
    } else if let data = types.first(where: {
      $0.conforms(to: .data) && !$0.conforms(to: .url)
    }) {
      loadFile(provider, type: data, isImage: false, count: count, completion: completion)
    } else if types.contains(where: { $0.conforms(to: .fileURL) }) {
      loadFileURL(provider, count: count, completion: completion)
    } else if let item = types.first(where: { $0.conforms(to: .item) }) {
      loadFile(provider, type: item, isImage: false, count: count, completion: completion)
    } else {
      completion(ShareError.unsupported)
    }
  }

  /// The URL handed to the handler is deleted when it returns, so the copy
  /// happens inside it.
  private func loadFile(
    _ provider: NSItemProvider, type: UTType, isImage: Bool, count: Int,
    completion: @escaping (Error?) -> Void
  ) {
    _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
      guard let url else {
        completion(error ?? ShareError.unsupported)
        return
      }
      completion(Self.writeInbox(
        from: url, uti: type.identifier, isImage: isImage, count: count))
    }
  }

  /// Some apps (Files among them) offer only a file URL, not the data.
  private func loadFileURL(
    _ provider: NSItemProvider, count: Int, completion: @escaping (Error?) -> Void
  ) {
    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
      let url = (item as? URL) ?? (item as? Data).flatMap {
        URL(dataRepresentation: $0, relativeTo: nil)
      }
      guard let url, url.isFileURL else {
        completion(error ?? ShareError.unsupported)
        return
      }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? .data
      completion(Self.writeInbox(
        from: url, uti: type.identifier, isImage: type.conforms(to: .image), count: count))
    }
  }

  // MARK: - Inbox

  /// Builds the new inbox beside the old one and swaps it in, so the app never
  /// sees a half-written item.
  private static func writeInbox(
    from source: URL, uti: String, isImage: Bool, count: Int
  ) -> Error? {
    guard
      let group = Bundle.main.object(forInfoDictionaryKey: "NFARAppGroup") as? String,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    else { return ShareError.noAppGroup }

    let fm = FileManager.default
    let id = UUID().uuidString
    let staging = container.appendingPathComponent(".\(inboxName)-\(id)", isDirectory: true)
    let inbox = container.appendingPathComponent(inboxName, isDirectory: true)
    do {
      let itemDir = staging.appendingPathComponent(id, isDirectory: true)
      try fm.createDirectory(at: itemDir, withIntermediateDirectories: true)

      var name = source.lastPathComponent
      if name.isEmpty { name = "shared" }
      if name == "meta.json" { name = "shared-meta.json" }
      try fm.copyItem(at: source, to: itemDir.appendingPathComponent(name))

      let meta: [String: Any] = [
        "name": name, "uti": uti, "isImage": isImage, "count": count,
      ]
      try JSONSerialization.data(withJSONObject: meta)
        .write(to: itemDir.appendingPathComponent("meta.json"), options: .atomic)

      if fm.fileExists(atPath: inbox.path) { try fm.removeItem(at: inbox) }
      try fm.moveItem(at: staging, to: inbox)
      return nil
    } catch {
      try? fm.removeItem(at: staging)
      return error
    }
  }

  // MARK: - Host app

  /// Best effort. Apple offers share extensions no way to open their host app,
  /// and the responder-chain route below has broken across iOS releases. The
  /// app also checks the inbox on launch and on every resume, so if this does
  /// nothing the share still arrives the next time the app is opened.
  ///
  /// `UIApplication.open` is unavailable to extensions at compile time, so it
  /// is called through its selector on the instance found in the chain.
  private func openHostApp() {
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication,
        application.responds(to: selector)
      {
        typealias Open = @convention(c) (
          AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
        ) -> Void
        let open = unsafeBitCast(application.method(for: selector), to: Open.self)
        open(application, selector, Self.hostURL as NSURL, NSDictionary(), nil)
        return
      }
      responder = current.next
    }
  }

  private func fail(_ error: Error) {
    extensionContext?.cancelRequest(withError: error)
  }
}

private enum ShareError: Error {
  case nothingShared
  case unsupported
  case noAppGroup
}
