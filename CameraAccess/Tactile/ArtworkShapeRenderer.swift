import UIKit

/// Renders a Claude-described shape scene as black outlines on white, ready
/// to feed into `DotGridConverter.convertThresholded`. Shapes are stroked,
/// not filled — a fingertip needs a traceable line, not a filled blob, and
/// filled shapes also fuse together into a solid black mass as soon as a
/// scene has more than one or two overlapping shapes (busy compositions like
/// a branch full of blossoms), which made every complex painting come out as
/// a nearly solid black square.
/// `canvasSize` should match the source photo's aspect ratio — the shapes'
/// x/y/width/height are normalized relative to that photo, so a mismatched
/// canvas would stretch circles into ellipses etc.
enum ArtworkShapeRenderer {
  static func render(_ shapes: [ArtworkShape], canvasSize: CGSize) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: canvasSize)
    // Thick enough to survive the later downsample to a 60x40 dot grid
    // (roughly a 5x reduction from a 300x200 canvas) as at least one dot.
    let strokeWidth = max(4, canvasSize.width * 0.02)

    return renderer.image { ctx in
      UIColor.white.setFill()
      ctx.fill(CGRect(origin: .zero, size: canvasSize))
      UIColor.black.setStroke()
      ctx.cgContext.setLineWidth(strokeWidth)

      for shape in shapes {
        let center = CGPoint(x: shape.x * canvasSize.width, y: shape.y * canvasSize.height)
        let size = CGSize(width: shape.width * canvasSize.width, height: shape.height * canvasSize.height)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)

        ctx.cgContext.saveGState()
        ctx.cgContext.translateBy(x: center.x, y: center.y)
        ctx.cgContext.rotate(by: shape.rotationDegrees * .pi / 180)
        ctx.cgContext.translateBy(x: -center.x, y: -center.y)

        switch shape.type {
        case .circle, .ellipse:
          ctx.cgContext.strokeEllipse(in: rect)

        case .rectangle:
          ctx.cgContext.stroke(rect)

        case .triangle:
          let path = CGMutablePath()
          path.move(to: CGPoint(x: center.x, y: rect.minY))
          path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
          path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
          path.closeSubpath()
          ctx.cgContext.addPath(path)
          ctx.cgContext.strokePath()

        case .line:
          ctx.cgContext.move(to: CGPoint(x: rect.minX, y: center.y))
          ctx.cgContext.addLine(to: CGPoint(x: rect.maxX, y: center.y))
          ctx.cgContext.strokePath()
        }

        ctx.cgContext.restoreGState()
      }
    }
  }
}
