import CoreML
import Vision
import os

enum ObjectDetectorError: Error {
  case modelNotFound
}

/// Runs YOLOv8 object detection on decoded video frames. Thread-safe — call
/// `detectIfDue(cgImage:)` from any thread. Internally throttles and drops
/// overlapping requests so inference never backs up behind the ~24fps preview.
final class ObjectDetector: @unchecked Sendable {
  private let visionModel: VNCoreMLModel
  private let confidenceThreshold: Float = 0.4

  private struct ThrottleState {
    var frameIndex = 0
    var isBusy = false
  }
  private let state = OSAllocatedUnfairLock(uncheckedState: ThrottleState())
  /// Run inference on every Nth decoded frame — plenty for a live overlay, and keeps
  /// the Neural Engine free for the video decoder running alongside it.
  private let frameStride = 6

  init() throws {
    guard let modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") else {
      throw ObjectDetectorError.modelNotFound
    }
    let mlModel = try MLModel(contentsOf: modelURL)
    self.visionModel = try VNCoreMLModel(for: mlModel)
  }

  /// Returns `nil` on throttled/skipped frames (including one already in flight) so
  /// the caller can leave the previous overlay on screen rather than clearing it.
  func detectIfDue(cgImage: CGImage) -> [DetectedObject]? {
    let shouldRun = state.withLockUnchecked { s -> Bool in
      s.frameIndex += 1
      guard !s.isBusy, s.frameIndex % frameStride == 0 else { return false }
      s.isBusy = true
      return true
    }
    guard shouldRun else { return nil }
    defer { state.withLockUnchecked { $0.isBusy = false } }

    let request = VNCoreMLRequest(model: visionModel)
    request.imageCropAndScaleOption = .scaleFill

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return []
    }

    guard let results = request.results as? [VNRecognizedObjectObservation] else { return [] }
    return results.compactMap { observation in
      guard let top = observation.labels.first, top.confidence >= confidenceThreshold else { return nil }
      // Vision's boundingBox has origin bottom-left; flip to top-left for SwiftUI.
      let bb = observation.boundingBox
      let flipped = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
      return DetectedObject(label: top.identifier, confidence: top.confidence, boundingBox: flipped)
    }
  }
}
