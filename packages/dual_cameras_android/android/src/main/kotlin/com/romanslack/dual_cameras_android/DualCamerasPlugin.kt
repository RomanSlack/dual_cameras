package com.romanslack.dual_cameras_android

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.Surface
import java.util.concurrent.Executor
import com.romanslack.dual_cameras_android.camera.CameraSource
import com.romanslack.dual_cameras_android.gl.CompositeLayout
import com.romanslack.dual_cameras_android.pipeline.RenderThread
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * Android implementation of dual_cameras.
 *
 * Capability detection + Pigeon wiring (Phase 0), and the unified GLES
 * compositor -> MediaCodec/MediaMuxer recording pipeline (Phase 1). Photo
 * capture and the perf HUD land in Phase 2; see ARCHITECTURE.md.
 */
class DualCamerasPlugin : FlutterPlugin, DualCameraHostApi {

  private var context: Context? = null
  private var textureRegistry: TextureRegistry? = null
  private var flutterApi: DualCameraFlutterApi? = null

  private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
  private var renderThread: RenderThread? = null
  private var cameraSource: CameraSource? = null
  private var currentLayout: CompositeLayout? = null
  private var recordAudio = true
  private var hevc = false
  private var compositeW = 1280
  private var compositeH = 720
  private val mainHandler = Handler(Looper.getMainLooper())
  private val mainExecutor = Executor { mainHandler.post(it) }
  private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
  private var debugChannel: MethodChannel? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    textureRegistry = binding.textureRegistry
    flutterApi = DualCameraFlutterApi(binding.binaryMessenger)
    DualCameraHostApi.setUp(binding.binaryMessenger, this)
    debugChannel = MethodChannel(binding.binaryMessenger, DEBUG_CHANNEL).also {
      it.setMethodCallHandler(::handleDebug)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    releaseSession()
    DualCameraHostApi.setUp(binding.binaryMessenger, null)
    debugChannel?.setMethodCallHandler(null)
    debugChannel = null
    flutterApi = null
    textureRegistry = null
    context = null
  }

  // --- DualCameraHostApi ---

  override fun probeSupport(callback: (Result<CameraCapabilities>) -> Unit) {
    callback(Result.success(detectCapabilities()))
  }

  override fun initialize(
    config: RecordingConfig,
    callback: (Result<InitResult>) -> Unit,
  ) {
    val ctx = context
    val registry = textureRegistry
    if (ctx == null || registry == null) {
      callback(Result.failure(IllegalStateException("Plugin not attached")))
      return
    }
    try {
      val (w, h) = resolutionFor(config.resolution)
      compositeW = w
      compositeH = h
      recordAudio = config.recordAudio
      hevc = config.codec == VideoCodec.HEVC
      val layout = toCompositeLayout(config.layout, w, h)
      currentLayout = layout

      val producer = registry.createSurfaceProducer()
      producer.setSize(w, h)
      surfaceProducer = producer

      val render = RenderThread(w, h, layout)
      val source = CameraSource(ctx)
      render.listener = object : RenderThread.Listener {
        override fun onCameraSurfaces(back: Surface, front: Surface) {
          source.bind(
            back, front,
            onResolution = { isFront, sw, sh -> render.setSourceSize(isFront, sw, sh) },
            onRotation = { isFront, deg -> render.setSourceRotation(isFront, deg) },
            onError = { err ->
              flutterApi?.onError("camera_bind", err.message ?: "bind failed") {}
            },
          )
        }
      }
      render.statsListener = { fps, ms, dropped ->
        mainHandler.post {
          flutterApi?.onFrameStats(
            FrameStats(fps, ms, dropped, ThermalLevel.NOMINAL),
          ) {}
        }
      }
      render.setPreviewSurface(producer.surface, w, h)
      producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
        override fun onSurfaceAvailable() {
          render.setPreviewSurface(producer.surface, w, h)
        }

        override fun onSurfaceDestroyed() {
          render.setPreviewSurface(null, w, h)
        }
      })
      renderThread = render
      cameraSource = source

      // Listener is now wired; hand over the camera surfaces to start the feed.
      render.startCameraFeed()

