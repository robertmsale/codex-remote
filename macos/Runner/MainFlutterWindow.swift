import Cocoa
import FlutterMacOS
import desktop_multi_window
import ObjectiveC.runtime

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    FieldExecPasteBridge.install()

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
    }

    super.awakeFromNib()
  }
}

private enum FieldExecPasteBridge {
  private static var didInstall = false
  private static let channelName = "field_exec/paste"

  static func install() {
    if didInstall { return }
    didInstall = true
    swizzlePasteOnNSWindow()
  }

  private static func swizzlePasteOnNSWindow() {
    let originalSelector = #selector(NSResponder.paste(_:))
    let swizzledSelector = #selector(NSWindow.fieldExec_paste(_:))

    guard
      let originalMethod = class_getInstanceMethod(NSWindow.self, originalSelector),
      let swizzledMethod = class_getInstanceMethod(NSWindow.self, swizzledSelector)
    else {
      return
    }

    method_exchangeImplementations(originalMethod, swizzledMethod)
  }

  fileprivate static func handlePaste(window: NSWindow) {
    let pasteboard = NSPasteboard.general
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
    guard let controller = window.contentViewController as? FlutterViewController else { return }

    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.invokeMethod("pasteText", arguments: ["text": text])
  }
}

extension NSWindow {
  @objc func fieldExec_paste(_ sender: Any?) {
    FieldExecPasteBridge.handlePaste(window: self)

    // Call the original implementation (which is now swapped).
    self.fieldExec_paste(sender)
  }
}
