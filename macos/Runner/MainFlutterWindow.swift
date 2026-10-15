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

    // System Now Playing / media keys. Dart (lib/features/nowplaying)
    // owns playback state; this only mirrors it and forwards commands.
    NowPlayingBridge.shared.attach(
      messenger: flutterViewController.engine.binaryMessenger)

    // The material above resolves against this window's effective
    // appearance, which by default is the *macOS system* appearance, not
    // the app's own Pearl/Midnight choice. Dart (lib/app/window.dart) pins
    // the window appearance through this channel so the sidebar material,
    // traffic lights and other native chrome track the in-app theme.
    let appearanceChannel = FlutterMethodChannel(
      name: "lastwave/window_appearance",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    appearanceChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setAppearance" else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.arguments as? String {
      case "light":
        self?.appearance = NSAppearance(named: .aqua)
      case "dark":
        self?.appearance = NSAppearance(named: .darkAqua)
      default:
        // nil = follow the system appearance again.
        self?.appearance = nil
      }
      result(nil)
    }

    super.awakeFromNib()
  }
}
