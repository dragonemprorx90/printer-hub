import Flutter
import ObjectiveC
import UIKit

/// Home-screen quick actions, printerhub:// links and files opened with
/// Printer Hub ("Open in…") go to Dart over `printerhub/launch`. Whatever
/// arrives before Dart is listening waits in `pending`.
class SceneDelegate: FlutterSceneDelegate {
  static var pending: [String] = []
  private var channel: FlutterMethodChannel?

  private func superHas(_ sel: Selector) -> Bool {
    class_getInstanceMethod(FlutterSceneDelegate.self, sel) != nil
  }

  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if superHas(#selector(FlutterSceneDelegate.scene(_:willConnectTo:options:))) {
      super.scene(scene, willConnectTo: session, options: connectionOptions)
    }
    for c in connectionOptions.urlContexts { SceneDelegate.pending.append(Self.describe(c.url)) }
    if let item = connectionOptions.shortcutItem { SceneDelegate.pending.append(item.type) }
    DispatchQueue.main.async { self.attach() }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if superHas(#selector(FlutterSceneDelegate.scene(_:openURLContexts:))) {
      super.scene(scene, openURLContexts: URLContexts)
    }
    for c in URLContexts { deliver(Self.describe(c.url)) }
  }

  override func windowScene(
    _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    deliver(shortcutItem.type)
    completionHandler(true)
  }

  /// "file:/path" for a document (copied out of the inbox), else the link.
  private static func describe(_ url: URL) -> String {
    guard url.isFileURL else { return url.absoluteString }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
    try? FileManager.default.removeItem(at: dest)
    try? FileManager.default.copyItem(at: url, to: dest)
    return "file:" + dest.path
  }

  private func deliver(_ s: String) {
    attach()
    if let ch = channel {
      ch.invokeMethod("open", arguments: s)
    } else {
      SceneDelegate.pending.append(s)
    }
  }

  private func attach() {
    guard channel == nil, let vc = window?.rootViewController as? FlutterViewController else { return }
    let ch = FlutterMethodChannel(name: "printerhub/launch", binaryMessenger: vc.binaryMessenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "pending":
        result(SceneDelegate.pending)
        SceneDelegate.pending = []
      case "setShortcuts":
        let names = call.arguments as? [String] ?? []
        UIApplication.shared.shortcutItems =
          names.prefix(3).map {
            UIApplicationShortcutItem(
              type: "printerhub://printer/" + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0),
              localizedTitle: $0, localizedSubtitle: nil,
              icon: UIApplicationShortcutIcon(systemImageName: "printer.fill"))
          } + [
            UIApplicationShortcutItem(
              type: "printerhub://wall", localizedTitle: "Camera wall", localizedSubtitle: nil,
              icon: UIApplicationShortcutIcon(systemImageName: "square.grid.2x2"))
          ]
        result(nil)
      case "setNext":
        UserDefaults.standard.set(call.arguments as? String ?? "", forKey: "printerhub.next")
        result(nil)
      case "setStatus":
        // Read by the Shortcuts actions (PrinterIntents.swift).
        UserDefaults.standard.set(call.arguments as? String ?? "", forKey: "printerhub.status")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }
}

// MARK: Siri Shortcuts (read-only; nothing here sends anything to a printer)

import AppIntents

@available(iOS 16.0, *)
struct PrinterStatusIntent: AppIntent {
  static var title: LocalizedStringResource = "Printer status"
  static var description = IntentDescription("What each printer is doing, as Printer Hub last saw it.")

  func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
    let s = UserDefaults.standard.string(forKey: "printerhub.status") ?? ""
    let text = s.isEmpty ? "Open Printer Hub once so it can see your printers." : s
    return .result(value: text, dialog: IntentDialog(stringLiteral: text))
  }
}

@available(iOS 16.0, *)
struct TimeLeftIntent: AppIntent {
  static var title: LocalizedStringResource = "Time left"
  static var description = IntentDescription("When the next print finishes.")

  func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
    let s = UserDefaults.standard.string(forKey: "printerhub.next") ?? ""
    let text = s.isEmpty ? "Nothing is printing." : s
    return .result(value: text, dialog: IntentDialog(stringLiteral: text))
  }
}

@available(iOS 16.0, *)
struct OpenWallIntent: AppIntent {
  static var title: LocalizedStringResource = "Open camera wall"
  static var openAppWhenRun = true
  func perform() async throws -> some IntentResult {
    SceneDelegate.pending.append("printerhub://wall")
    return .result()
  }
}

@available(iOS 16.0, *)
struct PrinterHubShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PrinterStatusIntent(),
      phrases: ["Printer status in \(.applicationName)", "How are my prints in \(.applicationName)"],
      shortTitle: "Printer status", systemImageName: "printer.fill")
    AppShortcut(
      intent: TimeLeftIntent(), phrases: ["Time left in \(.applicationName)", "When is my print done in \(.applicationName)"],
      shortTitle: "Time left", systemImageName: "clock")
    AppShortcut(
      intent: OpenWallIntent(), phrases: ["Open the camera wall in \(.applicationName)"],
      shortTitle: "Camera wall", systemImageName: "square.grid.2x2")
  }
}
