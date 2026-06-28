package com.romanslack.dual_cameras_android.camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.ConcurrentCamera
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.util.concurrent.Executor

/**
 * Binds the front + back cameras concurrently (CameraX) and delivers each
 * feed into one of the GL compositor's [Surface]s. We deliberately do NOT use
 * CompositionSettings — the cameras are texture sources only (MASTER_PLAN §4).
 */
class CameraSource(private val context: Context) {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { mainHandler.post(it) }
    private val lifecycle = SimpleLifecycleOwner()
    private var provider: ProcessCameraProvider? = null

    fun bind(
        backSurface: Surface,
        frontSurface: Surface,
        onResolution: (isFront: Boolean, width: Int, height: Int) -> Unit,
        onRotation: (isFront: Boolean, degrees: Int) -> Unit,
        onError: (Throwable) -> Unit,
    ) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                val cameraProvider = future.get()
                provider = cameraProvider
                cameraProvider.unbindAll()
                Log.i(TAG, "provider ready; concurrentInfos=${cameraProvider.availableConcurrentCameraInfos.size}")

                // Let each camera run its NATIVE resolution/aspect — forcing
                // 16:9 makes the HAL pre-stretch the sensor's 4:3, which we
                // can't undo. The compositor center-crops to fit the canvas.
                val backPreview = Preview.Builder().build().also {
                    it.setSurfaceProvider(mainExecutor) { request ->
                        Log.i(TAG, "back surface requested ${request.resolution}")
                        onResolution(false, request.resolution.width, request.resolution.height)
                        request.provideSurface(backSurface, mainExecutor) {
                            Log.i(TAG, "back surface released ${it.resultCode}")
                        }
                    }
                }
                val frontPreview = Preview.Builder().build().also {
                    it.setSurfaceProvider(mainExecutor) { request ->
                        Log.i(TAG, "front surface requested ${request.resolution}")
                        onResolution(true, request.resolution.width, request.resolution.height)
                        request.provideSurface(frontSurface, mainExecutor) {
                            Log.i(TAG, "front surface released ${it.resultCode}")
                        }
                    }
                }
                val backConfig = ConcurrentCamera.SingleCameraConfig(
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    UseCaseGroup.Builder().addUseCase(backPreview).build(),
                    lifecycle,
                )
                val frontConfig = ConcurrentCamera.SingleCameraConfig(
                    CameraSelector.DEFAULT_FRONT_CAMERA,
                    UseCaseGroup.Builder().addUseCase(frontPreview).build(),
                    lifecycle,
                )
                lifecycle.start()
                val cam = cameraProvider.bindToLifecycle(listOf(backConfig, frontConfig))
                Log.i(TAG, "bindToLifecycle OK; cameras=${cam.cameras.size}")
                for (camera in cam.cameras) {
                    val info = camera.cameraInfo
                    val isFront = info.lensFacing == CameraSelector.LENS_FACING_FRONT
                    Log.i(TAG, "${if (isFront) "front" else "back"} sensorRotation=${info.sensorRotationDegrees}")
                    onRotation(isFront, info.sensorRotationDegrees)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "bind failed", t)
                onError(t)
            }
        }, mainExecutor)
    }

    fun release() {
        mainHandler.post {
            try {
                provider?.unbindAll()
            } catch (_: Throwable) {
            }
            lifecycle.stop()
            provider = null
        }
    }

    private companion object {
        const val TAG = "DualCam"
    }

    /** Minimal always-resumed LifecycleOwner for the headless camera session. */
    private class SimpleLifecycleOwner : LifecycleOwner {
        private val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry

        fun start() {
            registry.currentState = Lifecycle.State.RESUMED
        }

        fun stop() {
            registry.currentState = Lifecycle.State.DESTROYED
        }
    }
}
