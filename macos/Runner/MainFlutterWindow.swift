import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var pendingHostFolderResult: FlutterResult?
  private var securityScopedHostFolderURL: URL?

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
      case "restoreHostFolderAccess":
        self.restoreHostFolderAccess(call: call, result: result)
      case "releaseHostFolderAccess":
        self.releaseHostFolderAccess()
        result(nil)
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
      do {
        let bookmarkData = try url.bookmarkData(
          options: .withSecurityScope,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        guard self.beginAccessingHostFolder(url) else {
          pending?(
            FlutterError(
              code: "HOST_FOLDER_ACCESS_DENIED",
              message: "macOS did not grant access to the selected folder.",
              details: nil
            )
          )
          return
        }
        pending?(self.hostFolderPayload(url: url, bookmarkData: bookmarkData))
      } catch {
        pending?(
          FlutterError(
            code: "HOST_FOLDER_BOOKMARK_FAILED",
            message: "Could not save permission for the selected folder.",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  private func restoreHostFolderAccess(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let encodedBookmark = arguments["bookmark"] as? String,
      let bookmarkData = Data(base64Encoded: encodedBookmark)
    else {
      result(
        FlutterError(
          code: "HOST_FOLDER_BOOKMARK_MISSING",
          message: "The saved folder permission is missing or invalid.",
          details: nil
        )
      )
      return
    }

    do {
      var bookmarkIsStale = false
      let url = try URL(
        resolvingBookmarkData: bookmarkData,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &bookmarkIsStale
      )
      guard beginAccessingHostFolder(url) else {
        result(
          FlutterError(
            code: "HOST_FOLDER_ACCESS_DENIED",
            message: "Access to the saved Drop folder has expired. Select it again.",
            details: nil
          )
        )
        return
      }

      let currentBookmarkData: Data
      if bookmarkIsStale {
        currentBookmarkData = try url.bookmarkData(
          options: .withSecurityScope,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
      } else {
        currentBookmarkData = bookmarkData
      }
      result(hostFolderPayload(url: url, bookmarkData: currentBookmarkData))
    } catch {
      releaseHostFolderAccess()
      result(
        FlutterError(
          code: "HOST_FOLDER_BOOKMARK_FAILED",
          message: "Could not restore access to the saved Drop folder. Select it again.",
          details: error.localizedDescription
        )
      )
    }
  }

  private func beginAccessingHostFolder(_ url: URL) -> Bool {
    releaseHostFolderAccess()
    guard url.startAccessingSecurityScopedResource() else {
      return false
    }
    securityScopedHostFolderURL = url
    return true
  }

  private func releaseHostFolderAccess() {
    securityScopedHostFolderURL?.stopAccessingSecurityScopedResource()
    securityScopedHostFolderURL = nil
  }

  private func hostFolderPayload(url: URL, bookmarkData: Data) -> [String: Any] {
    let name = url.lastPathComponent.isEmpty ? "Selected folder" : url.lastPathComponent
    return [
      "uri": url.absoluteString,
      "name": name,
      "platform": "macOS",
      "bookmark": bookmarkData.base64EncodedString(),
    ]
  }
}
