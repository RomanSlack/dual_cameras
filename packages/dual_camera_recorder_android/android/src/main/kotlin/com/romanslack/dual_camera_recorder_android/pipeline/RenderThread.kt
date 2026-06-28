package com.romanslack.dual_camera_recorder_android.pipeline

import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Message
import android.util.Log
import android.view.Surface
import com.romanslack.dual_camera_recorder_android.gl.CompositeLayout
import com.romanslack.dual_camera_recorder_android.gl.DualCompositor
import com.romanslack.dual_camera_recorder_android.gl.EglCore
import java.util.concurrent.CountDownLatch

/**
 * Owns the sole GL thread and EGLContext (ARCHITECTURE.md §4). Holds the two
 * camera external-OES textures, the [DualCompositor], and the consumer
 * surfaces (Flutter preview + encoder input). Composites once per back-camera
 * frame and fans out.
 */
class RenderThread(
    private val width: Int,
    private val height: Int,
    private var layout: CompositeLayout,
) {
    interface Listener {
        fun onCameraSurfaces(back: Surface, front: Surface)
    }

    private val thread = HandlerThread("dcr-gl").apply { start() }
    private val handler = Handler(thread.looper, ::handleMessage)

    private lateinit var egl: EglCore
    private var bootstrapSurface: EGLSurface? = null

    private var backTexId = 0
    private var frontTexId = 0
    private lateinit var backSt: SurfaceTexture
    private lateinit var frontSt: SurfaceTexture
    private val backMatrix = FloatArray(16)
    private val frontMatrix = FloatArray(16)

    private lateinit var compositor: DualCompositor

    private var previewSurface: EGLSurface? = null
    private var previewW = width
    private var previewH = height

    private var encoderSurface: EGLSurface? = null
    private var videoEncoder: VideoEncoder? = null
    private var audioEncoder: AudioEncoder? = null
    private var muxer: Muxer? = null
    @Volatile private var recording = false
    private var startNanos = 0L
    private var outputPath = ""

    @Volatile var listener: Listener? = null

    /** Reports (fps, meanCompositeMs, droppedFrames) ~twice a second. */
    var statsListener: ((Double, Double, Long) -> Unit)? = null
    private var windowStartNs = 0L
    private var windowFrames = 0
    private var windowCompositeNs = 0L
    private var droppedFrames = 0L
    private var backFrameCount = 0L
    private var frontFrameCount = 0L
    private var encoderFrameCount = 0L

    init {
        val latch = CountDownLatch(1)
        handler.post {
            bootstrap()
            latch.countDown()
        }
        latch.await()
    }

    private fun bootstrap() {
        egl = EglCore()
        bootstrapSurface = egl.createOffscreenSurface(1, 1).also { egl.makeCurrent(it) }

        backTexId = genOesTexture()
        frontTexId = genOesTexture()
        backSt = SurfaceTexture(backTexId).apply {
            setDefaultBufferSize(width, height)
            setOnFrameAvailableListener({
                if (backFrameCount == 0L) Log.i(TAG, "first BACK frame available")
                backFrameCount++
                requestDraw()
            }, handler)
        }
        frontSt = SurfaceTexture(frontTexId).apply {
            setDefaultBufferSize(width, height)
            setOnFrameAvailableListener({
                if (frontFrameCount == 0L) Log.i(TAG, "first FRONT frame available")
                frontFrameCount++
            }, handler)
        }
        compositor = DualCompositor(width, height)
        Log.i(TAG, "bootstrap done")
    }

    /**
     * Hand the two camera external-OES surfaces to the listener so it can bind
     * the cameras. Must be called *after* [listener] is set — bootstrap runs in
     * the constructor before the caller can wire the listener.
     */
    fun startCameraFeed() {
        handler.post {
            Log.i(TAG, "handing camera surfaces")
            listener?.onCameraSurfaces(Surface(backSt), Surface(frontSt))
        }
    }

    fun updateLayout(newLayout: CompositeLayout) {
        handler.post { layout = newLayout }
    }

    /** Report a camera's real frame size so the compositor can aspect-fill. */
    fun setSourceSize(isFront: Boolean, w: Int, h: Int) {
        handler.post {
            Log.i(TAG, "source size ${if (isFront) "front" else "back"} ${w}x$h")
            // Match the texture buffer to the native frame so the camera frame
            // isn't scaled (which would distort the aspect before we crop it).
            (if (isFront) frontSt else backSt).setDefaultBufferSize(w, h)
            compositor.setSourceSize(isFront, w, h)
        }
    }

    /** Report a camera's sensor orientation so it's rotated upright. */
    fun setSourceRotation(isFront: Boolean, degrees: Int) {
        handler.post { compositor.setSourceRotation(isFront, degrees) }
    }

    /** Flutter SurfaceProducer surface for the live preview. */
    fun setPreviewSurface(surface: Surface?, w: Int, h: Int) {
        handler.post {
            previewSurface?.let { egl.releaseSurface(it) }
            previewSurface = surface?.let { egl.createWindowSurface(it) }
            previewW = w
            previewH = h
        }
    }

    fun startRecording(path: String, recordAudio: Boolean, hevc: Boolean) {
        handler.post {
            outputPath = path
            startNanos = System.nanoTime()
            val mux = Muxer(outputPath, expectAudio = recordAudio)
            val venc = VideoEncoder(
                width, height,
                bitRate = 4_000_000, frameRate = 30, hevc = hevc, muxer = mux,
            )
            encoderSurface = egl.createWindowSurface(venc.inputSurface)
            venc.start()
            if (recordAudio) {
                @Suppress("MissingPermission")
                audioEncoder = AudioEncoder(mux, startNanos).apply { start() }
            }
            videoEncoder = venc
            muxer = mux
            recording = true
        }
    }

    fun stopRecordingResult(done: (String) -> Unit) {
        handler.post {
            recording = false
            audioEncoder?.stop()
            audioEncoder = null
            videoEncoder?.signalEndOfStream()
            val path = outputPath
            // Give the encoder a moment to flush EOS before tearing down.
            handler.postDelayed({
                videoEncoder?.release()
                videoEncoder = null
                encoderSurface?.let { egl.releaseSurface(it) }
                encoderSurface = null
                muxer?.stopAndRelease()
                muxer = null
                done(path)
            }, 150)
        }
    }

    /**
     * Capture a composited still (Phase 2): compose the latest frames into the
     * FBO, read it back, and JPEG-encode off the GL thread so the recording
     * cadence isn't stalled.
     */
    fun takePhoto(path: String, done: (String) -> Unit, fail: (Throwable) -> Unit) {
        handler.post {
            try {
                backSt.updateTexImage()
                backSt.getTransformMatrix(backMatrix)
                try {
                    frontSt.updateTexImage()
                    frontSt.getTransformMatrix(frontMatrix)
                } catch (_: Throwable) {
                }
                compositor.drawScene(
                    layout, backTexId, backMatrix, frontTexId, frontMatrix,
                )
                egl.makeCurrent(bootstrapSurface!!)
                val pixels = compositor.readComposite()
                val w = compositor.widthPx
                val h = compositor.heightPx
                Thread({
                    try {
                        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        pixels.rewind()
                        bmp.copyPixelsFromBuffer(pixels)
                        java.io.FileOutputStream(path).use {
                            bmp.compress(Bitmap.CompressFormat.JPEG, 92, it)
                        }
                        bmp.recycle()
                        done(path)
                    } catch (t: Throwable) {
                        fail(t)
                    }
                }, "dcr-photo-encode").start()
            } catch (t: Throwable) {
                fail(t)
            }
        }
    }

    private fun reportStats(composeNs: Long) {
        windowFrames++
        windowCompositeNs += composeNs
        val now = System.nanoTime()
        if (windowStartNs == 0L) windowStartNs = now
        val elapsed = now - windowStartNs
        if (elapsed >= 500_000_000L) {
            val fps = windowFrames * 1e9 / elapsed
            val meanMs = (windowCompositeNs.toDouble() / windowFrames) / 1e6
            statsListener?.invoke(fps, meanMs, droppedFrames)
            windowStartNs = now
            windowFrames = 0
            windowCompositeNs = 0L
        }
    }

    private fun requestDraw() {
        if (handler.hasMessages(MSG_DRAW)) {
            // A draw is already queued; this back-camera frame is coalesced away.
            droppedFrames++
        } else {
            handler.sendEmptyMessage(MSG_DRAW)
        }
    }

    private fun handleMessage(msg: Message): Boolean {
        if (msg.what == MSG_DRAW) drawFrame()
        return true
    }

    private var drawCount = 0L

    private fun drawFrame() {
        if (drawCount < 3L) {
            Log.i(TAG, "drawFrame #$drawCount previewSurface=${previewSurface != null} recording=$recording")
        }
        drawCount++
        // Latest from both cameras; re-query the transform every frame (§12).
        backSt.updateTexImage()
        backSt.getTransformMatrix(backMatrix)
        try {
            frontSt.updateTexImage()
            frontSt.getTransformMatrix(frontMatrix)
        } catch (_: Throwable) {
            // Front may not have produced a frame yet; keep last matrix.
        }

        if (statsListener != null) {
            // Debug HUD path only: glFinish to time the composite. Never done
            // when the HUD is off (ARCHITECTURE.md §10 / principle 9).
            val composeStart = System.nanoTime()
            compositor.drawScene(layout, backTexId, backMatrix, frontTexId, frontMatrix)
            GLES20.glFinish()
            reportStats(System.nanoTime() - composeStart)
        } else {
            compositor.drawScene(layout, backTexId, backMatrix, frontTexId, frontMatrix)
        }

        previewSurface?.let { surface ->
            egl.makeCurrent(surface)
            compositor.blit(previewW, previewH)
            egl.swapBuffers(surface)
            if (drawCount <= 3L) {
                val err = GLES20.glGetError()
                Log.i(TAG, "preview blit done ${previewW}x${previewH} glErr=$err")
            }
        }

        if (recording) {
            encoderSurface?.let { surface ->
                egl.makeCurrent(surface)
                compositor.blit(width, height)
                // Video + audio must share ONE clock/epoch or the muxer emits a
                // bogus duration and the tracks drift. AudioEncoder is based on
                // System.nanoTime()-startNanos, so the video frame uses the same
                // (the camera SurfaceTexture clock is a different base on some
                // devices — e.g. ~38h offset on Pixel 8).
                egl.setPresentationTime(surface, System.nanoTime() - startNanos)
                egl.swapBuffers(surface)
                if (encoderFrameCount == 0L) Log.i(TAG, "first ENCODER frame written")
                encoderFrameCount++
            }
        }
        egl.makeCurrent(bootstrapSurface!!)
    }

    fun release() {
        val latch = CountDownLatch(1)
        handler.post {
            if (recording) recording = false
            audioEncoder?.stop()
            videoEncoder?.release()
            muxer?.stopAndRelease()
            previewSurface?.let { egl.releaseSurface(it) }
            encoderSurface?.let { egl.releaseSurface(it) }
            compositor.release()
            backSt.release()
            frontSt.release()
            bootstrapSurface?.let { egl.releaseSurface(it) }
            egl.release()
            latch.countDown()
        }
        latch.await()
        thread.quitSafely()
    }

    private fun genOesTexture(): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        val tex = ids[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )
        return tex
    }

    companion object {
        private const val MSG_DRAW = 1
        private const val TAG = "DualCam"
    }
}
