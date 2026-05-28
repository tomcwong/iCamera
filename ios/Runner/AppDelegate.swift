import Flutter
import UIKit
import AVFoundation
import ImageIO
import MobileCoreServices
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var _proPhotoOutput: AVCapturePhotoOutput?
  private var _proCapturePending: FlutterResult?
  private weak var _captureSession: AVCaptureSession?

  // Face detection
  private var _faceVideoOutput: AVCaptureVideoDataOutput?
  private var _faceEventSink: FlutterEventSink?
  private var _faceFrameCount = 0

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // EventChannel for streaming face detection bounding boxes to Flutter
    let faceChannel = FlutterEventChannel(
      name: "com.tcw3.icamera/face_stream",
      binaryMessenger: controller.binaryMessenger
    )
    faceChannel.setStreamHandler(self)

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

      case "getPersonMask":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int
        else { result(nil); return }
        self?.getPersonMask(path: path, maskWidth: width, maskHeight: height, result: result)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Observe the Flutter camera plugin's session start/stop so we can find
    // its AVCapturePhotoOutput for native PRO captures (bypasses Smart HDR).
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(_sessionStarted(_:)),
      name: .AVCaptureSessionDidStartRunning,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(_sessionStopped(_:)),
      name: .AVCaptureSessionDidStopRunning,
      object: nil
    )

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @objc private func _sessionStarted(_ note: Notification) {
    guard let session = note.object as? AVCaptureSession else { return }
    DispatchQueue.main.async { [weak self] in
      self?._captureSession = session
      for output in session.outputs {
        if let photoOut = output as? AVCapturePhotoOutput {
          self?._proPhotoOutput = photoOut
          // Enable portrait effects matte delivery when the hardware supports it
          // (dual-camera or TrueDepth devices). The matte is Apple's own Neural
          // Engine mask — far higher quality than VNGeneratePersonSegmentationRequest.
          if photoOut.isPortraitEffectsMatteDeliverySupported {
            photoOut.isPortraitEffectsMatteDeliveryEnabled = true
          }
          break
        }
      }
      self?._setupFaceDetection(session: session)
    }
  }

  @objc private func _sessionStopped(_ note: Notification) {
    guard let session = note.object as? AVCaptureSession else { return }
    DispatchQueue.main.async { [weak self] in
      if self?._captureSession === session {
        self?._proPhotoOutput = nil
        self?._captureSession = nil
        self?._faceVideoOutput = nil
        self?._faceFrameCount = 0
      }
    }
  }

  // Attaches an AVCaptureVideoDataOutput to the Flutter camera plugin's session
  // so we can run Vision face detection on live frames without any polling.
  private func _setupFaceDetection(session: AVCaptureSession) {
    guard _faceVideoOutput == nil else { return }
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .utility))
    guard session.canAddOutput(output) else { return }
    session.beginConfiguration()
    session.addOutput(output)
    // Set portrait orientation so Vision gets portrait-space pixels directly —
    // face bounding boxes then map straight to the Flutter preview widget coords.
    if let conn = output.connection(with: .video) {
      if conn.isVideoOrientationSupported {
        conn.videoOrientation = .portrait
      }
    }
    session.commitConfiguration()
    _faceVideoOutput = output
  }

  // MARK: – Native PRO capture

  // Captures a single JPEG bypassing AVCapturePhotoOutput's Smart HDR /
  // virtual-device fusion pipeline, so the sensor's manual ISO/SS is honoured.
  private func captureProPhoto(result: @escaping FlutterResult) {
    guard let photoOutput = _proPhotoOutput,
          let session = _captureSession,
          session.isRunning else { result(nil); return }
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
    // Request Portrait Effects Matte when the hardware supports it.
    // This gives Apple's Neural Engine mask (hair-strand precision, soft alpha)
    // which is far better than our post-capture VNGeneratePersonSegmentationRequest.
    if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
      settings.isPortraitEffectsMatteDeliveryEnabled = true
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
    guard let device = cameraForExposure() else { result(nil); return }
    do {
      try device.lockForConfiguration()
      let duration = CMTimeMake(value: 1, timescale: Int32(max(1, shutterDenom)))
      let clampedIso = min(max(Float(iso), device.activeFormat.minISO), device.activeFormat.maxISO)
      // Ensure result is called exactly once: either from the completion handler
      // or from the 1.5 s safety timeout — whichever fires first.
      // Guards against the completion handler never firing (iOS 26 virtual-device
      // edge case) which would leave the Dart await hanging indefinitely.
      var done = false
      let finish = {
        guard !done else { return }
        done = true
        device.unlockForConfiguration()
        result(nil)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish() }
      device.setExposureModeCustom(duration: duration, iso: clampedIso) { _ in finish() }
    } catch {
      result(nil)
    }
  }

  // Always use the physical wide-angle camera for setExposureModeCustom.
  // Virtual devices (builtInDualWideCamera / builtInTripleCamera) claim to
  // support .custom mode but throw NSException on iOS 26, preventing the
  // completion handler from ever firing and hanging the Dart await.
  // The physical wide-angle camera reliably supports .custom on all iOS versions.
  private func cameraForExposure() -> AVCaptureDevice? {
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
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
    // Read from the physical wide-angle camera — its iso/exposureDuration properties
    // update in real-time under AE control. Virtual devices return stale snapshots
    // on iOS 26 and make the viewfinder HUD appear frozen.
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { result(nil); return }
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

  // Lossless GPS metadata injection: copies the compressed image data directly
  // from the source using CGImageDestinationAddImageFromSource (no pixel decode/
  // re-encode), merging GPS into the existing EXIF. Overwrites the file in-place.
  private func writeGpsToPhoto(path: String, lat: Double, lon: Double, alt: Double, result: @escaping FlutterResult) {
    let fileURL = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          let uti = CGImageSourceGetType(source)
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
    // AddImageFromSource copies compressed bytes as-is — truly lossless, unlike
    // CGImageDestinationAddImage which decodes then re-encodes the pixels.
    CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { result(nil); return }
    do {
      try (outputData as Data).write(to: fileURL, options: .atomic)
      result(nil)
    } catch { result(nil) }
  }

  private func encodeRgbaToHeif(rgbaData: Data, width: Int, height: Int, quality: Double, result: @escaping FlutterResult) {
    // Run H.265 encoding on a background queue — CGImageDestinationFinalize for HEIC
    // can take 2–5 s on 6 MP images and would freeze the UI if run on the main thread.
    DispatchQueue.global(qos: .userInitiated).async {
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
      else { DispatchQueue.main.async { result(nil) }; return }
      let data = NSMutableData()
      guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.heic" as CFString, 1, nil)
      else { DispatchQueue.main.async { result(nil) }; return }
      let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
      CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
      guard CGImageDestinationFinalize(dest) else { DispatchQueue.main.async { result(nil) }; return }
      DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data as Data)) }
    }
  }

  // Runs VNGeneratePersonSegmentationRequest on the JPEG at [path] and returns
  // a Float32 mask (1=person/sharp, 0=background/blur) resized to [maskWidth × maskHeight].
  // Returns nil when no person is detected or on error. Runs on a background queue.
  private func getPersonMask(path: String, maskWidth: Int, maskHeight: Int, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let fileURL = URL(fileURLWithPath: path)
      let request = VNGeneratePersonSegmentationRequest()
      // .accurate gives the best hair-edge detail; post-capture so speed is not critical.
      request.qualityLevel = .accurate
      request.outputPixelFormat = kCVPixelFormatType_OneComponent8

      let handler = VNImageRequestHandler(url: fileURL, options: [:])
      do {
        try handler.perform([request])
      } catch {
        DispatchQueue.main.async { result(nil) }
        return
      }

      guard let observation = request.results?.first else {
        DispatchQueue.main.async { result(nil) }
        return
      }

      let pixelBuffer = observation.pixelBuffer
      CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

      guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      let srcW = CVPixelBufferGetWidth(pixelBuffer)
      let srcH = CVPixelBufferGetHeight(pixelBuffer)
      let srcBPR = CVPixelBufferGetBytesPerRow(pixelBuffer)
      let src = baseAddr.assumingMemoryBound(to: UInt8.self)

      // Reject if person coverage < 1% of the mask area
      var personPixels = 0
      for sy in 0..<srcH {
        for sx in 0..<srcW {
          if src[sy * srcBPR + sx] > 127 { personPixels += 1 }
        }
      }
      guard personPixels > (srcW * srcH) / 100 else {
        DispatchQueue.main.async { result(nil) }
        return
      }

      // Bilinear resample to target dimensions
      let count = maskWidth * maskHeight
      var floatMask = [Float](repeating: 0, count: count)
      let fSrcW = Float(srcW - 1)
      let fSrcH = Float(srcH - 1)
      for dy in 0..<maskHeight {
        let fy = Float(dy) * fSrcH / Float(maskHeight - 1)
        let sy0 = Int(fy); let sy1 = min(sy0 + 1, srcH - 1)
        let ty = fy - Float(sy0)
        for dx in 0..<maskWidth {
          let fx = Float(dx) * fSrcW / Float(maskWidth - 1)
          let sx0 = Int(fx); let sx1 = min(sx0 + 1, srcW - 1)
          let tx = fx - Float(sx0)
          let v00 = Float(src[sy0 * srcBPR + sx0]) / 255.0
          let v01 = Float(src[sy0 * srcBPR + sx1]) / 255.0
          let v10 = Float(src[sy1 * srcBPR + sx0]) / 255.0
          let v11 = Float(src[sy1 * srcBPR + sx1]) / 255.0
          floatMask[dy * maskWidth + dx] = (v00 * (1 - tx) + v01 * tx) * (1 - ty)
                                         + (v10 * (1 - tx) + v11 * tx) * ty
        }
      }

      let data = floatMask.withUnsafeBufferPointer { Data(buffer: $0) }
      DispatchQueue.main.async {
        result(FlutterStandardTypedData(float32: data))
      }
    }
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
  @objc func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishProcessingPhoto photo: AVCapturePhoto,
                         error: Error?) {
    guard let result = _proCapturePending else { return }
    _proCapturePending = nil
    guard error == nil, let data = photo.fileDataRepresentation() else {
      result(nil)
      return
    }

    // Try to include the Portrait Effects Matte (Apple Neural Engine mask).
    // Matte is a Float32 pixel buffer: 1.0 = subject (sharp), 0.0 = background.
    // If available it replaces the slower post-capture VNGeneratePersonSegmentation.
    if #available(iOS 12.0, *),
       let matte = photo.portraitEffectsMatte {
      let buf = matte.mattingImage          // CVPixelBuffer, kCVPixelFormatType_OneComponent32Float
      CVPixelBufferLockBaseAddress(buf, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
      if let ptr = CVPixelBufferGetBaseAddress(buf) {
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        let count = w * h
        let floatPtr = ptr.assumingMemoryBound(to: Float.self)
        let floatData = Data(bytes: floatPtr, count: count * MemoryLayout<Float>.size)
        let matteTyped = FlutterStandardTypedData(float32: floatData)
        result([
          "jpeg": FlutterStandardTypedData(bytes: data),
          "matte": matteTyped,
          "matteWidth": w,
          "matteHeight": h,
        ])
        return
      }
    }

    // No matte available — return raw JPEG bytes (Dart will run Vision separately)
    result(FlutterStandardTypedData(bytes: data))
  }
}

// MARK: – Live face detection delegate
// Runs Vision VNDetectFaceRectanglesRequest on every ~20th video frame (~1.5 fps).
// videoOrientation is set to .portrait in _setupFaceDetection, so the pixel buffer
// arrives in portrait space — Vision bounds map directly to Flutter preview coords.
extension AppDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput,
                     didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    _faceFrameCount += 1
    guard _faceFrameCount % 20 == 0 else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let request = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
    do { try handler.perform([request]) } catch { return }

    let observations = request.results ?? []
    let faces: [[String: Double]] = observations.map { face in
      let b = face.boundingBox
      // Vision origin is bottom-left; flip Y so top-left matches Flutter screen coords.
      return ["x": b.minX, "y": 1.0 - b.maxY, "w": b.width, "h": b.height]
    }
    DispatchQueue.main.async { [weak self] in
      self?._faceEventSink?(faces)
    }
  }
}

// MARK: – Flutter EventChannel stream handler (face stream)
extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    _faceEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    _faceEventSink = nil
    return nil
  }
}
