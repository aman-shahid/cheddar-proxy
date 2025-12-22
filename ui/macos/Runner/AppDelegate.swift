import Cocoa
import FlutterMacOS
import Security

@main
class AppDelegate: FlutterAppDelegate {
  private var platformChannel: FlutterMethodChannel?
  private var logDirectory: URL?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    DispatchQueue.main.async { [weak self] in
      self?.configurePlatformChannel()
    }
  }

  private func configurePlatformChannel() {
    guard platformChannel == nil else { return }

    let controller: FlutterViewController?
    if let main = mainFlutterWindow?.contentViewController as? FlutterViewController {
      controller = main
    } else {
      controller = NSApplication.shared.windows
        .compactMap { $0.contentViewController as? FlutterViewController }
        .first
    }

    guard let flutterController = controller else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.configurePlatformChannel()
      }
      return
    }

    let channel = FlutterMethodChannel(
      name: "com.cheddarproxy/platform",
      binaryMessenger: flutterController.engine.binaryMessenger
    )
    channel.setMethodCallHandler(handlePlatformCall)
    platformChannel = channel
  }

  private func handlePlatformCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "trustMacCertificate":
      guard let args = call.arguments as? [String: Any],
            let commonName = args["commonName"] as? String else {
        result(FlutterError(code: "invalid_args", message: "commonName missing", details: nil))
        return
      }
      trustCertificate(commonName: commonName, result: result)
    case "setStoragePath":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "invalid_args", message: "path missing", details: nil))
        return
      }
      logDirectory = URL(fileURLWithPath: path).appendingPathComponent("logs")
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func trustCertificate(commonName: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let query: [CFString: Any] = [
        kSecClass: kSecClassCertificate,
        kSecMatchLimit: kSecMatchLimitOne,
        kSecReturnRef: true,
        kSecAttrLabel: commonName,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
      ]

      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      guard status == errSecSuccess, let certificateRef = item else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "cert_not_found",
            message: "Certificate \(commonName) not found in login keychain.",
            details: status
          ))
        }
        return
      }
      let certificate = certificateRef as! SecCertificate

      let trustSettings = [
        [
          kSecTrustSettingsResult: NSNumber(
            value: SecTrustSettingsResult.trustRoot.rawValue
          )
        ]
      ] as CFArray

      let setStatus = SecTrustSettingsSetTrustSettings(
        certificate,
        SecTrustSettingsDomain.user,
        trustSettings
      )

      DispatchQueue.main.async {
        if setStatus == errSecSuccess {
          result(true)
        } else {
          result(FlutterError(
            code: "trust_failed",
            message: "Unable to update trust settings.",
            details: setStatus
          ))
        }
      }
    }
  }

  @IBAction
  func openHelp(_ sender: Any?) {
    openURL("https://github.com/aman-shahid/cheddarproxy#readme")
  }

  @IBAction
  func reportIssue(_ sender: Any?) {
    openURL("https://github.com/aman-shahid/cheddarproxy/issues/new/choose")
  }

  @IBAction
  func checkForUpdates(_ sender: Any?) {
    configurePlatformChannel()
    if let channel = platformChannel {
      channel.invokeMethod("checkForUpdates", arguments: nil)
    }
  }

  @IBAction
  func showAboutPanel(_ sender: Any?) {
    configurePlatformChannel()
    if let channel = platformChannel {
      channel.invokeMethod("showAboutPanel", arguments: nil)
      return
    }
    NSApplication.shared.orderFrontStandardAboutPanel(sender)
  }

  private func openURL(_ urlString: String) {
    guard let url = URL(string: urlString) else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  @IBAction
  func openLogsFolder(_ sender: Any?) {
    let url = logDirectory ?? defaultLogsDirectory()
    guard FileManager.default.fileExists(atPath: url.path) else {
      showAlert(
        title: "Logs not found",
        message: "Expected logs at \(url.path). Make sure the app can create and write logs."
      )
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func defaultLogsDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let bundleID = Bundle.main.bundleIdentifier ?? "com.cheddarproxy.app"
    return (base ?? URL(fileURLWithPath: "~/Library/Application Support", isDirectory: true))
      .appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("logs", isDirectory: true)
  }

  private func showAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
  }
}
