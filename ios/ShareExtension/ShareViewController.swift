import UIKit

final class ShareViewController: UIViewController {
  private let appGroupId = "group.com.erebrus.shared"
  private let inboxName = "ShareInbox"
  private let plainTextType = "public.plain-text"
  private let urlType = "public.url"
  private let dataType = "public.data"

  override func viewDidLoad() {
    super.viewDidLoad()
    processSharedItems()
  }

  private func processSharedItems() {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let payload = try self.collectPayload()
        if try !self.importPayloadIfPossible(payload) {
          try self.writePayload(payload)
        }
        DispatchQueue.main.async {
          self.extensionContext?.completeRequest(returningItems: nil)
        }
      } catch {
        DispatchQueue.main.async {
          self.extensionContext?.cancelRequest(withError: error)
        }
      }
    }
  }

  private func collectPayload() throws -> [String: Any] {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
      return ["text": "", "filePaths": []]
    }
    var textValues: [String] = []
    var filePaths: [String] = []
    let group = DispatchGroup()
    let lock = NSLock()
    var capturedError: Error?

    for item in items {
      for provider in item.attachments ?? [] {
        if provider.hasItemConformingToTypeIdentifier(plainTextType) {
          group.enter()
          provider.loadItem(forTypeIdentifier: self.plainTextType, options: nil) { value, error in
            defer { group.leave() }
            if let error {
              lock.lock()
              capturedError = error
              lock.unlock()
              return
            }
            if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              lock.lock()
              textValues.append(text)
              lock.unlock()
            }
          }
          continue
        }
        if provider.hasItemConformingToTypeIdentifier(urlType) {
          group.enter()
          provider.loadItem(forTypeIdentifier: self.urlType, options: nil) { value, error in
            defer { group.leave() }
            if let error {
              lock.lock()
              capturedError = error
              lock.unlock()
              return
            }
            if let url = value as? URL {
              lock.lock()
              textValues.append(url.absoluteString)
              lock.unlock()
            }
          }
          continue
        }
        group.enter()
        let typeIdentifier = provider.registeredTypeIdentifiers.first ?? self.dataType
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
          if let sourceURL = url {
            do {
              let path = try self.copySharedFile(sourceURL)
              lock.lock()
              filePaths.append(path)
              lock.unlock()
            } catch {
              lock.lock()
              capturedError = error
              lock.unlock()
            }
            group.leave()
            return
          }
          if error != nil {
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { value, fallbackError in
              defer { group.leave() }
              if let fallbackError {
                lock.lock()
                capturedError = fallbackError
                lock.unlock()
                return
              }
              do {
                if let sourceURL = value as? URL {
                  let path = try self.copySharedFile(sourceURL)
                  lock.lock()
                  filePaths.append(path)
                  lock.unlock()
                } else if let data = value as? Data {
                  let path = try self.writeSharedData(data, preferredName: provider.suggestedName)
                  lock.lock()
                  filePaths.append(path)
                  lock.unlock()
                }
              } catch {
                lock.lock()
                capturedError = error
                lock.unlock()
              }
            }
            return
          }
          group.leave()
        }
      }
    }

    if group.wait(timeout: .now() + 30) == .timedOut {
      throw NSError(domain: "ErebrusDropShare", code: 2, userInfo: [NSLocalizedDescriptionKey: "Shared items took too long to prepare."])
    }
    if let capturedError {
      throw capturedError
    }
    return [
      "text": textValues.joined(separator: "\n\n"),
      "filePaths": filePaths
    ]
  }

  private func writePayload(_ payload: [String: Any]) throws {
    let inbox = try inboxDirectory()
    let manifest = inbox.appendingPathComponent("pending-share.json")
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    try data.write(to: manifest, options: [.atomic])
  }

  private func importPayloadIfPossible(_ payload: [String: Any]) throws -> Bool {
    guard let root = try resolveSharedDropFolder() else {
      return false
    }
    let accessed = root.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        root.stopAccessingSecurityScopedResource()
      }
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var imported = false
    if let text = payload["text"] as? String,
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let name = "\(timestamp())-Shared text.txt"
      let destination = uniqueURL(in: root, name: name)
      try text.write(to: destination, atomically: true, encoding: .utf8)
      imported = true
    }
    for path in payload["filePaths"] as? [String] ?? [] {
      let source = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: source.path) else {
        continue
      }
      let destination = uniqueURL(in: root, name: source.lastPathComponent)
      try FileManager.default.copyItem(at: source, to: destination)
      imported = true
    }
    return imported
  }

  private func resolveSharedDropFolder() throws -> URL? {
    let config = try inboxDirectory().appendingPathComponent("host-folder.json")
    guard FileManager.default.fileExists(atPath: config.path) else {
      return nil
    }
    let data = try Data(contentsOf: config)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let uri = json["uri"] as? String,
          uri.hasPrefix("ios-bookmark:"),
          let bookmark = Data(base64Encoded: String(uri.dropFirst("ios-bookmark:".count))) else {
      return nil
    }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: bookmark,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    )
    return url
  }

  private func copySharedFile(_ sourceURL: URL) throws -> String {
    let inbox = try inboxDirectory()
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }
    let name = safeName(sourceURL.lastPathComponent.isEmpty ? "shared-file" : sourceURL.lastPathComponent)
    let destination = uniqueURL(in: inbox, name: name)
    try FileManager.default.copyItem(at: sourceURL, to: destination)
    return destination.path
  }

  private func writeSharedData(_ data: Data, preferredName: String?) throws -> String {
    let inbox = try inboxDirectory()
    let name = safeName(preferredName ?? "shared-file")
    let destination = uniqueURL(in: inbox, name: name)
    try data.write(to: destination, options: [.atomic])
    return destination.path
  }

  private func inboxDirectory() throws -> URL {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
      throw NSError(domain: "ErebrusDropShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shared App Group is not available."])
    }
    let directory = container.appendingPathComponent(inboxName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func uniqueURL(in directory: URL, name: String) -> URL {
    let safe = safeName(name)
    let base = (safe as NSString).deletingPathExtension
    let ext = (safe as NSString).pathExtension
    var candidate = directory.appendingPathComponent(safe)
    var index = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
      let next = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
      candidate = directory.appendingPathComponent(next)
      index += 1
    }
    return candidate
  }

  private func safeName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
    let components = value.components(separatedBy: invalid)
    let cleaned = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "shared-file" : cleaned
  }

  private func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return safeName(formatter.string(from: Date()))
  }
}
