import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    let channel = FlutterMethodChannel(
      name: "com.tcw3.icamera/manual_camera",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "bindControl":
        result(nil)

      case "setManualExposure":
        guard let args = call.arguments as? [String: Any],
              let iso = args["iso"] as? Int,
              let shutterDenom = args["shutterDenom"] as? Int
        else {
          result(FlutterError(code: "ARGS", message: "Invalid arguments", details: nil))
          return
        }
        self?.setManualExposure(iso: iso, shutterDenom: shutterDenom, result: result)

      case "setAutoExposure":
        self?.setAutoExposure(result: result)

      case "getLiveExposure":
        self?.getLiveExposure(result: result)

      case "openGallery":
        result(nil)

      case "getAvailableZoomFactors":
        self?.getAvailableZoomFactors(result: result)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: – AVCaptureDevice helpers

  private func backCamera() -> AVCaptureDevice? {
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
  }

  private func setManualExposure(iso: Int, shutterDenom: Int, result: @escaping FlutterResult) {
    guard let device = backCamera() else { result(nil); return }
    do {
      try device.lockForConfiguration()
      let duration = CMTimeMake(value: 1, timescale: Int32(max(1, shutterDenom)))
      let minIso = device.activeFormat.minISO
      let maxIso = device.activeFormat.maxISO
      let clampedIso = min(max(Float(iso), minIso), maxIso)
      device.setExposureModeCustom(duration: duration, iso: clampedIso, completionHandler: nil)
      device.unlockForConfiguration()
      result(nil)
    } catch {
      result(nil) // silently fail if configuration lock is unavailable
    }
  }

  private func setAutoExposure(result: @escaping FlutterResult) {
    guard let device = backCamera() else { result(nil); return }
    do {
      try device.lockForConfiguration()
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
      device.unlockForConfiguration()
      result(nil)
    } catch {
      result(nil)
    }
  }

  private func getLiveExposure(result: @escaping FlutterResult) {
    guard let device = backCamera() else { result(nil); return }
    let iso = Int(device.iso)
    let durationSec = CMTimeGetSeconds(device.exposureDuration)
    let shutterDenom: Int
    if durationSec > 0 && durationSec < 1.0 {
      shutterDenom = max(1, Int(round(1.0 / durationSec)))
    } else {
      shutterDenom = 1
    }
    let ev = Double(device.exposureTargetBias)
    result(["iso": iso, "shutterDenom": shutterDenom, "ev": ev])
  }

  private func getAvailableZoomFactors(result: @escaping FlutterResult) {
    var factors: [Double] = [1.0]

    // Detect ultra-wide and telephoto physical cameras
    let session = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInUltraWideCamera, .builtInTelephotoCamera],
      mediaType: .video,
      position: .back
    )
    var hasTelephoto = false
    for device in session.devices {
      if device.deviceType == .builtInUltraWideCamera {
        factors.append(0.5)
      }
      if device.deviceType == .builtInTelephotoCamera {
        hasTelephoto = true
      }
    }

    // For telephoto, read the optical switch-over zoom from the virtual device
    if hasTelephoto {
      let virtualTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera
      ]
      for vType in virtualTypes {
        if let vDev = AVCaptureDevice.default(vType, for: .video, position: .back) {
          if let teleZoom = vDev.virtualDeviceSwitchOverVideoZoomFactors.last {
            factors.append(teleZoom.doubleValue)
          }
          break
        }
      }
    }

    result(factors.sorted())
  }
}
