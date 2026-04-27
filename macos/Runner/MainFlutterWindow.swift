import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let trafficLightOffset = NSPoint(x: 12, y: -8)
  private var trafficLightButtonOrigins: [String: NSPoint] = [:]

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 980, height: 680)
    if self.frame.size.width < 1080 || self.frame.size.height < 720 {
      self.setContentSize(NSSize(width: 1180, height: 780))
      self.center()
    }

    // Hide the native title bar so Flutter can render a custom Mac header area.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.isMovableByWindowBackground = true
    self.title = ""
    self.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1.0)

    DispatchQueue.main.async { [weak self] in
      self?.repositionTrafficLightButtons()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private func repositionTrafficLightButtons() {
    let buttonTypes: [NSWindow.ButtonType] = [
      .closeButton,
      .miniaturizeButton,
      .zoomButton,
    ]

    for buttonType in buttonTypes {
      guard let button = standardWindowButton(buttonType) else {
        continue
      }

      let key = trafficLightButtonKey(for: buttonType)
      let baseOrigin = trafficLightButtonOrigins[key] ?? button.frame.origin
      trafficLightButtonOrigins[key] = baseOrigin
      button.setFrameOrigin(NSPoint(
        x: baseOrigin.x + trafficLightOffset.x,
        y: baseOrigin.y + trafficLightOffset.y
      ))
    }
  }

  private func trafficLightButtonKey(for buttonType: NSWindow.ButtonType) -> String {
    switch buttonType {
    case .closeButton:
      return "close"
    case .miniaturizeButton:
      return "miniaturize"
    case .zoomButton:
      return "zoom"
    default:
      return "other"
    }
  }
}
