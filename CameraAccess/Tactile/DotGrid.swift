import CoreGraphics
import UIKit

/// A black-and-white dot-matrix rendering of an image, sized for a low-fidelity
/// or tactile display. `true` means the dot at that cell is "on" (dark).
struct DotGrid {
  let width: Int
  let height: Int
  /// Row-major: dots[y * width + x].
  let dots: [Bool]

  subscript(x: Int, y: Int) -> Bool {
    dots[y * width + x]
  }

  /// Builds a grid directly from normalized (0...1, Vision's convention —
  /// origin bottom-left, y-up) sample points, e.g. from
  /// `ContourDotExtractor`. Each point lights the nearest cell — this is
  /// deliberately *not* rendered into a bitmap and downsampled, since that
  /// would blur or merge individually-spaced dots back together.
  static func fromNormalizedPoints(_ points: [CGPoint], width: Int = 60, height: Int = 40) -> DotGrid {
    var dots = [Bool](repeating: false, count: width * height)
    for point in points {
      let x = Int((point.x * CGFloat(width)).rounded())
      let y = Int(((1 - point.y) * CGFloat(height)).rounded())
      guard x >= 0, x < width, y >= 0, y < height else { continue }
      dots[y * width + x] = true
    }
    return DotGrid(width: width, height: height, dots: dots)
  }
}

enum DotGridConverter {
  /// Converts an image into a `width` x `height` black-and-white dot grid using
  /// Floyd-Steinberg dithering, so the reduced resolution reads as a recognizable
  /// silhouette rather than a coarse, banded threshold.
  static func convert(image: UIImage, width: Int = 60, height: Int = 40) -> DotGrid? {
    guard let cgImage = image.cgImage else { return nil }

    // Render straight into a tiny grayscale bitmap — CoreGraphics does the
    // downsampling, so each pixel here is already one dot cell's average.
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else { return nil }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let data = context.data else { return nil }
    let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
    var gray = (0..<(width * height)).map { Float(buffer[$0]) }

    // Floyd-Steinberg error diffusion over the low-res grid — spreads each
    // pixel's rounding error to its neighbors instead of just thresholding,
    // which is what keeps a 40x60 grid legible as a shape.
    var dots = [Bool](repeating: false, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let i = y * width + x
        let oldValue = gray[i]
        let newValue: Float = oldValue < 128 ? 0 : 255
        dots[i] = newValue == 0
        let quantError = oldValue - newValue

        if x + 1 < width {
          gray[i + 1] += quantError * 7 / 16
        }
        if y + 1 < height {
          if x > 0 { gray[i + width - 1] += quantError * 3 / 16 }
          gray[i + width] += quantError * 5 / 16
          if x + 1 < width { gray[i + width + 1] += quantError * 1 / 16 }
        }
      }
    }

    return DotGrid(width: width, height: height, dots: dots)
  }

  /// Like `convert`, but for content that's already pure black-and-white
  /// (e.g. `ShapeSimplifier` output) — skips dithering, which exists to fake
  /// gradients in continuous-tone images and would only blur an already-clean
  /// shape, and just thresholds each downsampled cell directly.
  static func convertThresholded(image: UIImage, width: Int = 60, height: Int = 40) -> DotGrid? {
    guard let cgImage = image.cgImage else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else { return nil }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let data = context.data else { return nil }
    let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
    let dots = (0..<(width * height)).map { buffer[$0] < 128 }

    return DotGrid(width: width, height: height, dots: dots)
  }

  /// For repeating patterns (tiling, mosaics, textiles) — a direct pixel
  /// downsample thresholded at a per-photo cutoff chosen by Otsu's method,
  /// rather than a fixed 128. A pattern's "shape" is its repeating
  /// micro-structure, which this reproduces directly; AI shape-abstraction
  /// (`ArtworkShapeRenderer`) can't describe a tessellation as a handful of
  /// shapes and loses the repetition entirely — confirmed empirically by
  /// comparing both against a real tiling photo, where this read as a
  /// legible repeating grid and the shape version read as ~5 disconnected
  /// stars.
  static func convertOtsu(image: UIImage, width: Int = 60, height: Int = 40) -> DotGrid? {
    guard let cgImage = image.cgImage else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else { return nil }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let data = context.data else { return nil }
    let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
    let pixelCount = width * height

    var histogram = [Int](repeating: 0, count: 256)
    for i in 0..<pixelCount { histogram[Int(buffer[i])] += 1 }

    let threshold = otsuThreshold(histogram: histogram, pixelCount: pixelCount)
    let dots = (0..<pixelCount).map { Int(buffer[$0]) < threshold }

    return DotGrid(width: width, height: height, dots: dots)
  }

  /// Picks the grayscale cutoff that maximizes between-class variance of the
  /// resulting binary split — the standard technique for 1-bit/dither image
  /// conversion when exposure or lighting varies, instead of guessing a
  /// fixed number like 128.
  private static func otsuThreshold(histogram: [Int], pixelCount: Int) -> Int {
    let sumTotal = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }

    var sumB = 0.0
    var weightB = 0.0
    var bestVariance = -1.0
    var bestThreshold = 128

    for t in 0..<256 {
      weightB += Double(histogram[t])
      guard weightB > 0 else { continue }
      let weightF = Double(pixelCount) - weightB
      guard weightF > 0 else { break }

      sumB += Double(t * histogram[t])
      let meanB = sumB / weightB
      let meanF = (sumTotal - sumB) / weightF
      let varianceBetween = weightB * weightF * (meanB - meanF) * (meanB - meanF)

      if varianceBetween > bestVariance {
        bestVariance = varianceBetween
        bestThreshold = t
      }
    }
    return bestThreshold
  }
}

