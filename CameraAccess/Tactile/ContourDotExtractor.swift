import CoreImage
import UIKit
import Vision

/// `Painting → grayscale → blur → contours (Vision) → simplify (RDP) → arc-length
/// dot sampling` — the pipeline turns a photo into a set of normalized points
/// tracing its most significant boundaries, evenly spaced so a fingertip can
/// follow them as a dotted line rather than feeling a filled blob or a mass
/// of noise. Points are normalized 0...1, Vision's convention (origin
/// bottom-left, y-up).
enum ContourDotExtractor {
  static func extract(
    from image: UIImage,
    maxImageDimension: CGFloat = 512,
    maxContours: Int = 4,
    minAreaFraction: CGFloat = 0.02,
    simplificationEpsilon: Float = 0.01,
    dotSpacing: CGFloat = 0.02
  ) -> [CGPoint] {
    guard let cgImage = image.cgImage else { return [] }

    // 1. Resize + grayscale + light blur — suppresses brush-stroke/texture
    // noise before edge detection, same as a bilateral/Gaussian pre-filter
    // would in a Canny pipeline.
    let ciImage = CIImage(cgImage: cgImage)
    let scale = maxImageDimension / max(ciImage.extent.width, ciImage.extent.height)
    let resized = scale < 1 ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ciImage
    let grayscale = resized.applyingFilter("CIPhotoEffectMono")
    let blurred = grayscale
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
      .cropped(to: resized.extent)

    let context = CIContext()
    guard let preprocessedCG = context.createCGImage(blurred, from: resized.extent) else { return [] }

    // 2. Edge map + contour tracing — Vision's built-in equivalent of
    // Canny + findContours, producing vector paths rather than pixel edges.
    let request = VNDetectContoursRequest()
    request.contrastAdjustment = 2.0
    request.maximumImageDimension = Int(maxImageDimension)

    let handler = VNImageRequestHandler(cgImage: preprocessedCG, options: [:])
    do {
      try handler.perform([request])
      guard let observation = request.results?.first else {
        print("🟠 ContourDotExtractor: no observation returned")
        return []
      }
      // `topLevelContours` only exposes the roots of Vision's contour tree —
      // in practice that's just the outer photo-frame boundary, with every
      // actual shape inside the image nested underneath it as children.
      // Walk the flat, all-levels index instead so we see everything Vision
      // found, then drop whatever is (near-)frame-sized, since that's always
      // the border, never real content.
      let allContours: [VNContour] = (0..<observation.contourCount).compactMap {
        try? observation.contour(at: $0)
      }
      print(
        "🟣 ContourDotExtractor: topLevelContours.count=\(observation.topLevelContours.count) allContours.count=\(allContours.count)"
      )

      // 3. Keep only the few largest non-frame contours — a stand-in for
      // "the subject" ranking without full semantic segmentation. Vision
      // happily returns dozens of tiny contours (text, icons, texture); most
      // of those are clutter, not the thing being looked at, so anything
      // under `minAreaFraction` of the frame is dropped before ranking, not
      // just capped by count.
      let ranked = allContours
        .filter { contour in
          let area = contour.normalizedPath.boundingBoxOfPath.area
          return area < 0.9 && area >= minAreaFraction
        }
        .sorted { $0.normalizedPath.boundingBoxOfPath.area > $1.normalizedPath.boundingBoxOfPath.area }
        .prefix(maxContours)

      var points: [CGPoint] = []
      for (i, contour) in ranked.enumerated() {
        // 4. Simplify — Vision's own Ramer-Douglas-Peucker implementation,
        // same algorithm as OpenCV's approxPolyDP.
        let simplified: VNContour
        do {
          simplified = try contour.polygonApproximation(epsilon: simplificationEpsilon)
        } catch {
          print("🟠 ContourDotExtractor: polygonApproximation failed for contour \(i) (\(error)), using raw contour")
          simplified = contour
        }
        let box = contour.normalizedPath.boundingBoxOfPath
        // 5. Resample at fixed arc-length spacing — evenly-spaced dots along
        // the curve, not just the (unevenly-spaced) RDP vertices.
        let sampled = sampleArcLength(path: simplified.normalizedPath, spacing: dotSpacing)
        print("🟣 ContourDotExtractor: contour \(i) box=\(box) sampled=\(sampled.count) points")
        points.append(contentsOf: sampled)
      }
      print("🟣 ContourDotExtractor: total points=\(points.count)")
      return points
    } catch {
      print("🟠 ContourDotExtractor: Vision request failed (\(error))")
      return []
    }
  }

  /// Walks a CGPath's segments and returns points spaced `spacing` apart
  /// along its total arc length.
  private static func sampleArcLength(path: CGPath, spacing: CGFloat) -> [CGPoint] {
    var segments: [(CGPoint, CGPoint)] = []
    var current = CGPoint.zero
    var subpathStart = CGPoint.zero

    path.applyWithBlock { elementPtr in
      let element = elementPtr.pointee
      switch element.type {
      case .moveToPoint:
        current = element.points[0]
        subpathStart = current
      case .addLineToPoint:
        let next = element.points[0]
        segments.append((current, next))
        current = next
      case .addQuadCurveToPoint:
        let next = element.points[1]
        segments.append((current, next))
        current = next
      case .addCurveToPoint:
        let next = element.points[2]
        segments.append((current, next))
        current = next
      case .closeSubpath:
        segments.append((current, subpathStart))
        current = subpathStart
      @unknown default:
        break
      }
    }

    var result: [CGPoint] = []
    var carryover: CGFloat = 0
    for (start, end) in segments {
      let dx = end.x - start.x
      let dy = end.y - start.y
      let length = (dx * dx + dy * dy).squareRoot()
      guard length > 0 else { continue }
      var distance = spacing - carryover
      while distance < length {
        let t = distance / length
        result.append(CGPoint(x: start.x + dx * t, y: start.y + dy * t))
        distance += spacing
      }
      carryover = length - (distance - spacing)
    }
    return result
  }
}

private extension CGRect {
  var area: CGFloat { width * height }
}
