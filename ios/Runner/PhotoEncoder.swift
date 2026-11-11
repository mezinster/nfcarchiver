import CoreGraphics
import Flutter
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `com.nfcarchiver/photo`: decodes a photo once per session and re-encodes it
/// as a metadata-free JPEG at any longest side and quality.
///
/// Each scaled bitmap is rendered with the orientation baked in, drawn onto
/// white, and cached per maxSide so the fit search's repeated encodes at one
/// size skip the decode. All work runs on a serial background queue, which
/// also owns `sessions`; results are posted back on the main queue.
///
/// Errors never carry the file path: diagnostics must not log paths.
final class PhotoEncoder {
  private static let channelName = "com.nfcarchiver/photo"
  /// Decoded pixels kept per session before older sizes are dropped. A 12 MP
  /// photo alone is ~48 MB, so the newest entry is always kept.
  private static let cacheBudgetBytes = 64 * 1024 * 1024

  private final class Session {
    let source: CGImageSource
    let longestSide: Int
    var width = 0
    var height = 0
    var cache: [Int: CGImage] = [:]
    var lru: [Int] = []

    init(source: CGImageSource, longestSide: Int) {
      self.source = source
      self.longestSide = longestSide
    }
  }

  private let queue = DispatchQueue(label: "com.nfcarchiver.photo", qos: .userInitiated)
  private var sessions: [Int: Session] = [:]
  private var nextId = 1
  private var channel: FlutterMethodChannel?

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: PhotoEncoder.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(FlutterMethodNotImplemented) }
      let args = call.arguments as? [String: Any] ?? [:]
      self.queue.async {
        let reply = self.handle(call.method, args)
        DispatchQueue.main.async { result(reply) }
      }
    }
    self.channel = channel
  }

  // Runs on `queue`.
  private func handle(_ method: String, _ args: [String: Any]) -> Any? {
    switch method {
    case "open":
      guard let path = args["path"] as? String else { return badArgs() }
      return open(path)
    case "encode":
      guard let id = args["id"] as? Int, let maxSide = args["maxSide"] as? Int,
            let quality = args["quality"] as? Int, maxSide > 0, (1...100).contains(quality)
      else { return badArgs() }
      guard let session = sessions[id] else {
        return FlutterError(code: "no_session", message: "Unknown photo session", details: nil)
      }
      return encode(session, maxSide: maxSide, quality: quality)
    case "close":
      if let id = args["id"] as? Int { sessions.removeValue(forKey: id) }
      return nil
    default:
      return FlutterMethodNotImplemented
    }
  }

  private func open(_ path: String) -> Any? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) > 0,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let pw = props[kCGImagePropertyPixelWidth] as? Int,
          let ph = props[kCGImagePropertyPixelHeight] as? Int, pw > 0, ph > 0
    else { return decodeFailed() }

    let session = Session(source: source, longestSide: max(pw, ph))
    // Render the original size now: it proves the file decodes, gives the
    // dimensions after orientation, and is the fit search's first encode.
    guard let original = bitmap(session, side: session.longestSide) else { return decodeFailed() }
    session.width = original.width
    session.height = original.height

    let id = nextId
    nextId += 1
    sessions[id] = session
    return ["id": id, "width": session.width, "height": session.height]
  }

  private func encode(_ session: Session, maxSide: Int, quality: Int) -> Any? {
    // Never upscale.
    guard let image = bitmap(session, side: min(maxSide, session.longestSide)) else {
      return decodeFailed()
    }
    return autoreleasepool { () -> Any? in
      let data = NSMutableData()
      guard let dest = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil)
      else { return encodeFailed() }
      // Quality is the only option: no metadata properties are written.
      CGImageDestinationAddImage(
        dest, image,
        [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0] as CFDictionary)
      guard CGImageDestinationFinalize(dest) else { return encodeFailed() }
      return FlutterStandardTypedData(bytes: data as Data)
    }
  }

  /// The oriented, white-backed bitmap whose longest side is [side], cached.
  private func bitmap(_ session: Session, side: Int) -> CGImage? {
    if let hit = session.cache[side] {
      session.lru.removeAll { $0 == side }
      session.lru.append(side)
      return hit
    }
    guard let image = render(session.source, side: side) else { return nil }
    session.cache[side] = image
    session.lru.append(side)
    var total = session.cache.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    while total > PhotoEncoder.cacheBudgetBytes, session.lru.count > 1 {
      let evicted = session.lru.removeFirst()
      if let old = session.cache.removeValue(forKey: evicted) {
        total -= old.bytesPerRow * old.height
      }
    }
    return image
  }

  private func render(_ source: CGImageSource, side: Int) -> CGImage? {
    autoreleasepool {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: side,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
              data: nil, width: thumb.width, height: thumb.height, bitsPerComponent: 8,
              bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return nil }
      // Opaque sRGB context: transparency lands on white, and wide-gamut
      // sources are converted, since the ICC profile does not survive the
      // metadata strip.
      let rect = CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height)
      ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
      ctx.fill(rect)
      ctx.interpolationQuality = .high
      ctx.draw(thumb, in: rect)
      return ctx.makeImage()
    }
  }

  private func badArgs() -> FlutterError {
    FlutterError(code: "bad_args", message: "Invalid photo channel arguments", details: nil)
  }

  private func decodeFailed() -> FlutterError {
    FlutterError(code: "decode_failed", message: "The image could not be decoded", details: nil)
  }

  private func encodeFailed() -> FlutterError {
    FlutterError(code: "encode_failed", message: "The image could not be encoded", details: nil)
  }
}
