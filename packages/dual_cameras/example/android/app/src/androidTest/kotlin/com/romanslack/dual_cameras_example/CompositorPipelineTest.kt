package com.romanslack.dual_cameras_example

import android.graphics.Color
import android.graphics.SurfaceTexture
import android.media.MediaExtractor
import android.media.MediaFormat
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.view.Surface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.romanslack.dual_cameras_android.gl.CompositeLayout
import com.romanslack.dual_cameras_android.gl.DualCompositor
import com.romanslack.dual_cameras_android.gl.EglCore
import com.romanslack.dual_cameras_android.pipeline.Muxer
import com.romanslack.dual_cameras_android.pipeline.VideoEncoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * On-device verification of the REAL compositor path: synthetic frames are
 * produced into two `SurfaceTexture`s (the same external-OES inputs the cameras
 * feed), run through the actual [DualCompositor] (OES sampling, SDF rounded-PiP
 * shader, FBO, blit), then encoded to a valid `.mp4`. The only substitution vs.
 * production is the pixel source (Canvas-painted instead of camera) — the
 * compositor + encoder + muxer code is exercised exactly as it runs live.
 *
 * The one thing this cannot cover is two cameras delivering frames
 * concurrently, which the emulator hardware does not support.
 */
@RunWith(AndroidJUnit4::class)
class CompositorPipelineTest {

    @Test
    fun compositesSyntheticOesFramesToValidMp4() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val out = File(ctx.cacheDir, "compositor_test_${System.nanoTime()}.mp4")
        val w = 1280
        val h = 720
        val frames = 20
        val frameNs = 1_000_000_000L / 30

        val muxer = Muxer(out.absolutePath, expectAudio = false)
        val encoder = VideoEncoder(w, h, 4_000_000, 30, hevc = false, muxer = muxer)

        val egl = EglCore()
        val pbuffer = egl.createOffscreenSurface(1, 1)
        egl.makeCurrent(pbuffer)

        val backTex = genOes()
        val frontTex = genOes()
        val backSt = SurfaceTexture(backTex).apply { setDefaultBufferSize(w, h) }
        val frontSt = SurfaceTexture(frontTex).apply { setDefaultBufferSize(w / 3, h / 3) }
        val backSurface = Surface(backSt)
        val frontSurface = Surface(frontSt)

        val compositor = DualCompositor(w, h)
        val encSurface = egl.createWindowSurface(encoder.inputSurface)
        encoder.start()

        val layout = CompositeLayout(
            pictureInPicture = true, primaryFront = false,
            insetLeft = 0.68f, insetTop = 0.68f, insetRight = 0.96f, insetBottom = 0.96f,
            cornerRadiusPx = 16f, mirrorFront = true, splitVertical = false,
        )
        val backMatrix = FloatArray(16)
        val frontMatrix = FloatArray(16)

        for (i in 0 until frames) {
            paint(backSurface, Color.rgb((i * 12) % 255, 80, 160))
            paint(frontSurface, Color.rgb(220, (i * 9) % 255, 60))
            Thread.sleep(8) // let the producer buffer reach the SurfaceTexture

            egl.makeCurrent(pbuffer)
            backSt.updateTexImage(); backSt.getTransformMatrix(backMatrix)
            frontSt.updateTexImage(); frontSt.getTransformMatrix(frontMatrix)

            compositor.drawScene(layout, backTex, backMatrix, frontTex, frontMatrix)

            egl.makeCurrent(encSurface)
            compositor.blit(w, h)
            egl.setPresentationTime(encSurface, i * frameNs)
            egl.swapBuffers(encSurface)
        }

        encoder.signalEndOfStream()
        Thread.sleep(1500)
        egl.makeCurrent(pbuffer)
        egl.releaseSurface(encSurface)
        encoder.release()
        muxer.stopAndRelease()
        compositor.release()
        backSurface.release(); frontSurface.release()
        backSt.release(); frontSt.release()
        egl.releaseSurface(pbuffer)
        egl.release()

        assertTrue("output exists", out.exists())
        assertTrue("output non-empty", out.length() > 0)

        val extractor = MediaExtractor()
        extractor.setDataSource(out.absolutePath)
        var foundVideo = false
        var vw = 0
        var vh = 0
        for (t in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(t)
            if ((format.getString(MediaFormat.KEY_MIME) ?: "").startsWith("video/")) {
                foundVideo = true
                vw = format.getInteger(MediaFormat.KEY_WIDTH)
                vh = format.getInteger(MediaFormat.KEY_HEIGHT)
            }
        }
        extractor.release()

        assertTrue("composited mp4 has a video track", foundVideo)
        assertEquals(w, vw)
        assertEquals(h, vh)
        out.delete()
    }

    private fun paint(surface: Surface, color: Int) {
        val canvas = surface.lockCanvas(null)
        canvas.drawColor(color)
        surface.unlockCanvasAndPost(canvas)
    }

    private fun genOes(): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, ids[0])
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return ids[0]
    }
}
