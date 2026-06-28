import Flutter
import CoreVideo

/// Flutter external texture backed by the latest composited pixel buffer.
///
/// Phase 0/3: the Metal compositor writes a BGRA/IOSurface-backed
/// `CVPixelBuffer` here each frame; `copyPixelBuffer` hands the same buffer to
/// the Flutter raster thread (zero-copy). Until the compositor is wired
/// (Phase 3) this returns nil and the preview shows the widget's placeholder.
final class DualCameraTexture: NSObject, FlutterTexture {
  private let lock = NSLock()
  private var latest: CVPixelBuffer?

  /// Swap in a new composited frame. Thread-safe; called from the capture queue.
  func push(_ buffer: CVPixelBuffer) {
    lock.lock()
    latest = buffer
    lock.unlock()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }
}
