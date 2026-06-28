package com.romanslack.dual_cameras_example

import android.media.MediaExtractor
import android.media.MediaFormat
import android.opengl.GLES20
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.romanslack.dual_cameras_android.gl.EglCore
import com.romanslack.dual_cameras_android.pipeline.Muxer
import com.romanslack.dual_cameras_android.pipeline.VideoEncoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * On-device verification of the highest-risk runtime path: the real
 * [VideoEncoder] (MediaCodec surface input) -> [Muxer] (MediaMuxer) producing a
 * valid, playable .mp4. The camera/compositor are substituted with synthetic
 * GL frames because the emulator cannot run two cameras concurrently — but this
 * exercises the actual encode/mux/EOS/presentation-time machinery end to end.
 */
@RunWith(AndroidJUnit4::class)
class EncoderPipelineTest {

    @Test
    fun encodesSyntheticFramesToValidMp4() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val out = File(ctx.cacheDir, "encoder_test_${System.nanoTime()}.mp4")
        val width = 1280
        val height = 720
        val frames = 30
        val frameNs = 1_000_000_000L / 30

        val muxer = Muxer(out.absolutePath, expectAudio = false)
        val encoder = VideoEncoder(
            width, height, bitRate = 4_000_000, frameRate = 30,
            hevc = false, muxer = muxer,
        )

        val egl = EglCore()
        val surface = egl.createWindowSurface(encoder.inputSurface)
        egl.makeCurrent(surface)
        encoder.start()

        for (i in 0 until frames) {
            // A moving test pattern so every frame differs.
            GLES20.glClearColor((i % frames) / frames.toFloat(), 0.35f, 0.6f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            egl.setPresentationTime(surface, i * frameNs)
            egl.swapBuffers(surface)
        }
        encoder.signalEndOfStream()
        Thread.sleep(1500) // let the drain thread flush EOS into the muxer
        egl.releaseSurface(surface)
        encoder.release()
        muxer.stopAndRelease()
        egl.release()

        assertTrue("output file exists", out.exists())
        assertTrue("output file is non-empty", out.length() > 0)

        val extractor = MediaExtractor()
        extractor.setDataSource(out.absolutePath)
        var foundVideo = false
        var vw = 0
        var vh = 0
        for (t in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(t)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith("video/")) {
                foundVideo = true
                vw = format.getInteger(MediaFormat.KEY_WIDTH)
                vh = format.getInteger(MediaFormat.KEY_HEIGHT)
            }
        }
        extractor.release()

        assertTrue("mp4 has a video track", foundVideo)
        assertEquals("width", width, vw)
        assertEquals("height", height, vh)

        out.delete()
    }
}
