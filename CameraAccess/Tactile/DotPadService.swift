import DotPadFrameworks
import Observation

/// Thin wrapper around the DotPad SDK: scans for and auto-connects to a
/// nearby DotPad320, and pushes `DotGrid` data to its tactile graphic display.
@MainActor
@Observable
final class DotPadService: NSObject {
  private(set) var statusText = "DotPad: not connected"
  private(set) var isConnected = false

  @ObservationIgnored private var isGraphicDisplay = false
  @ObservationIgnored private let api = DotPadFrameworks.DotPadAPI()
  // Auto-connect to the first discovered device whose name contains this —
  // avoids needing a device picker UI for a single expected pad.
  @ObservationIgnored private let targetNameSubstring = "DotPad"

  override init() {
    super.init()
    api.setCallBack(dotDeviceMessage: self)
  }

  func startScan() {
    print("🔵 DotPadService: startScan() called")
    statusText = "DotPad: scanning…"
    api.dotPadDeviceScan(isScan: true)
    print("🔵 DotPadService: dotPadDeviceScan(isScan: true) returned")
  }

  func disconnect() {
    api.dotPadDisconnect()
    api.dotPadDeviceScan(isScan: false)
  }

  /// Sends a dot grid to the display. No-ops (with a log line) if not
  /// connected to a graphic-capable device, rather than crashing.
  func send(_ grid: DotGrid) {
    guard isConnected, isGraphicDisplay else {
      print("🟡 DotPadService: not connected to a graphic-capable device, skipping send")
      return
    }
    let hex = grid.dotPadHexString()
    print("🟪 DotPadService: sending \(hex.count / 2)-byte graphic frame")
    api.displayGraphicData(data: hex)
  }

  /// Sends the calibration "L" pattern — see `DotGrid.calibrationPattern()`.
  func sendCalibrationPattern() {
    send(DotGrid.calibrationPattern())
  }
}

extension DotPadService: DotPadFrameworks.DotDeviceMessage {
  nonisolated func receivedMessageCallBack(_ dataCode: DotPadFrameworks.DataCodes, _ msg: String) {
    print("🔵 DotPadService: receivedMessageCallBack dataCode=\(dataCode) msg=\"\(msg)\"")
    Task { @MainActor in
      switch dataCode {
      case .Discovery_List:
        let discoveries = self.api.getDeviceFiltered()
        print("🔵 DotPadService: Discovery_List, \(discoveries.count) device(s): \(discoveries.map { $0.localName ?? "(no name)" })")
        if let match = discoveries.first(where: { ($0.localName ?? "").contains(self.targetNameSubstring) }) {
          self.statusText = "DotPad: found \(match.localName ?? "device"), connecting…"
          self.api.connectDevice(peripheral: match.remotePeripheral)
        } else {
          self.statusText = "DotPad: scanning… (\(discoveries.count) BLE device(s) seen, none named DotPad yet)"
        }

      case .Connected:
        self.isConnected = true
        self.statusText = "DotPad: connected, checking device type…"
        // Mirrors the SDK's own demo app — give the device a moment to finish
        // its own init before asking for its name.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        self.api.requestDeviceName()

      case .Disconnected:
        self.isConnected = false
        self.isGraphicDisplay = false
        self.statusText = "DotPad: disconnected"

      case .DeviceName:
        self.isGraphicDisplay = msg.contains("DotPad320")
        self.statusText = self.isGraphicDisplay
          ? "DotPad: connected (\(msg))"
          : "DotPad: connected to \(msg) — no graphic display"

      default:
        break
      }
    }
  }

  nonisolated func receivedKeyCallBack(_ keyCode: DotPadFrameworks.KeyCodes, _ msg: String) {
    // Not used yet — DotPad's own physical keys aren't wired to anything here.
  }

  nonisolated func onKeyDown(key: DotPadFrameworks.DotPadKey, dotKeyBinary: String) {}
  nonisolated func onKeyUp(key: DotPadFrameworks.DotPadKey, dotKeyBinary: String) {}
}
