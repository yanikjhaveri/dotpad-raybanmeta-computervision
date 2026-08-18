import CoreGraphics
import Foundation

/// A single detected object, ready for on-screen overlay.
struct DetectedObject: Identifiable, Sendable {
  let id = UUID()
  let label: String
  let confidence: Float
  /// Normalized bounding box, origin top-left, 0...1 in both axes.
  let boundingBox: CGRect
}
