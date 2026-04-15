import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
