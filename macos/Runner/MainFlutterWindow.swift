import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Make the title bar transparent so Flutter can draw under it,
    // while keeping the native traffic lights.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    // Add native vibrancy view
    let visualEffectView = NSVisualEffectView(frame: flutterViewController.view.bounds)
    visualEffectView.autoresizingMask = [.width, .height]
    visualEffectView.material = .sidebar
    visualEffectView.blendingMode = .behindWindow
    visualEffectView.state = .active

    // Add it underneath the flutter view
    if let contentView = self.contentView {
        contentView.addSubview(visualEffectView, positioned: .below, relativeTo: flutterViewController.view)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
