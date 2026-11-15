import CoreGraphics
import Flutter
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `com.nfcarchiver/photo`: decodes a photo once per session and re-encodes it
/// as a metadata-free JPEG at any longest side and quality.
///
/// A photo is never decoded above `maxPixels`. A larger source (48-200 MP
/// sensors) is treated as if it were that size: `open` reports the capped
/// dimensions and every encode works within them, so Dart needs no cap of its
/// own and a full-resolution bitmap (190 MB at 48 MP) is never allocated.
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
  /// 16 MP, a 64 MB bitmap: the web app's canvas limit, and above any 12 MP
  /// photo.
  private static let maxPixels = 16_000_000
  /// The size of Dart's opening probe encode (photo_optimiser_provider.dart).
  private static let probeSide = 640

  private final class Session {
    let source: CGImageSource
    /// The largest side ever decoded: the source's, capped.
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

    // Dimensions come from the header: nothing is decoded at full size.
    var longest = max(pw, ph)
    if pw * ph > PhotoEncoder.maxPixels {
      let scale = (Double(PhotoEncoder.maxPixels) / Double(pw * ph)).squareRoot()
      longest = max(1, Int(Double(longest) * scale))
    }
    let shortest = max(
      1, Int((Double(longest) * Double(min(pw, ph)) / Double(max(pw, ph))).rounded()))
    let session = Session(source: source, longestSide: longest)
    // A small render proves the file decodes and shows which way up it is
    // after orientation; Dart's opening probe encode reuses it.
    guard let probe = bitmap(session, side: min(PhotoEncoder.probeSide, longest)) else {
      return decodeFailed()
    }
    let portrait = probe.width != probe.height ? probe.width < probe.height : pw < ph
    session.width = portrait ? shortest : longest
    session.height = portrait ? longest : shortest

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
