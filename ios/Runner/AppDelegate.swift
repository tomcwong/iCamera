import Flutter
import UIKit
import AVFoundation
import ImageIO
import MobileCoreServices

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

      case "encodeRgbaToHeif":
        guard let args = call.arguments as? [String: Any],
              let rgbaData = args["rgba"] as? FlutterStandardTypedData,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int
        else { result(nil); return }
        let quality = args["quality"] as? Double ?? 0.9
        self?.encodeRgbaToHeif(rgbaData: rgbaData.data, width: width, height: height, quality: quality, result: result)

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
      // Completion handler fires when the sensor has actually applied the new
      // ISO and shutter — only then do we unlock and signal Dart to proceed.
      device.setExposureModeCustom(duration: duration, iso: clampedIso) { _ in
        device.unlockForConfiguration()
        result(nil)
      }
    } catch {
      result(nil)
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

  private func encodeRgbaToHeif(rgbaData: Data, width: Int, height: Int, quality: Double, result: @escaping FlutterResult) {
    let bytesPerRow = width * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let provider = CGDataProvider(data: rgbaData as CFData),
          let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    else { result(nil); return }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.heic" as CFString, 1, nil)
    else { result(nil); return }
    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { result(nil); return }
    result(FlutterStandardTypedData(bytes: data as Data))
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