      registerThermalListener(ctx)
      val textureId = producer.id()
      flutterApi?.onReady(textureId) {}
      callback(Result.success(InitResult(textureId, detectCapabilities())))
    } catch (t: Throwable) {
      callback(Result.failure(t))
    }
  }

  /** Proactive thermal monitoring (ThermalGovernor, ARCHITECTURE.md §10). */
  private fun registerThermalListener(ctx: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
    if (thermalListener != null) return
    val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
    val listener = PowerManager.OnThermalStatusChangedListener { status ->
      flutterApi?.onThermal(mapThermal(status)) {}
    }
    pm.addThermalStatusListener(mainExecutor, listener)
    thermalListener = listener
  }

  private fun unregisterThermalListener() {
    val ctx = context ?: return
    val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
    thermalListener?.let {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) pm.removeThermalStatusListener(it)
    }
    thermalListener = null
  }

  private fun mapThermal(status: Int): ThermalLevel = when {
    status >= PowerManager.THERMAL_STATUS_CRITICAL -> ThermalLevel.CRITICAL
    status == PowerManager.THERMAL_STATUS_SEVERE -> ThermalLevel.SERIOUS
    status == PowerManager.THERMAL_STATUS_MODERATE -> ThermalLevel.FAIR
    else -> ThermalLevel.NOMINAL
  }

  override fun startRecording(callback: (Result<Unit>) -> Unit) {
    val render = renderThread
    val ctx = context
    if (render == null || ctx == null) {
      callback(notYet("startRecording (not initialized)"))
      return
    }
    val path = File(ctx.cacheDir, "dcr_${System.nanoTime()}.mp4").absolutePath
    render.startRecording(path, recordAudio, hevc)
    flutterApi?.onRecordingStarted {}
    callback(Result.success(Unit))
  }

  override fun stopRecording(callback: (Result<String>) -> Unit) {
    val render = renderThread
    if (render == null) {
      callback(notYet("stopRecording (not initialized)"))
      return
    }
    render.stopRecordingResult { path ->
      mainHandler.post {
        flutterApi?.onRecordingStopped(path) {}
        callback(Result.success(path))
      }
    }
    return
  }

  override fun takePhoto(callback: (Result<String>) -> Unit) {
    val render = renderThread
    val ctx = context
    if (render == null || ctx == null) {
      callback(notYet("takePhoto (not initialized)"))
      return
    }
    val path = File(ctx.cacheDir, "dcr_${System.nanoTime()}.jpg").absolutePath
    render.takePhoto(
      path,
      done = { mainHandler.post { callback(Result.success(it)) } },
      fail = { mainHandler.post { callback(Result.failure(it)) } },
    )
  }

  override fun swapPrimary(callback: (Result<Unit>) -> Unit) {
    val layout = currentLayout ?: return callback(notYet("swapPrimary (not initialized)"))
    val swapped = layout.copy(primaryFront = !layout.primaryFront)
    currentLayout = swapped
    renderThread?.updateLayout(swapped)
    callback(Result.success(Unit))
  }

  override fun setLayout(layout: LayoutConfig, callback: (Result<Unit>) -> Unit) {
    if (surfaceProducer == null) return callback(notYet("setLayout (not initialized)"))
    val composite = toCompositeLayout(layout, compositeW, compositeH)
    currentLayout = composite
    renderThread?.updateLayout(composite)
    callback(Result.success(Unit))
  }

  override fun dispose(callback: (Result<Unit>) -> Unit) {
    releaseSession()
    callback(Result.success(Unit))
  }

  // --- debug tuning channel (example app only) ---

  /**
   * Live geometry tuning for the example harness — rotation correction, front
   * mirror, and source-aspect override — so the front/back orientation and any
   * stretch can be dialed in on a real device without rebuilding native code.
   */
  private fun handleDebug(call: MethodCall, result: MethodChannel.Result) {
    val render = renderThread
    if (render == null) {
      result.error("not_init", "initialize() first", null)
      return
    }
    when (call.method) {
      "setRotationOffset" -> {
        val front = call.argument<Boolean>("front") ?: true
        val offset = call.argument<Int>("offset") ?: 0
        render.setRotationOffset(front, offset)
        result.success(null)
      }
      "setAspectOverride" -> {
        val front = call.argument<Boolean>("front") ?: true
        val aspect = (call.argument<Double>("aspect") ?: 0.0).toFloat()
        render.setAspectOverride(front, aspect)
        result.success(null)
      }
      "setMirrorFront" -> {
        val on = call.argument<Boolean>("on") ?: true
        currentLayout?.let {
          val updated = it.copy(mirrorFront = on)
          currentLayout = updated
          render.updateLayout(updated)
        }
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  // --- internals ---

  private fun releaseSession() {
    unregisterThermalListener()
    cameraSource?.release()
    cameraSource = null
    renderThread?.release()
    renderThread = null
    surfaceProducer?.release()
    surfaceProducer = null
    currentLayout = null
  }

  private fun <T> notYet(op: String): Result<T> =
    Result.failure(UnsupportedOperationException("$op is not available"))

  // Portrait canvas (vertical video). Width < height; the cameras are rotated
  // upright into it by the compositor using each sensor's orientation.
  private fun resolutionFor(res: DualResolution): Pair<Int, Int> = when (res) {
    DualResolution.SD480 -> 480 to 854
    DualResolution.HD720 -> 720 to 1280
    DualResolution.HD1080 -> 1080 to 1920
  }

  private fun toCompositeLayout(layout: LayoutConfig, w: Int, h: Int): CompositeLayout {
    val primaryFront = layout.primary == CameraLens.FRONT
    val pip = layout.mode == DualLayoutMode.PICTURE_IN_PICTURE
    val splitVertical = layout.mode == DualLayoutMode.SPLIT_VERTICAL

    // Inset rect in normalized [0,1] surface coords (origin top-left).
    // insetScale is a fraction of the SHORTER side (height), so a circle inset
    // is a true square in pixels; a rect inset matches the canvas aspect.
    val insetH = layout.insetScale
    val insetW = if (layout.circleInset) layout.insetScale * h / w else layout.insetScale
    val mx = layout.margin / w
    val my = layout.margin / h
    val (l, t, r, b) = when (layout.insetCorner) {
      InsetCorner.TOP_LEFT -> arrayOf(mx, my, mx + insetW, my + insetH)
      InsetCorner.TOP_RIGHT -> arrayOf(1 - mx - insetW, my, 1 - mx, my + insetH)
      InsetCorner.BOTTOM_LEFT -> arrayOf(mx, 1 - my - insetH, mx + insetW, 1 - my)
      InsetCorner.BOTTOM_RIGHT ->
        arrayOf(1 - mx - insetW, 1 - my - insetH, 1 - mx, 1 - my)
    }
    // A circle is the rounded-rect SDF on a square rect with radius = half side.
    val insetSidePx = (insetH * h).toFloat()
    val cornerRadiusPx =
      if (layout.circleInset) insetSidePx / 2f else layout.cornerRadius.toFloat()
    return CompositeLayout(
      pictureInPicture = pip,
      primaryFront = primaryFront,
      insetLeft = l.toFloat(),
      insetTop = t.toFloat(),
      insetRight = r.toFloat(),
      insetBottom = b.toFloat(),
      cornerRadiusPx = cornerRadiusPx,
      mirrorFront = layout.mirrorFront,
      splitVertical = splitVertical,
    )
  }

  /**
   * Detect whether this device can run front + back concurrently. Mirrors
   * MASTER_PLAN.md §4.1.
   */
  private fun detectCapabilities(): CameraCapabilities {
    val ctx = context ?: return CameraCapabilities(
      isSupported = false,
      reason = UnsupportedReason.NO_CONCURRENT_CAMERA,
    )
    val manager = ctx.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
      ?: return CameraCapabilities(
        isSupported = false,
        reason = UnsupportedReason.NO_CONCURRENT_CAMERA,
      )

    val supported = try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        manager.concurrentCameraIds.any { combo -> comboHasFrontAndBack(manager, combo) }
      } else {
        ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_CONCURRENT)
      }
    } catch (_: Throwable) {
      false
    }

    return if (supported) {
      CameraCapabilities(isSupported = true, maxWidth = 1280L, maxHeight = 720L)
    } else {
      CameraCapabilities(
        isSupported = false,
        reason = UnsupportedReason.NO_CONCURRENT_CAMERA,
      )
    }
  }

  private fun comboHasFrontAndBack(
    manager: CameraManager,
    combo: Set<String>,
  ): Boolean {
    var hasFront = false
    var hasBack = false
    for (id in combo) {
      val facing = try {
        manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
      } catch (_: Throwable) {
        null
      }
      when (facing) {
        CameraCharacteristics.LENS_FACING_FRONT -> hasFront = true
        CameraCharacteristics.LENS_FACING_BACK -> hasBack = true
      }
    }
    return hasFront && hasBack
  }

  private companion object {
    const val DEBUG_CHANNEL = "dual_cameras/debug"
  }
}
