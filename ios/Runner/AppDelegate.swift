import Flutter
import Darwin
import Foundation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
          "reason": "iOS does not allow apps to create Personal Hotspot automatically."
        ])
      case "startLocalOnlyHotspot":
        result([
          "supported": false,
          "started": false,
          "reason": "Open Settings, enable Personal Hotspot, connect nearby devices, then return to Erebrus Drop."
        ])
      case "stopLocalOnlyHotspot":
        result(["stopped": true])
      case "pickFileForUpload", "pickFilesForUpload":
        result(FlutterError(
          code: "PICK_FILE_UNAVAILABLE",
          message: "Native file upload picker is currently available on Android. iOS document picker support is next.",
          details: nil
        ))
      case "selectHostFolder":
        result(FlutterError(
          code: "PICK_FOLDER_UNAVAILABLE",
          message: "iOS folder selection through Files/iCloud needs the document picker storage adapter before it can host a Drop Room folder.",
          details: nil
        ))
      case "startRoomForegroundService":
        result(["started": false, "reason": "Foreground hosting service is Android-only."])
      case "stopRoomForegroundService":
        result(["stopped": true])
      case "moveAppToBackground":
        result(["backgrounded": false, "reason": "Programmatic backgrounding is Android-only."])
      case "getCurrentNetworkInfo":
        result(["interface": "local-network"])
      case "checkLocalNetworkPermission":
        result(["allowed": true, "reason": "iOS prompts when local network access is first used"])
      case "openPersonalHotspotSettingsGuide":
        result([
          "supported": false,
          "reason": "Open Settings, enable Personal Hotspot, connect nearby devices, then return to Erebrus Drop."
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func localIpAddresses() -> [String] {
    var addresses: [String] = []
    var interfaces: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return addresses
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
          addresses.append(address)
        }
      }
      pointer = interface.ifa_next
    }
    return addresses
  }

  private static func storageStats() -> [String: Int64] {
    guard
      let attributes = try? FileManager.default.attributesOfFileSystem(
        forPath: NSHomeDirectory()
      )
    else {
      return [:]
    }
    let free = attributes[.systemFreeSize] as? NSNumber
    let total = attributes[.systemSize] as? NSNumber
    return [
      "availableBytes": free?.int64Value ?? 0,
      "totalBytes": total?.int64Value ?? 0
    ]
  }
}
