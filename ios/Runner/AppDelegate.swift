import Flutter
import AVFoundation
import Darwin
import Foundation
import QuickLook
import UniformTypeIdentifiers
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate, UIDocumentInteractionControllerDelegate, QLPreviewControllerDataSource, QLPreviewControllerDelegate, NetServiceBrowserDelegate, NetServiceDelegate {
  private var publishedService: NetService?
  private var discoveryBrowser: NetServiceBrowser?
  private var discoveryResult: FlutterResult?
  private var discoveryTimer: Timer?
  private var discoveryServices: [NetService] = []
  private var discoveredRooms: [String: [String: Any]] = [:]
  private var pendingHostFolderResult: FlutterResult?
  private var pendingUploadPickResult: FlutterResult?
  private var pendingQrScanResult: FlutterResult?
  private var documentInteractionController: UIDocumentInteractionController?
  private var quickLookPreviewURL: URL?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ErebrusDropNetwork") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.erebrus.drop/network",
      binaryMessenger: registrar.messenger()
    )
    let qrScannerChannel = FlutterMethodChannel(
      name: "com.erebrus.drop/qr_scanner",
      binaryMessenger: registrar.messenger()
    )
    qrScannerChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "scanQrCode":
        self.scanQrCode(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getDeviceName":
        result(UIDevice.current.name)
      case "getLocalIpAddresses":
        result(Self.localIpAddresses())
      case "getStorageStats":
        result(Self.storageStats())
      case "isLocalOnlyHotspotSupported":
        result([
          "supported": false,
          "reason": "Use shared Wi-Fi, or enable Personal Hotspot from iPhone Settings when needed."
        ])
      case "startLocalOnlyHotspot":
        result([
          "supported": false,
          "started": false,
          "reason": "Enable Personal Hotspot from iPhone Settings, connect guests, then return to Erebrus Drop."
        ])
      case "stopLocalOnlyHotspot":
        result(["stopped": true])
      case "pickFileForUpload", "pickFilesForUpload":
        self.pickFilesForUpload(result: result)
      case "consumeSharedPayload":
        self.consumeSharedPayload(result: result)
      case "selectHostFolder":
        self.selectHostFolder(result: result)
      case "syncShareIntakeHostFolder":
        self.syncShareIntakeHostFolder(call: call, result: result)
      case "clearShareIntakeHostFolder":
        self.clearShareIntakeHostFolder(result: result)
      case "listHostFolder":
        self.listHostFolder(call: call, result: result)
      case "copyFileIntoHostFolder":
        self.copyFileIntoHostFolder(call: call, result: result)
      case "createHostFolder":
        self.createHostFolder(call: call, result: result)
      case "copyHostFileToCache":
        self.copyHostFileToCache(call: call, result: result)
      case "openHostFile":
        self.openHostFile(call: call, result: result)
      case "shareHostFile":
        self.shareHostFile(call: call, result: result)
      case "deleteHostFile":
        self.deleteHostFile(call: call, result: result)
      case "renameHostItem":
        self.renameHostItem(call: call, result: result)
      case "moveHostItem":
        self.moveHostItem(call: call, result: result)
      case "openLocalFile":
        self.openLocalFile(call: call, result: result)
      case "shareLocalFile":
        self.shareLocalFile(call: call, result: result)
      case "saveFileToDownloads":
        self.saveFileToDownloads(call: call, result: result)
      case "publishMdnsService":
        self.publishMdnsService(call: call, result: result)
      case "stopMdnsService":
        self.stopMdnsService()
        result(["stopped": true])
      case "discoverMdnsRooms":
        self.discoverMdnsRooms(call: call, result: result)
      case "startRoomForegroundService":
        result(["started": false, "reason": "Foreground hosting service is Android-only."])
      case "stopRoomForegroundService":
        result(["stopped": true])
      case "setRoomKeepAwake":
        let enabled = call.arguments as? [String: Any]
        UIApplication.shared.isIdleTimerDisabled = enabled?["enabled"] as? Bool ?? false
        result(["enabled": UIApplication.shared.isIdleTimerDisabled])
      case "moveAppToBackground":
        result(["backgrounded": false, "reason": "Programmatic backgrounding is Android-only."])
      case "getCurrentNetworkInfo":
        result(["interface": "local-network"])
      case "checkLocalNetworkPermission":
        result(["allowed": true, "reason": "iOS prompts when local network access is first used"])
      case "openPersonalHotspotSettingsGuide":
        result([
          "supported": false,
          "reason": "Enable Personal Hotspot from iPhone Settings, connect guests, then return to Erebrus Drop."
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func scanQrCode(result: @escaping FlutterResult) {
    if pendingQrScanResult != nil {
      result(FlutterError(
        code: "SCAN_IN_PROGRESS",
        message: "A QR scanner is already open.",
        details: nil
      ))
      return
    }
    pendingQrScanResult = result
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      presentQrScanner()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { allowed in
        DispatchQueue.main.async {
          if allowed {
            self.presentQrScanner()
          } else {
            self.finishQrScan(errorCode: "CAMERA_PERMISSION_DENIED", message: "Camera permission is required to scan a Drop Code.")
          }
        }
      }
    default:
      finishQrScan(errorCode: "CAMERA_PERMISSION_DENIED", message: "Camera permission is required to scan a Drop Code.")
    }
  }

  private func presentQrScanner() {
    guard let presenter = topViewController() else {
      finishQrScan(errorCode: "CAMERA_UNAVAILABLE", message: "The camera scanner could not start on this device.")
      return
    }
    let scanner = NativeQrScannerViewController()
    scanner.modalPresentationStyle = .fullScreen
    scanner.onFinish = { [weak self] code in
      self?.finishQrScan(code: code)
    }
    presenter.present(scanner, animated: true)
  }

  private func finishQrScan(code: String? = nil, errorCode: String? = nil, message: String? = nil) {
    guard let result = pendingQrScanResult else {
      return
    }
    pendingQrScanResult = nil
    if let errorCode {
      result(FlutterError(code: errorCode, message: message, details: nil))
      return
    }
    result(code)
  }

  private func consumeSharedPayload(result: FlutterResult) {
    let appGroupId = "group.com.erebrus.drop"
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
      result(nil)
      return
    }
    let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
    let manifest = inbox.appendingPathComponent("pending-share.json")
    guard FileManager.default.fileExists(atPath: manifest.path) else {
      result(nil)
      return
    }
    do {
      let data = try Data(contentsOf: manifest)
      let decoded = try JSONSerialization.jsonObject(with: data)
      try? FileManager.default.removeItem(at: manifest)
      result(decoded)
    } catch {
      result(FlutterError(
        code: "SHARE_INTAKE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    handlePickedDocuments(urls)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentAt url: URL
  ) {
    handlePickedDocuments([url])
  }

  private func handlePickedDocuments(_ urls: [URL]) {
    if let result = pendingUploadPickResult {
      pendingUploadPickResult = nil
      do {
        result(try urls.map(copyPickedFile))
      } catch {
        result(FlutterError(
          code: "PICK_FILE_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
      }
      return
    }
    guard let result = pendingHostFolderResult else {
      return
    }
    pendingHostFolderResult = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    let didStart = url.startAccessingSecurityScopedResource()
    defer {
      if didStart {
        url.stopAccessingSecurityScopedResource()
      }
    }
    do {
      let bookmark = try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      let selection: [String: Any] = [
        "uri": "ios-bookmark:\(bookmark.base64EncodedString())",
        "name": url.lastPathComponent.isEmpty ? "Selected folder" : url.lastPathComponent,
        "platform": "iOS Files"
      ]
      try? writeShareIntakeHostFolder(selection)
      result(selection)
    } catch {
      result(FlutterError(
        code: "PICK_FOLDER_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingUploadPickResult?(nil)
    pendingUploadPickResult = nil
    pendingHostFolderResult?(nil)
    pendingHostFolderResult = nil
  }

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    return topViewController() ?? UIViewController()
  }

  func documentInteractionControllerDidEndPreview(
    _ controller: UIDocumentInteractionController
  ) {
    if documentInteractionController === controller {
      documentInteractionController = nil
    }
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    return quickLookPreviewURL == nil ? 0 : 1
  }

  func previewController(
    _ controller: QLPreviewController,
    previewItemAt index: Int
  ) -> QLPreviewItem {
    return quickLookPreviewURL! as NSURL
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    quickLookPreviewURL = nil
  }

  private func selectHostFolder(result: @escaping FlutterResult) {
    if pendingHostFolderResult != nil || pendingUploadPickResult != nil {
      result(FlutterError(
        code: "PICK_IN_PROGRESS",
        message: "A folder picker is already open.",
        details: nil
      ))
      return
    }
    guard let presenter = topViewController() else {
      result(FlutterError(
        code: "PICK_FOLDER_UNAVAILABLE",
        message: "Could not present the Files folder picker.",
        details: nil
      ))
      return
    }
    pendingHostFolderResult = result
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [.folder],
        asCopy: false
      )
    } else {
      picker = UIDocumentPickerViewController(
        documentTypes: ["public.folder"],
        in: .open
      )
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  private func pickFilesForUpload(result: @escaping FlutterResult) {
    if pendingHostFolderResult != nil || pendingUploadPickResult != nil {
      result(FlutterError(
        code: "PICK_IN_PROGRESS",
        message: "A file picker is already open.",
        details: nil
      ))
      return
    }
    guard let presenter = topViewController() else {
      result(FlutterError(
        code: "PICK_FILE_UNAVAILABLE",
        message: "Could not present the Files picker.",
        details: nil
      ))
      return
    }
    pendingUploadPickResult = result
    let picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .import)
    picker.delegate = self
    picker.allowsMultipleSelection = true
    presenter.present(picker, animated: true)
  }

  private func listHostFolder(call: FlutterMethodCall, result: FlutterResult) {
    do {
      let arguments = try hostFolderArguments(call)
      let items = try withScopedFolder(rootUri: arguments.rootUri) { root in
        let folder = hostURL(root: root, path: arguments.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
          throw HostFolderError.message("Folder not found: \(arguments.path)")
        }
        let urls = try FileManager.default.contentsOfDirectory(
          at: folder,
          includingPropertiesForKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey
          ],
          options: [.skipsHiddenFiles]
        )
        return urls
          .map { hostFileMap(root: root, url: $0) }
          .sorted { lhs, rhs in
            let leftFolder = lhs["type"] as? String == "folder"
            let rightFolder = rhs["type"] as? String == "folder"
            if leftFolder != rightFolder {
              return leftFolder
            }
            return (lhs["name"] as? String ?? "").localizedCaseInsensitiveCompare(
              rhs["name"] as? String ?? ""
            ) == .orderedAscending
          }
      }
      result(items)
    } catch {
      result(FlutterError(
        code: "HOST_FOLDER_LIST_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func createHostFolder(call: FlutterMethodCall, result: FlutterResult) {
    do {
      let arguments = try hostFolderArguments(call)
      try withScopedFolder(rootUri: arguments.rootUri) { root in
        try ensureHostFolder(root: root, path: arguments.path)
      }
      result(["ok": true])
    } catch {
      result(FlutterError(
        code: "HOST_FOLDER_CREATE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func syncShareIntakeHostFolder(call: FlutterMethodCall, result: FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let selection = arguments["selection"] as? [String: Any] else {
      result(FlutterError(
        code: "SHARE_FOLDER_SYNC_FAILED",
        message: "Missing Drop folder selection.",
        details: nil
      ))
      return
    }
    do {
      try writeShareIntakeHostFolder(selection)
      result(["synced": true])
    } catch {
      result(FlutterError(
        code: "SHARE_FOLDER_SYNC_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func clearShareIntakeHostFolder(result: FlutterResult) {
    do {
      let file = try shareIntakeInboxDirectory().appendingPathComponent("host-folder.json")
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
      result(["cleared": true])
    } catch {
      result(FlutterError(
        code: "SHARE_FOLDER_CLEAR_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func writeShareIntakeHostFolder(_ selection: [String: Any]) throws {
    let file = try shareIntakeInboxDirectory().appendingPathComponent("host-folder.json")
    let data = try JSONSerialization.data(withJSONObject: selection, options: [])
    try data.write(to: file, options: [.atomic])
  }

  private func shareIntakeInboxDirectory() throws -> URL {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.com.erebrus.drop"
    ) else {
      throw HostFolderError.message("Shared App Group is not available.")
    }
    let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    return inbox
  }

  private func copyFileIntoHostFolder(call: FlutterMethodCall, result: FlutterResult) {
    do {
      guard let arguments = call.arguments as? [String: Any],
            let rootUri = arguments["rootUri"] as? String,
            let sourcePath = arguments["sourcePath"] as? String else {
        throw HostFolderError.message("Missing rootUri or sourcePath")
      }
      let folderPath = arguments["folderPath"] as? String ?? "/"
      let requestedName = safeName(arguments["name"] as? String ?? URL(fileURLWithPath: sourcePath).lastPathComponent)
      let item = try withScopedFolder(rootUri: rootUri) { root in
        let folder = try ensureHostFolder(root: root, path: folderPath)
        let destination = uniqueChildURL(parent: folder, name: requestedName)
        try FileManager.default.copyItem(
          at: URL(fileURLWithPath: sourcePath),
          to: destination
        )
        return hostFileMap(root: root, url: destination)
      }
      result(item)
    } catch {
      result(FlutterError(
        code: "HOST_FOLDER_COPY_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func copyHostFileToCache(call: FlutterMethodCall, result: FlutterResult) {
    do {
      let arguments = try hostFolderArguments(call)
      let copied = try withScopedFolder(rootUri: arguments.rootUri) { root in
        let source = hostURL(root: root, path: arguments.path)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
          throw HostFolderError.message("Folders cannot be streamed as files.")
        }
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("ErebrusDropHostCache", isDirectory: true)
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        let destination = uniqueChildURL(parent: directory, name: safeName(source.lastPathComponent))
        try FileManager.default.copyItem(at: source, to: destination)
        return [
          "path": destination.path,
          "name": source.lastPathComponent,
          "mimeType": mimeType(for: source)
        ]
      }
      result(copied)
    } catch {
      result(FlutterError(
        code: "HOST_FOLDER_CACHE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func openHostFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let arguments = try hostFolderArguments(call)
      let localPreview = try withScopedFolder(rootUri: arguments.rootUri) { root in
        let source = hostURL(root: root, path: arguments.path)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
          throw HostFolderError.message("Open a folder by browsing into it.")
        }
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("ErebrusDropPreview", isDirectory: true)
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        let destination = uniqueChildURL(parent: directory, name: safeName(source.lastPathComponent))
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
      }
      try presentDocumentPreview(url: localPreview)
      result(["opened": true])
    } catch {
      result(FlutterError(
        code: "OPEN_FILE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func shareHostFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let arguments = try hostFolderArguments(call)
      let localShare = try withScopedFolder(rootUri: arguments.rootUri) { root in
        let source = hostURL(root: root, path: arguments.path)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
          throw HostFolderError.message("Share a file, not a folder.")
        }
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("ErebrusDropShare", isDirectory: true)
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        let destination = uniqueChildURL(parent: directory, name: safeName(source.lastPathComponent))
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
      }
      try presentShareSheet(url: localShare)
      result(["shared": true])
    } catch {
      result(FlutterError(
        code: "SHARE_FILE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func deleteHostFile(call: FlutterMethodCall, result: FlutterResult) {
    do {
      let arguments = try hostFolderArguments(call)
      try withScopedFolder(rootUri: arguments.rootUri) { root in
        let source = hostURL(root: root, path: arguments.path)
        try FileManager.default.removeItem(at: source)
      }
      result(["deleted": true])
    } catch {
      result(FlutterError(
        code: "DELETE_FILE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func renameHostItem(call: FlutterMethodCall, result: FlutterResult) {
    do {
      guard let arguments = call.arguments as? [String: Any],
            let rootUri = arguments["rootUri"] as? String,
            let path = arguments["path"] as? String,
            let newName = arguments["newName"] as? String else {
        throw HostFolderError.message("Missing rootUri, path, or newName")
      }
      try withScopedFolder(rootUri: rootUri) { root in
        let source = hostURL(root: root, path: path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(safeName(newName))
        try FileManager.default.moveItem(at: source, to: destination)
      }
      result(["renamed": true])
    } catch {
      result(FlutterError(
        code: "RENAME_ITEM_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func moveHostItem(call: FlutterMethodCall, result: FlutterResult) {
    do {
      guard let arguments = call.arguments as? [String: Any],
            let rootUri = arguments["rootUri"] as? String,
            let path = arguments["path"] as? String,
            let destinationPath = arguments["destinationPath"] as? String else {
        throw HostFolderError.message("Missing rootUri, path, or destinationPath")
      }
      try withScopedFolder(rootUri: rootUri) { root in
        let source = hostURL(root: root, path: path)
        let destination = hostURL(root: root, path: destinationPath)
        let destinationParent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
          atPath: destinationParent.path,
          isDirectory: &isDirectory
        ), isDirectory.boolValue else {
          throw HostFolderError.message("Destination parent not found.")
        }
        try FileManager.default.moveItem(at: source, to: destination)
      }
      result(["moved": true])
    } catch {
      result(FlutterError(
        code: "MOVE_ITEM_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func openLocalFile(call: FlutterMethodCall, result: FlutterResult) {
    do {
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        throw HostFolderError.message("Missing path")
      }
      let url = URL(fileURLWithPath: path)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue else {
        throw HostFolderError.message("File not found: \(path)")
      }
      try presentDocumentPreview(url: url)
      result(["opened": true])
    } catch {
      result(FlutterError(
        code: "OPEN_FILE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func shareLocalFile(call: FlutterMethodCall, result: FlutterResult) {
    do {
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        throw HostFolderError.message("Missing path")
      }
      let url = URL(fileURLWithPath: path)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue else {
        throw HostFolderError.message("File not found: \(path)")
      }
      try presentShareSheet(url: url)
      result(["shared": true])
    } catch {
      result(FlutterError(
        code: "SHARE_FILE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func saveFileToDownloads(call: FlutterMethodCall, result: FlutterResult) {
    do {
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        throw HostFolderError.message("Missing path")
      }
      let source = URL(fileURLWithPath: path)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
            !isDirectory.boolValue else {
        throw HostFolderError.message("File not found: \(path)")
      }
      guard let documents = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first else {
        throw HostFolderError.message("Could not open the Files documents folder.")
      }
      let requestedName = safeName(arguments["name"] as? String ?? source.lastPathComponent)
      let destination = uniqueChildURL(parent: documents, name: requestedName)
      try FileManager.default.copyItem(at: source, to: destination)
      result([
        "name": destination.lastPathComponent,
        "location": "Files > Erebrus Drop > \(destination.lastPathComponent)",
        "path": destination.path
      ])
    } catch {
      result(FlutterError(
        code: "SAVE_DOWNLOAD_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private struct HostFolderArguments {
    let rootUri: String
    let path: String
  }

  private enum HostFolderError: LocalizedError {
    case message(String)

    var errorDescription: String? {
      switch self {
      case .message(let value):
        return value
      }
    }
  }

  private func hostFolderArguments(_ call: FlutterMethodCall) throws -> HostFolderArguments {
    guard let arguments = call.arguments as? [String: Any],
          let rootUri = arguments["rootUri"] as? String else {
      throw HostFolderError.message("Missing rootUri")
    }
    return HostFolderArguments(
      rootUri: rootUri,
      path: arguments["path"] as? String ?? "/"
    )
  }

  private func withScopedFolder<T>(
    rootUri: String,
    _ body: (URL) throws -> T
  ) throws -> T {
    let (url, release) = try resolveScopedFolder(rootUri: rootUri)
    defer { release() }
    return try body(url)
  }

  private func resolveScopedFolder(rootUri: String) throws -> (URL, () -> Void) {
    let url: URL
    if rootUri.hasPrefix("ios-bookmark:") {
      let encoded = String(rootUri.dropFirst("ios-bookmark:".count))
      guard let data = Data(base64Encoded: encoded) else {
        throw HostFolderError.message("Selected folder bookmark is invalid.")
      }
      var isStale = false
      url = try URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    } else if let parsed = URL(string: rootUri), parsed.isFileURL {
      url = parsed
    } else {
      throw HostFolderError.message("Selected folder is not available.")
    }

    let didStart = url.startAccessingSecurityScopedResource()
    return (url.standardizedFileURL, {
      if didStart {
        url.stopAccessingSecurityScopedResource()
      }
    })
  }

  private func presentDocumentPreview(url: URL) throws {
    guard let presenter = topViewController() else {
      throw HostFolderError.message("Could not present a file preview.")
    }
    if QLPreviewController.canPreview(url as NSURL) {
      quickLookPreviewURL = url
      let controller = QLPreviewController()
      controller.dataSource = self
      controller.delegate = self
      presenter.present(controller, animated: true)
      return
    }

    let interactionController = UIDocumentInteractionController(url: url)
    interactionController.delegate = self
    documentInteractionController = interactionController
    if !interactionController.presentPreview(animated: true) {
      interactionController.presentOptionsMenu(
        from: presenter.view.bounds,
        in: presenter.view,
        animated: true
      )
    }
  }

  private func presentShareSheet(url: URL) throws {
    guard let presenter = topViewController() else {
      throw HostFolderError.message("Could not present the share sheet.")
    }
    let controller = UIActivityViewController(
      activityItems: [url],
      applicationActivities: nil
    )
    if let popover = controller.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 1,
        height: 1
      )
      popover.permittedArrowDirections = []
    }
    presenter.present(controller, animated: true)
  }

  private func copyPickedFile(_ url: URL) throws -> [String: Any] {
    let didStart = url.startAccessingSecurityScopedResource()
    defer {
      if didStart {
        url.stopAccessingSecurityScopedResource()
      }
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ErebrusDropPickedUploads", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let name = safeName(url.lastPathComponent.isEmpty ? "upload" : url.lastPathComponent)
    let target = uniqueChildURL(parent: directory, name: name)
    try FileManager.default.copyItem(at: url, to: target)
    let values = try? target.resourceValues(forKeys: [.fileSizeKey])
    return [
      "path": target.path,
      "name": name,
      "sizeBytes": values?.fileSize ?? 0
    ]
  }

  @discardableResult
  private func ensureHostFolder(root: URL, path: String) throws -> URL {
    let url = hostURL(root: root, path: path)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  private func hostURL(root: URL, path: String) -> URL {
    var url = root
    for segment in hostPathSegments(path) {
      url.appendPathComponent(segment, isDirectory: false)
    }
    return url
  }

  private func hostPathSegments(_ path: String) -> [String] {
    return path
      .split(separator: "/")
      .map(String.init)
      .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
      .map(safeName)
      .filter { !$0.isEmpty }
  }

  private func normalizeHostPath(_ path: String) -> String {
    let parts = hostPathSegments(path)
    return parts.isEmpty ? "/" : "/\(parts.joined(separator: "/"))"
  }

  private func relativeHostPath(root: URL, child: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let childPath = child.standardizedFileURL.path
    guard childPath != rootPath else {
      return "/"
    }
    if childPath.hasPrefix("\(rootPath)/") {
      return normalizeHostPath(String(childPath.dropFirst(rootPath.count)))
    }
    return normalizeHostPath("/\(child.lastPathComponent)")
  }

  private func hostFileMap(root: URL, url: URL) -> [String: Any?] {
    let values = try? url.resourceValues(forKeys: [
      .isDirectoryKey,
      .fileSizeKey,
      .contentModificationDateKey
    ])
    let isDirectory = values?.isDirectory == true
    let modified = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
    return [
      "name": url.lastPathComponent,
      "path": relativeHostPath(root: root, child: url),
      "type": isDirectory ? "folder" : "file",
      "sizeBytes": isDirectory ? 0 : (values?.fileSize ?? 0),
      "modifiedAtMillis": Int64(modified.timeIntervalSince1970 * 1000),
      "mimeType": isDirectory ? nil : mimeType(for: url)
    ]
  }

  private func uniqueChildURL(parent: URL, name: String) -> URL {
    let clean = safeName(name)
    let base = (clean as NSString).deletingPathExtension
    let ext = (clean as NSString).pathExtension
    var candidate = parent.appendingPathComponent(clean)
    var index = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
      let nextName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
      candidate = parent.appendingPathComponent(nextName)
      index += 1
    }
    return candidate
  }

  private func safeName(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
    let cleaned = name
      .components(separatedBy: invalid)
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "upload" : cleaned
  }

  private func mimeType(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if #available(iOS 14.0, *) {
      if let type = UTType(filenameExtension: ext),
         let mimeType = type.preferredMIMEType {
        return mimeType
      }
    }
    switch ext {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "svg": return "image/svg+xml"
    case "pdf": return "application/pdf"
    case "txt", "log", "md": return "text/plain"
    case "html": return "text/html"
    case "json": return "application/json"
    case "mp4": return "video/mp4"
    case "mov": return "video/quicktime"
    case "m4v": return "video/x-m4v"
    case "webm": return "video/webm"
    case "mp3": return "audio/mpeg"
    case "m4a": return "audio/mp4"
    case "wav": return "audio/wav"
    case "zip": return "application/zip"
    default: return "application/octet-stream"
    }
  }

  private func topViewController(
    base: UIViewController? = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController
  ) -> UIViewController? {
    if let navigation = base as? UINavigationController {
      return topViewController(base: navigation.visibleViewController)
    }
    if let tab = base as? UITabBarController {
      return topViewController(base: tab.selectedViewController)
    }
    if let presented = base?.presentedViewController {
      return topViewController(base: presented)
    }
    return base
  }

  private static func localIpAddresses() -> [String] {
    var candidates: [(Int, String)] = []
    var interfaces: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return []
    }
    defer { freeifaddrs(interfaces) }

    var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
    while pointer != nil {
      guard let interface = pointer?.pointee else {
        pointer = pointer?.pointee.ifa_next
        continue
      }
      guard let addressPointer = interface.ifa_addr else {
        pointer = interface.ifa_next
        continue
      }
      let family = addressPointer.pointee.sa_family
      if family == UInt8(AF_INET) {
        let interfaceName = String(cString: interface.ifa_name)
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(
          addressPointer,
          socklen_t(addressPointer.pointee.sa_len),
          &hostname,
          socklen_t(hostname.count),
          nil,
          0,
          NI_NUMERICHOST
        )
        let address = String(cString: hostname)
        if address != "127.0.0.1" {
          candidates.append((interfacePriority(interfaceName), address))
        }
      }
      pointer = interface.ifa_next
    }
    return candidates.sorted { lhs, rhs in
      if lhs.0 == rhs.0 {
        return lhs.1 < rhs.1
      }
      return lhs.0 < rhs.0
    }.map { $0.1 }
  }

  private static func interfacePriority(_ name: String) -> Int {
    if name == "en0" { return 0 }
    if name.hasPrefix("en") { return 1 }
    if name.hasPrefix("bridge") { return 3 }
    if name.hasPrefix("pdp_ip") { return 8 }
    if name.hasPrefix("utun") { return 9 }
    if name.hasPrefix("ipsec") { return 9 }
    return 5
  }

  private func publishMdnsService(call: FlutterMethodCall, result: FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let port = arguments["port"] as? Int,
      port > 0
    else {
      result(FlutterError(
        code: "MDNS_INVALID_PORT",
        message: "A valid TCP port is required.",
        details: nil
      ))
      return
    }

    stopMdnsService()
    let serviceName = arguments["serviceName"] as? String ?? "Erebrus Drop"
    let serviceType = arguments["serviceType"] as? String ?? "_erebrusdrop._tcp."
    let service = NetService(
      domain: "local.",
      type: serviceType.hasSuffix(".") ? serviceType : "\(serviceType).",
      name: serviceName,
      port: Int32(port)
    )
    if let txt = arguments["txt"] as? [String: Any] {
      let record = txt.reduce(into: [String: Data]()) { partial, item in
        partial[item.key] = "\(item.value)".data(using: .utf8)
      }
      service.setTXTRecord(NetService.data(fromTXTRecord: record))
    }
    publishedService = service
    service.publish()
    result(["published": true])
  }

  private func stopMdnsService() {
    publishedService?.stop()
    publishedService = nil
  }

  private func discoverMdnsRooms(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if discoveryResult != nil {
      result(FlutterError(
        code: "MDNS_DISCOVERY_BUSY",
        message: "Room discovery is already running.",
        details: nil
      ))
      return
    }
    let arguments = call.arguments as? [String: Any]
    let requestedType = arguments?["serviceType"] as? String ?? "_erebrusdrop._tcp."
    let serviceType = requestedType.hasSuffix(".") ? requestedType : "\(requestedType)."
    let timeoutMillis = min(max(arguments?["timeoutMillis"] as? Int ?? 2500, 1000), 8000)

    discoveredRooms.removeAll()
    discoveryServices.removeAll()
    discoveryResult = result

    let browser = NetServiceBrowser()
    browser.delegate = self
    discoveryBrowser = browser
    browser.searchForServices(ofType: serviceType, inDomain: "local.")
    discoveryTimer = Timer.scheduledTimer(
      withTimeInterval: Double(timeoutMillis) / 1000.0,
      repeats: false
    ) { [weak self] _ in
      self?.finishMdnsDiscovery()
    }
  }

  private func finishMdnsDiscovery(error: String? = nil) {
    guard let result = discoveryResult else {
      return
    }
    discoveryResult = nil
    discoveryTimer?.invalidate()
    discoveryTimer = nil
    discoveryBrowser?.stop()
    discoveryBrowser?.delegate = nil
    discoveryBrowser = nil
    discoveryServices.forEach { $0.delegate = nil }
    discoveryServices.removeAll()

    if let error {
      result(FlutterError(
        code: "MDNS_DISCOVERY_FAILED",
        message: error,
        details: nil
      ))
      return
    }
    result(Array(discoveredRooms.values))
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    guard discoveryResult != nil else { return }
    discoveryServices.append(service)
    service.delegate = self
    service.resolve(withTimeout: 2.0)
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didRemove service: NetService,
    moreComing: Bool
  ) {
    discoveredRooms.removeValue(forKey: service.name)
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didNotSearch errorDict: [String : NSNumber]
  ) {
    finishMdnsDiscovery(error: "Discovery failed.")
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard discoveryResult != nil, let room = mdnsRoomMap(sender) else {
      return
    }
    let key = "\(room["host"] ?? ""):\(room["port"] ?? "")"
    discoveredRooms[key] = room
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
    sender.delegate = nil
  }

  private func mdnsRoomMap(_ service: NetService) -> [String: Any]? {
    guard service.port > 0, let host = resolvedIPv4Address(service) else {
      return nil
    }
    let txt = NetService.dictionary(fromTXTRecord: service.txtRecordData() ?? Data())
      .reduce(into: [String: String]()) { partial, item in
        partial[item.key] = String(data: item.value, encoding: .utf8) ?? ""
      }
    return [
      "serviceName": service.name,
      "host": host,
      "port": service.port,
      "url": "http://\(host):\(service.port)",
      "txt": txt
    ]
  }

  private func resolvedIPv4Address(_ service: NetService) -> String? {
    for address in service.addresses ?? [] {
      if let ip = ipv4Address(from: address) {
        return ip
      }
    }
    return nil
  }

  private func ipv4Address(from data: Data) -> String? {
    return data.withUnsafeBytes { rawBuffer -> String? in
      guard let baseAddress = rawBuffer.baseAddress else {
        return nil
      }
      let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
      guard Int32(sockaddrPointer.pointee.sa_family) == AF_INET else {
        return nil
      }
      var address = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee.sin_addr
      }
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
        return nil
      }
      return String(cString: buffer)
    }
  }

  private static func storageStats() -> [String: Int64] {
    let homeUrl = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? homeUrl.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeTotalCapacityKey
    ])
    let attributes = try? FileManager.default.attributesOfFileSystem(
      forPath: NSHomeDirectory()
    )
    let fallbackFree = attributes?[.systemFreeSize] as? NSNumber
    let fallbackTotal = attributes?[.systemSize] as? NSNumber
    return [
      "availableBytes": values?.volumeAvailableCapacityForImportantUsage ??
        fallbackFree?.int64Value ?? 0,
      "totalBytes": Int64(values?.volumeTotalCapacity ?? 0) != 0
        ? Int64(values?.volumeTotalCapacity ?? 0)
        : fallbackTotal?.int64Value ?? 0
    ]
  }
}

final class NativeQrScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onFinish: ((String?) -> Void)?
  private let session = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var didFinish = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    buildUi()
    startSession()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    session.stopRunning()
  }

  private func startSession() {
    guard let device = AVCaptureDevice.default(for: .video) else {
      finish(code: nil)
      return
    }
    do {
      let input = try AVCaptureDeviceInput(device: device)
      if session.canAddInput(input) {
        session.addInput(input)
      }
      let output = AVCaptureMetadataOutput()
      if session.canAddOutput(output) {
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]
      }
      let layer = AVCaptureVideoPreviewLayer(session: session)
      layer.videoGravity = .resizeAspectFill
      layer.frame = view.bounds
      view.layer.insertSublayer(layer, at: 0)
      previewLayer = layer
      DispatchQueue.global(qos: .userInitiated).async {
        self.session.startRunning()
      }
    } catch {
      finish(code: nil)
    }
  }

  private func buildUi() {
    let topBar = UIView()
    topBar.translatesAutoresizingMaskIntoConstraints = false
    topBar.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
    view.addSubview(topBar)

    let title = UILabel()
    title.translatesAutoresizingMaskIntoConstraints = false
    title.text = "Scan Drop Code"
    title.textColor = .white
    title.font = .systemFont(ofSize: 26, weight: .regular)
    topBar.addSubview(title)

    let close = UIButton(type: .system)
    close.translatesAutoresizingMaskIntoConstraints = false
    close.setTitle("‹", for: .normal)
    close.setTitleColor(.white, for: .normal)
    close.titleLabel?.font = .systemFont(ofSize: 48, weight: .regular)
    close.accessibilityLabel = "Back"
    close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
    topBar.addSubview(close)

    let frame = UIView()
    frame.translatesAutoresizingMaskIntoConstraints = false
    frame.layer.borderColor = UIColor(red: 1, green: 0.41, blue: 0.16, alpha: 1).cgColor
    frame.layer.borderWidth = 4
    frame.layer.cornerRadius = 24
    view.addSubview(frame)

    let guide = UILabel()
    guide.translatesAutoresizingMaskIntoConstraints = false
    guide.text = "Point the camera at the host device Drop Code."
    guide.textColor = .white
    guide.font = .systemFont(ofSize: 17)
    guide.numberOfLines = 2
    guide.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 0.94)
    guide.layer.borderColor = UIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1).cgColor
    guide.layer.borderWidth = 1
    guide.layer.cornerRadius = 10
    guide.layer.masksToBounds = true
    guide.textAlignment = .center
    view.addSubview(guide)

    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: view.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.heightAnchor.constraint(equalToConstant: 108),
      close.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 10),
      close.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -8),
      close.widthAnchor.constraint(equalToConstant: 64),
      close.heightAnchor.constraint(equalToConstant: 64),
      title.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      title.centerYAnchor.constraint(equalTo: close.centerYAnchor),
      frame.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      frame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      frame.widthAnchor.constraint(equalToConstant: 276),
      frame.heightAnchor.constraint(equalToConstant: 276),
      guide.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      guide.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      guide.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
      guide.heightAnchor.constraint(equalToConstant: 82)
    ])
  }

  @objc private func cancel() {
    finish(code: nil)
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
      object.type == .qr,
      let code = object.stringValue else {
      return
    }
    finish(code: code)
  }

  private func finish(code: String?) {
    if didFinish {
      return
    }
    didFinish = true
    session.stopRunning()
    dismiss(animated: true) {
      self.onFinish?(code)
    }
  }
}
