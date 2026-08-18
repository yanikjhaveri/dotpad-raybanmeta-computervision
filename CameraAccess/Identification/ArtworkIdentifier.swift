import UIKit

enum ArtworkIdentifierError: Error {
  case missingAPIKey
  case invalidResponse
  case apiError(String)
}

/// Identifies a painting or sculpture from a photo and produces both a
/// spoken-ready description and a simplified geometric "shapes" breakdown for
/// the tactile display, using the Claude API's vision input. Swift has no
/// official Anthropic SDK, so this talks to the Messages API directly over
/// HTTPS.
///
/// The shapes come from what Claude *knows* about the piece, not from pixel
/// analysis of this specific (likely imperfect — glare, screen reproduction,
/// odd angle) photo — a local CV pipeline (`ContourDotExtractor`, still in
/// the project but no longer wired up) was tried first and produced mostly
/// noise (browser chrome, text fragments) instead of a recognizable subject.
final class ArtworkIdentifier {
  private let apiKey: String
  private let model = "claude-opus-5"

  private static let systemPrompt = """
    You are an audio and tactile guide for a blind museum visitor wearing smart \
    glasses. Every photo you receive shows a painting or sculpture the wearer is \
    standing in front of — even if the photo itself is imperfect (glare, an odd \
    angle, a screen reproduction during testing), always treat it as the artwork \
    it is, never as a literal scene. A painting of a person is a painting, not a \
    person.

    Respond with ONLY a single JSON object — no markdown fences, no commentary \
    before or after — matching exactly this shape:

    {
      "description": string,
      "category": "painting_or_photograph" | "sculpture_or_artifact" | \
    "pattern_or_textile" | "architecture" | "other",
      "shapes": [
        { "type": "circle" | "ellipse" | "triangle" | "rectangle" | "line",
          "x": number, "y": number, "width": number, "height": number,
          "rotationDegrees": number }
      ]
    }

    For "category": pick "pattern_or_textile" for tiling, mosaics, rugs, \
    wallpaper, or any decorative surface whose content is a repeating motif \
    rather than a single subject — this changes how the tactile display \
    renders it (a direct pixel pattern instead of shapes), so get this right. \
    Otherwise pick whichever of the other categories best fits.

    For "description": keep it to about 30 seconds of spoken audio — roughly 80 \
    words, never more. Prioritize in this order: what the work depicts, the \
    artist and the artistic tradition or movement they worked in (if known), and \
    one piece of historical context — when or why it was made, or what makes it \
    significant. Cut visual detail before you cut historical or artistic context. \
    If you recognize the specific work, name it and its artist first. If you \
    don't, skip the name and describe the artwork itself instead — its subject, \
    medium, and apparent style or tradition. Write it as plain prose ready to be \
    read aloud by a text-to-speech engine — no headers, no preamble like "This \
    is" or "I can see".

    For "shapes": reconstruct the artwork's most recognizable silhouette from \
    what you know about the piece itself, not from tracing this specific photo's \
    pixels. If you recognize the work, draw its iconic composition — for example \
    the Great Pyramid of Giza is one large triangle for the main pyramid, a \
    smaller triangle beside it for a companion pyramid, and a low flat rectangle \
    for the sand it sits on. If you don't recognize the specific work, \
    approximate its general composition instead — e.g. a standing figure is an \
    ellipse for the head over a tall rectangle for the body. Use 3 to 8 shapes: \
    enough to be recognizable, few enough to stay legible as raised dots on a \
    low-resolution tactile display. x/y are each shape's CENTER, normalized \
    0...1 with (0,0) at the top-left of the frame and (1,1) at the bottom-right; \
    width/height are normalized to that same frame. Keep every shape within \
    0...1. If "category" is "pattern_or_textile", the shapes are unused — \
    return an empty array for "shapes" rather than spending effort on it.
    """

  init() throws {
    guard Secrets.anthropicAPIKey.hasPrefix("sk-ant-") else {
      throw ArtworkIdentifierError.missingAPIKey
    }
    self.apiKey = Secrets.anthropicAPIKey
  }

  func identify(image: UIImage) async throws -> ArtworkShapeScene {
    guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
      throw ArtworkIdentifierError.invalidResponse
    }
    let base64Image = jpegData.base64EncodedString()

    let body: [String: Any] = [
      "model": model,
      "max_tokens": 900,
      "system": Self.systemPrompt,
      "output_config": ["effort": "medium"],
      "messages": [
        [
          "role": "user",
          "content": [
            [
              "type": "image",
              "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": base64Image,
              ],
            ],
            [
              "type": "text",
              "text": "What is this artwork?",
            ],
          ],
        ]
      ],
    ]

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw ArtworkIdentifierError.apiError(message)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let content = json["content"] as? [[String: Any]]
    else {
      throw ArtworkIdentifierError.invalidResponse
    }

    let text = content
      .compactMap { block -> String? in
        guard block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
      }
      .joined(separator: " ")

    guard !text.isEmpty else { throw ArtworkIdentifierError.invalidResponse }

    // Claude is instructed to return raw JSON, but defensively strip a
    // ```json ... ``` fence in case it wraps the response anyway.
    var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonText.hasPrefix("```") {
      jsonText = jsonText
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard let jsonData = jsonText.data(using: .utf8) else {
      throw ArtworkIdentifierError.invalidResponse
    }
    do {
      return try JSONDecoder().decode(ArtworkShapeScene.self, from: jsonData)
    } catch {
      print("🟠 ArtworkIdentifier: failed to decode shape scene (\(error)). Raw text: \(jsonText)")
      throw ArtworkIdentifierError.invalidResponse
    }
  }
}
