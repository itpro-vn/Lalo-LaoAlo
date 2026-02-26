import Flutter
import UIKit
import PushKit
import CallKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  private let callController = CXCallController()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register for VoIP push notifications
    let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [.voIP]

    // Configure audio session for voice/video calls
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
    } catch {
      print("Failed to configure audio session: \(error)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // MARK: - PKPushRegistryDelegate

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    // Forward VoIP token to Flutter via method channel
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "com.lalo.call/push", binaryMessenger: controller.binaryMessenger)
    channel.invokeMethod("onVoIPToken", arguments: token)
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }

    let data = payload.dictionaryPayload
    let callID = data["call_id"] as? String ?? UUID().uuidString
    let callerName = data["caller_name"] as? String ?? "Unknown"
    let hasVideo = data["has_video"] as? Bool ?? false

    // CRITICAL: Report to CallKit IMMEDIATELY before ANY async work.
    // iOS will terminate the app if reportNewIncomingCall is not called
    // within the PushKit callback.
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerName)
    update.localizedCallerName = callerName
    update.hasVideo = hasVideo
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsHolding = false
    update.supportsDTMF = false

    let provider = CXProvider(configuration: Self.providerConfiguration())
    let uuid = UUID(uuidString: callID) ?? UUID()

    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      if let error = error {
        print("Failed to report incoming call: \(error)")
      }
      // Forward to Flutter for signaling connection
      DispatchQueue.main.async {
        guard let controller = self.window?.rootViewController as? FlutterViewController else {
          completion()
          return
        }
        let channel = FlutterMethodChannel(name: "com.lalo.call/push", binaryMessenger: controller.binaryMessenger)
        channel.invokeMethod("onIncomingCall", arguments: data)
      }
      completion()
    }
  }

  private static func providerConfiguration() -> CXProviderConfiguration {
    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    config.includesCallsInRecents = true
    return config
  }
}
