import Foundation

/// Claude's response to an identification request: the spoken description,
/// a coarse category used to choose *how* to render the tactile output, and
/// (for representational subjects) a simplified geometric breakdown built
/// from what Claude knows about the piece rather than derived from pixel
/// analysis of a (likely imperfect) photo of it.
struct ArtworkShapeScene: Decodable {
  /// Drives the tactile rendering strategy: representational subjects (a
  /// painting's figure, a sculpture's silhouette) read better as a handful
  /// of AI-abstracted shapes, since a fingertip needs the *idea* of the
  /// subject, not literal pixels. Repeating patterns are the opposite — the
  /// content *is* the repeating micro-structure (tiling, weave), which shape
  /// abstraction destroys (Claude can't describe a tessellation as 3-8
  /// shapes) but a plain pixel-threshold downsample reproduces directly.
  /// Confirmed empirically: AI shapes clearly win on paintings/sculptures/
  /// architecture, pixel-threshold clearly wins on tiling patterns.
  enum Category: String, Decodable {
    case paintingOrPhotograph = "painting_or_photograph"
    case sculptureOrArtifact = "sculpture_or_artifact"
    case patternOrTextile = "pattern_or_textile"
    case architecture
    case other
  }

  let description: String
  let category: Category
  let shapes: [ArtworkShape]
}

/// One elementary shape in the simplified diagram — e.g. "a triangle" for a
/// pyramid, "a circle" for a moon. Position/size are normalized 0...1
/// relative to the photo Claude was shown (0,0 = top-left, 1,1 = bottom-right).
struct ArtworkShape: Decodable {
  enum Kind: String, Decodable {
    case circle, ellipse, triangle, rectangle, line
  }

  let type: Kind
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  let rotationDegrees: Double
}
