import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var manualCameraDevice: AVCaptureDevice?
  private var manualCameraChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Standard Flutter channel setup: get messenger from the root FlutterViewController.
    // The storyboard sets this up before didFinishLaunchingWithOptions is called.
    if let controller = window?.rootViewController as? FlutterViewController {
      manualCameraChannel = FlutterMethodChannel(
        name: "com.tcw3.icamera/manual_camera",
        binaryMessenger: controller.binaryMessenger
      )
      manualCameraChannel?.setMethodCallHandler { [weak self] call, result in
        self?.handleManualCamera(call: call, result: result)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleManualCamera(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "bindControl":
      let args = call.arguments as? [String: Any]
      let front = args?["front"] as? Bool ?? false
      let position: AVCaptureDevice.Position = front ? .front : .back
      manualCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
      result(nil)

    case "setManualExposure":
      guard let args = call.arguments as? [String: Any],
            let iso = args["iso"] as? Int,
            let shutterDenom = args["shutterDenom"] as? Int,
            let device = manualCameraDevice else {
        result(nil)
        return
      }
      applyManualExposure(device: device, iso: iso, shutterDenom: shutterDenom)
      result(nil)

    case "setAutoExposure":
      if let device = manualCameraDevice,
         device.isExposureModeSupported(.continuousAutoExposure) {
        do {
          try device.lockForConfiguration()
          device.exposureMode = .continuousAutoExposure
          device.unlockForConfiguration()
        } catch {}
      }
      result(nil)

    case "openGallery":
      DispatchQueue.main.async {
        if let url = URL(string: "photos-redirect://") {
          UIApplication.shared.open(url)
        }
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func applyManualExposure(device: AVCaptureDevice, iso: Int, shutterDenom: Int) {
    guard device.isExposureModeSupported(.custom) else { return }
    do {
      try device.lockForConfiguration()
      let targetSec = 1.0 / Double(max(1, shutterDenom))
      let minSec = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
      let maxSec = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
      let clampedSec = min(max(targetSec, minSec), maxSec)
      let duration = CMTimeMakeWithSeconds(clampedSec, preferredTimescale: 1_000_000)
      let clampedIso = min(max(Float(iso), device.activeFormat.minISO), device.activeFormat.maxISO)
      device.setExposureModeCustom(duration: duration, iso: clampedIso, completionHandler: nil)
      device.unlockForConfiguration()
    } catch {}
  }
}
