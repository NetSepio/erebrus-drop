import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var pendingHostFolderResult: FlutterResult?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "com.erebrus.drop/network",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        return
      }
      switch call.method {
      case "selectHostFolder":
        self.selectHostFolder(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  private func selectHostFolder(result: @escaping FlutterResult) {
    if pendingHostFolderResult != nil {
      result(
        FlutterError(
          code: "PICK_IN_PROGRESS",
          message: "A folder picker is already open.",
          details: nil
        )
      )
      return
    }
    pendingHostFolderResult = result
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        return
      }
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.prompt = "Select Drop Folder"
      panel.message = "Choose a folder to host shared files."
      let response = panel.runModal()
      let pending = self.pendingHostFolderResult
      self.pendingHostFolderResult = nil
      guard response == .OK, let url = panel.url else {
        pending?(nil)
        return
      }
      let name = url.lastPathComponent.isEmpty ? "Selected folder" : url.lastPathComponent
      pending?([
        "uri": url.absoluteString,
        "name": name,
        "platform": "macOS",
      ])
    }
  }
}