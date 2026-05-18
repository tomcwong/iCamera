package com.tcw3.icamera

import android.content.Context
import android.content.Intent
import android.hardware.camera2.CaptureRequest
import android.util.Log
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Provides direct Camera2 ISO + shutter-speed control via CameraX's
 * Camera2 interop layer, sharing the ProcessCameraProvider singleton
 * that the Flutter camera plugin already uses — no camera restart needed.
 */
@OptIn(ExperimentalCamera2Interop::class)
class ManualCameraPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var appContext: Context? = null
    private var lifecycleOwner: LifecycleOwner? = null
    private var camera2Control: Camera2CameraControl? = null
    private val analysisExecutor = Executors.newSingleThreadExecutor()

    companion object {
        private const val TAG = "ManualCameraPlugin"
        const val CHANNEL = "com.tcw3.icamera/manual_camera"
    }

    // ── FlutterPlugin ─────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        appContext = null
        analysisExecutor.shutdown()
    }

    // ── ActivityAware ─────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        lifecycleOwner = binding.activity as? LifecycleOwner
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        lifecycleOwner = binding.activity as? LifecycleOwner
    }
    override fun onDetachedFromActivityForConfigChanges() { lifecycleOwner = null }
    override fun onDetachedFromActivity() { lifecycleOwner = null }

    // ── MethodCallHandler ─────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "bindControl" -> {
                val front = call.argument<Boolean>("front") ?: false
                bindCameraControl(front, result)
            }
            "setManualExposure" -> {
                val iso         = call.argument<Int>("iso")          ?: 100
                val shutterDenom = call.argument<Int>("shutterDenom") ?: 125
                applyManual(iso, shutterDenom, result)
            }
            "setAutoExposure" -> clearManual(result)
            "openGallery"     -> openGallery(result)
            else -> result.notImplemented()
        }
    }

    // ── Camera2 interop ───────────────────────────────────────────────────────

    /**
     * Binds a lightweight no-op ImageAnalysis use case to the same
     * ProcessCameraProvider + lifecycle the Flutter plugin uses.
     * CameraX merges use cases sharing a lifecycle/selector into one session,
     * so this does NOT restart the camera. The returned Camera gives us
     * Camera2CameraControl which can override any capture request parameter.
     */
    private fun bindCameraControl(front: Boolean, result: MethodChannel.Result) {
        val ctx   = appContext   ?: return result.error("NO_CTX",       "No application context", null)
        val owner = lifecycleOwner ?: return result.error("NO_LIFECYCLE", "No lifecycle owner",    null)

        val selector = if (front) CameraSelector.DEFAULT_FRONT_CAMERA
                       else       CameraSelector.DEFAULT_BACK_CAMERA

        Log.d(TAG, "bindCameraControl: front=$front")
        val future = ProcessCameraProvider.getInstance(ctx)
        future.addListener(Runnable {
            try {
                val provider = future.get()
                val analysis = ImageAnalysis.Builder().build().also { ia ->
                    ia.setAnalyzer(analysisExecutor) { proxy -> proxy.close() }
                }
                val camera = provider.bindToLifecycle(owner, selector, analysis)
                camera2Control = Camera2CameraControl.from(camera.cameraControl)
                Log.d(TAG, "bindCameraControl: OK — camera2Control=$camera2Control")
                result.success(null)
            } catch (e: Exception) {
                Log.e(TAG, "bindCameraControl failed", e)
                result.error("BIND_FAILED", e.message, null)
            }
        }, ctx.mainExecutor)
    }

    /**
     * Disable auto-exposure and lock sensor sensitivity (ISO) and
     * exposure time (shutter speed) to exact Camera2 values.
     * Camera2CameraControl settings have higher priority than CameraX
     * defaults, so they override whatever the Flutter plugin sets.
     */
    private fun applyManual(iso: Int, shutterDenom: Int, result: MethodChannel.Result) {
        val control = camera2Control
        if (control == null) {
            Log.w(TAG, "applyManual: camera2Control is null — bindControl may not have succeeded yet")
            return result.success(null)
        }

        val shutterNs = 1_000_000_000L / shutterDenom.coerceAtLeast(1)
        Log.d(TAG, "applyManual: ISO=$iso  shutter=1/$shutterDenom (${shutterNs}ns)  AE_MODE_OFF")

        val opts = CaptureRequestOptions.Builder()
            .setCaptureRequestOption(
                CaptureRequest.CONTROL_AE_MODE,
                CaptureRequest.CONTROL_AE_MODE_OFF
            )
            .setCaptureRequestOption(CaptureRequest.SENSOR_SENSITIVITY, iso)
            .setCaptureRequestOption(CaptureRequest.SENSOR_EXPOSURE_TIME, shutterNs)
            .build()

        control.setCaptureRequestOptions(opts)
        result.success(null)
    }

    /**
     * Clear all Camera2 overrides so CameraX auto-exposure resumes.
     */
    private fun clearManual(result: MethodChannel.Result) {
        val control = camera2Control ?: return result.success(null)
        control.setCaptureRequestOptions(CaptureRequestOptions.Builder().build())
        result.success(null)
    }

    private fun openGallery(result: MethodChannel.Result) {
        val ctx = appContext ?: return result.success(null)
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                type = "image/*"
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            ctx.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "openGallery failed", e)
        }
        result.success(null)
    }
}