extension DotGrid {
  /// Renders the grid back into an image for on-screen preview — filled circles
  /// on a white background, scaled to fit within `targetSize`. Set
  /// `showOffDots` to also draw a faint hollow circle at every *inactive*
  /// cell — every physical DotPad pin position is always there, whether
  /// raised or flat, and showing the full grid is what makes a dense,
  /// dithered pattern (see `DotGridConverter.convert`) read as a proper
  /// halftone rather than sparse noise. Off for the default (coarse,
  /// AI-shape/pattern) previews, where the un-lit background would just add
  /// visual clutter around already-sparse content.
  func renderAsImage(targetSize: CGSize, showOffDots: Bool = false) -> UIImage {
    let cellSize = min(targetSize.width / CGFloat(width), targetSize.height / CGFloat(height))
    let imageSize = CGSize(width: cellSize * CGFloat(width), height: cellSize * CGFloat(height))
    let renderer = UIGraphicsImageRenderer(size: imageSize)
    return renderer.image { ctx in
      UIColor.white.setFill()
      ctx.fill(CGRect(origin: .zero, size: imageSize))
      let dotDiameter = cellSize * 0.8
      let offDiameter = cellSize * 0.5
      let inset = (cellSize - dotDiameter) / 2
      let offInset = (cellSize - offDiameter) / 2
      for y in 0..<height {
        for x in 0..<width {
          let cx = CGFloat(x) * cellSize
          let cy = CGFloat(y) * cellSize
          if self[x, y] {
            UIColor.black.setFill()
            ctx.cgContext.fillEllipse(
              in: CGRect(x: cx + inset, y: cy + inset, width: dotDiameter, height: dotDiameter)
            )
          } else if showOffDots {
            UIColor(white: 0.8, alpha: 1).setStroke()
            ctx.cgContext.strokeEllipse(
              in: CGRect(x: cx + offInset, y: cy + offInset, width: offDiameter, height: offDiameter)
            )
          }
        }
      }
    }
  }
}

extension DotGrid {
  /// Encodes this grid for `DotPadAPI.displayGraphicData(data:)` on a
  /// DotPad320: 300 bytes (600 hex chars), one byte per 2-wide x 4-tall dot
  /// cell, cells scanned left-to-right then top-to-bottom (30 x 10 cells, per
  /// Dot's own spec for the device). Each cell's 8 dots are packed using the
  /// standard 8-dot braille bit order — bits 0-3 are the left column
  /// top-to-bottom, bits 4-7 are the right column top-to-bottom — mirroring
  /// how the SDK already encodes braille cells (`FF` = fully raised).
  ///
  /// This is reconstructed from the SDK's demo code and Dot's public spec,
  /// not from documented bit-packing — verify against real hardware. If the
  /// rendered pattern is flipped/rotated/scrambled, the fix lives entirely in
  /// this function (cell scan order or the `bitIndex` formula below).
  func dotPadHexString() -> String {
    precondition(
      width % 2 == 0 && height % 4 == 0,
      "DotPad cell encoding needs width divisible by 2 and height divisible by 4"
    )
    let cellCols = width / 2
    let cellRows = height / 4
    var bytes = [UInt8]()
    bytes.reserveCapacity(cellRows * cellCols)

    for cellRow in 0..<cellRows {
      for cellCol in 0..<cellCols {
        var byte: UInt8 = 0
        for subCol in 0..<2 {
          for subRow in 0..<4 {
            let x = cellCol * 2 + subCol
            let y = cellRow * 4 + subRow
            guard self[x, y] else { continue }
            let bitIndex = subCol * 4 + subRow
            byte |= (1 << bitIndex)
          }
        }
        bytes.append(byte)
      }
    }

    return bytes.map { String(format: "%02X", $0) }.joined()
  }

  /// A distinctive "L" bracket — the entire top row plus the entire left
  /// column raised, everything else flat. Used to calibrate against real
  /// hardware: if this doesn't come out as an L in the top-left corner, that
  /// tells us exactly how `dotPadHexString()` needs to change.
  static func calibrationPattern(width: Int = 60, height: Int = 40) -> DotGrid {
    var dots = [Bool](repeating: false, count: width * height)
    for x in 0..<width { dots[x] = true }
    for y in 0..<height { dots[y * width] = true }
    return DotGrid(width: width, height: height, dots: dots)
  }
}
