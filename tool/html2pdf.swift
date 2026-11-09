// Prints an HTML file to a paginated A4 PDF with WebKit (macOS only).
//   swift tool/html2pdf.swift in.html out.pdf
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: html2pdf in.html out.pdf"); exit(2) }
let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])

final class Printer: NSObject, WKNavigationDelegate {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 794, height: 1123),
                        styleMask: [.borderless], backing: .buffered, defer: false)
  let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))

  func start() {
    window.contentView = web
    web.navigationDelegate = self
    web.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
  }

  func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.print() }
  }

  func print() {
    let info = NSPrintInfo()
    info.paperSize = NSSize(width: 595.28, height: 841.89) // A4
    info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 0; info.rightMargin = 0
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
    let op = web.printOperation(with: info)
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    op.view?.frame = web.bounds
    op.runModal(for: window, delegate: self, didRun: #selector(done(_:success:context:)), contextInfo: nil)
  }

  @objc func done(_ op: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
    exit(success ? 0 : 1)
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let p = Printer()
p.start()
app.run()
