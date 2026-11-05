import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Menu-bar item showing print progress ("42% · 1h03"); set from Dart.
  private var statusItem: NSStatusItem?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "printerhub/statusbar",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setTitle" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.setStatus(call.arguments as? String ?? "")
      result(nil)
    }

    super.awakeFromNib()
  }

  private func setStatus(_ text: String) {
    if statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.image = NSImage(
        systemSymbolName: "printer.fill", accessibilityDescription: "Printer Hub")
      item.button?.imagePosition = .imageLeading
      item.button?.target = self
      item.button?.action = #selector(showApp)
      item.button?.toolTip = "Printer Hub"
      statusItem = item
    }
    statusItem?.button?.title = text.isEmpty ? "" : " \(text)"
  }

  @objc private func showApp() {
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }
}
