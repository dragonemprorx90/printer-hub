import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  /// Menu-bar item showing print progress ("42% · 1h03"); set from Dart.
  private var statusItem: NSStatusItem?
  private var channel: FlutterMethodChannel?
  /// (key, name, line) per printer, from Dart's setMenu.
  private var printers: [(String, String, String)] = []
  /// The window, for the Dock menu (AppDelegate).
  static weak var main: MainFlutterWindow?

  /// Right-click the Dock icon: every printer, click to open it.
  func dockMenu() -> NSMenu {
    let menu = NSMenu()
    for p in printers {
      let item = NSMenuItem(title: p.2.isEmpty ? p.1 : "\(p.1) — \(p.2)", action: #selector(openPrinter(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = p.0
      menu.addItem(item)
    }
    return menu
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    MainFlutterWindow.main = self
    // Remember the window's size and place between launches.
    self.setFrameAutosaveName("PrinterHubMain")

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "printerhub/statusbar",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "activate":
        self?.showApp()
        result(nil)
      case "setTitle":
        self?.setStatus(call.arguments as? String ?? "")
        result(nil)
      case "setMenu":
        // [{key, name, line}], plus the number that need attention for the Dock badge.
        let args = call.arguments as? [String: Any] ?? [:]
        let list = args["printers"] as? [[String: String]] ?? []
        self?.printers = list.map { ($0["key"] ?? "", $0["name"] ?? "", $0["line"] ?? "") }
        let attention = args["attention"] as? Int ?? 0
        NSApp.dockTile.badgeLabel = attention > 0 ? "\(attention)" : nil
        self?.setStatus(self?.statusItem?.button?.title.trimmingCharacters(in: .whitespaces) ?? "")
        result(nil)
      case "setOnTop":
        // Float above other apps (camera on top while you work in Orca).
        self?.level = (call.arguments as? Bool ?? false) ? .floating : .normal
        result(nil)
      case "loginItem":
        result(Self.loginItemEnabled)
      case "setLoginItem":
        result(Self.setLoginItem(call.arguments as? Bool ?? false))
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  private func setStatus(_ text: String) {
    if statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.image = NSImage(
        systemSymbolName: "printer.fill", accessibilityDescription: "Printer Hub")
      item.button?.imagePosition = .imageLeading
      item.button?.toolTip = "Printer Hub"
      statusItem = item
    }
    statusItem?.button?.title = text.isEmpty ? "" : " \(text)"
    statusItem?.menu = buildMenu()
  }

  /// Every printer with its state; click one to open it.
  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    for (i, p) in printers.enumerated() {
      let item = NSMenuItem(
        title: p.2.isEmpty ? p.1 : "\(p.1) — \(p.2)", action: #selector(openPrinter(_:)),
        keyEquivalent: i < 9 ? "\(i + 1)" : "")
      item.target = self
      item.representedObject = p.0
      menu.addItem(item)
    }
    if !printers.isEmpty { menu.addItem(.separator()) }
    let open = NSMenuItem(title: "Open Printer Hub", action: #selector(showApp), keyEquivalent: "o")
    open.target = self
    menu.addItem(open)
    let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    login.target = self
    login.state = Self.loginItemEnabled ? .on : .off
    menu.addItem(login)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Printer Hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    return menu
  }

  @objc private func openPrinter(_ sender: NSMenuItem) {
    showApp()
    channel?.invokeMethod("openPrinter", arguments: sender.representedObject as? String)
  }

  @objc private func toggleLogin() {
    _ = Self.setLoginItem(!Self.loginItemEnabled)
    statusItem?.menu = buildMenu()
  }

  static var loginItemEnabled: Bool {
    if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
    return false
  }

  /// True when it worked (needs macOS 13).
  static func setLoginItem(_ on: Bool) -> Bool {
    guard #available(macOS 13.0, *) else { return false }
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      return true
    } catch {
      return false
    }
  }

  @objc private func showApp() {
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }
}
