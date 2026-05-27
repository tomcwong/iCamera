import Flutter
import UIKit
import AVFoundation
import ImageIO
import MobileCoreServices

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var _proPhotoOutput: AVCapturePhotoOutput?
  private var _proCapturePending: FlutterResult?

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

      case "unlockAfterCapture":
        self?.unlockAfterCapture(result: result)

      case "setAutoExposure":
        self?.setAutoExposure(result: result)

      case "getLiveExposure":
        self?.getLiveExposure(result: result)

      case "openGallery":
        result(nil)

      case "getAvailableZoomFactors":
        self?.getAvailableZoomFactors(result: result)

      case "writeGpsToPhoto":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String,
              let lat = args["lat"] as? Double,
              let lon = args["lon"] as? Double
        else { result(nil); return }
        let alt = args["alt"] as? Double ?? 0
        self?.writeGpsToPhoto(path: path, lat: lat, lon: lon, alt: alt, result: result)

      case "encodeRgbaToHeif":
        guard let args = call.arguments as? [String: Any],
              let rgbaData = args["rgba"] as? FlutterStandardTypedData,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int
        else { result(nil); return }
        let quality = args["quality"] as? Double ?? 0.9
        self?.encodeRgbaToHeif(rgbaData: rgbaData.data, width: width, height: height, quality: quality, result: result)

      case "captureProPhoto":
        self?.captureProPhoto(result: result)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Observe the Flutter camera plugin's session start so we can find its
    // AVCapturePhotoOutput for native PRO captures (bypasses Smart HDR).
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(_sessionStarted(_:)),
      name: .AVCaptureSessionDidStartRunning,
      object: nil
    )

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @objc private func _sessionStarted(_ note: Notification) {
    guard let session = note.object as? AVCaptureSession else { return }
    DispatchQueue.main.async { [weak self] in
      for output in session.outputs {
        if let photoOut = output as? AVCapturePhotoOutput {
          self?._proPhotoOutput = photoOut
          break
        }
      }
    }
  }

  // MARK: – Native PRO capture

  // Captures a single JPEG bypassing AVCapturePhotoOutput's Smart HDR /
  // virtual-device fusion pipeline, so the sensor's manual ISO/SS is honoured.
  private func captureProPhoto(result: @escaping FlutterResult) {
    guard let photoOutput = _proPhotoOutput else { result(nil); return }
    guard _proCapturePending == nil else { result(nil); return }

    let settings: AVCapturePhotoSettings
    if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
      settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
    } else {
      settings = AVCapturePhotoSettings()
    }
    settings.isAutoVirtualDeviceFusionEnabled = false
    if #available(iOS 13.0, *) {
      settings.photoQualityPrioritization = .speed
    }
    _proCapturePending = result
    photoOutput.capturePhoto(with: settings, delegate: self)
  }

  // MARK: – AVCaptureDevice helpers

  // Returns the same virtual device the Flutter camera plugin uses for capture.
  // On iPhone 13: builtInDualWideCamera (wide + ultra-wide virtual).
  // On iPhone 13 Pro: builtInTripleCamera. Single-camera iPhones: builtInWideAngleCamera.
  // Using the physical builtInWideAngleCamera here was the original bug —
  // setExposureModeCustom on that device has no effect on a virtual-device capture.
  private func backCamera() -> AVCaptureDevice? {
    let preferredTypes: [AVCaptureDevice.DeviceType] = [
      .builtInTripleCamera,
      .builtInDualWideCamera,
      .builtInDualCamera,
      .builtInWideAngleCamera,
    ]
    for type in preferredTypes {
      if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
        return device
      }
    }
    return nil
  }

  private func setManualExposure(iso: Int, shutterDenom: Int, result: @escaping FlutterResult) {
    guard let device = backCamera() else { result(nil); return }
    do {
      try device.lockForConfiguration()
      let duration = CMTimeMake(value: 1, timescale: Int32(max(1, shutterDenom)))
      let clampedIso = min(max(Float(iso), device.activeFormat.minISO), device.activeFormat.maxISO)
      // Completion fires when the sensor has applied the new ISO/shutter.
      // Unlock immediately — .custom mode persists after unlock, so the photo
      // capture will use these settings. The Flutter plugin can now lock freely.
      device.setExposureModeCustom(duration: duration, iso: clampedIso) { _ in
        device.unlockForConfiguration()
        result(nil)
      }
    } catch {
      result(nil)
    }
  }

  // No-op: lock is released inside the setManualExposure completion handler.
  private func unlockAfterCapture(result: @escaping FlutterResult) {
    result(nil)
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
    let aperture = Double(device.lensAperture)
    result(["iso": iso, "shutterDenom": shutterDenom, "ev": ev, "aperture": aperture])
  }

  // Writes GPS metadata into an existing JPEG at the given file path.
  // Reads the file with CGImageSource, merges the GPS dictionary, and writes
  // back to the same path without re-encoding pixel data (lossless metadata).
  private func writeGpsToPhoto(path: String, lat: Double, lon: Double, alt: Double, result: @escaping FlutterResult) {
    let fileURL = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          let uti = CGImageSourceGetType(source),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { result(nil); return }

    var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
    var gps = (props[kCGImagePropertyGPSDictionary as String] as? [String: Any]) ?? [:]
    gps[kCGImagePropertyGPSLatitude as String] = abs(lat)
    gps[kCGImagePropertyGPSLatitudeRef as String] = lat >= 0 ? "N" : "S"
    gps[kCGImagePropertyGPSLongitude as String] = abs(lon)
    gps[kCGImagePropertyGPSLongitudeRef as String] = lon >= 0 ? "E" : "W"
    if alt != 0 {
      gps[kCGImagePropertyGPSAltitude as String] = abs(alt)
      gps[kCGImagePropertyGPSAltitudeRef as String] = NSNumber(value: alt >= 0 ? 0 : 1)
    }
    props[kCGImagePropertyGPSDictionary as String] = gps

    let outputData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(outputData as CFMutableData, uti, 1, nil)
    else { result(nil); return }
    props[kCGImageDestinationLossyCompressionQuality as String] = 0.97
    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { result(nil); return }
    do {
      try (outputData as Data).write(to: fileURL, options: .atomic)
      result(nil)
    } catch { result(nil) }
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

// MARK: – PRO capture delegate
extension AppDelegate: AVCapturePhotoCaptureDelegate {
  func photoOutput(_ output: AVCapturePhotoOutput,
                   didFinishProcessingPhoto photo: AVCapturePhoto,
                   error: Error?) {
    guard let result = _proCapturePending else { return }
    _proCapturePending = nil
    guard error == nil, let data = photo.fileDataRepresentation() else {
      result(nil)
      return
    }
    result(FlutterStandardTypedData(bytes: data))
  }
}
