package com.romanslack.dual_camera_recorder_android.gl

import android.opengl.GLES11Ext
import android.opengl.GLES20
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Layout geometry handed down from Dart (normalized, [LayoutConfig]). Computed
 * once and applied identically to preview, recording, and stills so they can
 * never drift (ARCHITECTURE.md §7).
 */
data class CompositeLayout(
    val pictureInPicture: Boolean,
    val primaryFront: Boolean,
    // PiP inset rect in normalized [0,1] surface coords (origin top-left).
    val insetLeft: Float,
    val insetTop: Float,
    val insetRight: Float,
    val insetBottom: Float,
    val cornerRadiusPx: Float,
    val mirrorFront: Boolean,
    // Split layouts.
    val splitVertical: Boolean,
)

/**
 * The unified GPU compositor: two external-OES camera textures -> one composed
 * scene. Renders the primary full-frame, then the secondary either as a rounded
 * inset (PiP) or a half (split), mirroring the front feed.
 *
 * Render-once-fan-out: [drawScene] composes into an offscreen FBO; [blit]
 * copies that FBO to each consumer EGLSurface, so we never composite twice
 * (ARCHITECTURE.md §3 principle 2).
 */
class DualCompositor(private var width: Int, private var height: Int) {

    private var oesProgram = 0
    private var blitProgram = 0

    // OES program handles.
    private var oesPosLoc = 0
    private var oesTexLoc = 0
    private var oesMvpLoc = 0
    private var oesStLoc = 0
    private var oesMirrorLoc = 0
    private var oesRoundLoc = 0
    private var oesRadiusLoc = 0
    private var oesInsetHalfLoc = 0
    private var oesSamplerLoc = 0
    private var oesXformLoc = 0

    // Real frame aspect (w/h) of each camera, so we center-crop instead of
    // stretch. Default to the composite aspect until the camera reports.
    private var backSrcAspect = width.toFloat() / height
    private var frontSrcAspect = width.toFloat() / height

    // Sensor orientation per camera, to rotate the landscape sensor upright into
    // the portrait canvas.
    private var backRotation = 0
    private var frontRotation = 0

    // Blit program handles.
    private var blitPosLoc = 0
    private var blitTexLoc = 0
    private var blitSamplerLoc = 0

    private var fboId = 0
    private var fboTex = 0

    private val fullQuad: FloatBuffer = quad(0f, 0f, 1f, 1f)
    private val texQuad: FloatBuffer = texCoords()

    init {
        oesProgram = buildProgram(VERTEX, OES_FRAGMENT)
        oesPosLoc = GLES20.glGetAttribLocation(oesProgram, "aPosition")
        oesTexLoc = GLES20.glGetAttribLocation(oesProgram, "aTexCoord")
        oesMvpLoc = GLES20.glGetUniformLocation(oesProgram, "uMvp")
        oesStLoc = GLES20.glGetUniformLocation(oesProgram, "uTexMatrix")
        oesMirrorLoc = GLES20.glGetUniformLocation(oesProgram, "uMirror")
        oesRoundLoc = GLES20.glGetUniformLocation(oesProgram, "uRounded")
        oesRadiusLoc = GLES20.glGetUniformLocation(oesProgram, "uRadiusPx")
        oesInsetHalfLoc = GLES20.glGetUniformLocation(oesProgram, "uInsetHalfPx")
        oesSamplerLoc = GLES20.glGetUniformLocation(oesProgram, "uTexture")
        oesXformLoc = GLES20.glGetUniformLocation(oesProgram, "uTexXform")

        blitProgram = buildProgram(BLIT_VERTEX, BLIT_FRAGMENT)
        blitPosLoc = GLES20.glGetAttribLocation(blitProgram, "aPosition")
        blitTexLoc = GLES20.glGetAttribLocation(blitProgram, "aTexCoord")
        blitSamplerLoc = GLES20.glGetUniformLocation(blitProgram, "uTexture")

        createFbo(width, height)
    }

    fun resize(w: Int, h: Int) {
        if (w == width && h == height) return
        width = w
        height = h
        releaseFbo()
        createFbo(w, h)
    }

    /** A camera's real frame aspect, for center-crop (avoids stretching). */
    fun setSourceSize(isFront: Boolean, w: Int, h: Int) {
        if (h <= 0) return
        val a = w.toFloat() / h
        if (isFront) frontSrcAspect = a else backSrcAspect = a
    }

    /**
     * A camera's sensor orientation in degrees. ROTATION_OFFSET is the empirical
     * correction for how the SurfaceTexture transform's Y-flip composes with our
     * rotation (so the upright direction comes out right).
     */
    fun setSourceRotation(isFront: Boolean, degrees: Int) {
        val offset = if (isFront) FRONT_ROTATION_OFFSET else BACK_ROTATION_OFFSET
        val d = (((degrees + offset) % 360) + 360) % 360
        if (isFront) frontRotation = d else backRotation = d
    }

    /**
     * Column-major mat2 mapping target-rect normalized-centered coords to source
     * normalized-centered coords: rotates the source upright by [rotationDeg] and
     * cover-crops [srcAspect] into [targetAspect] without distortion.
     */
    private fun texXform(srcAspect: Float, targetAspect: Float, rotationDeg: Int): FloatArray {
        val s = srcAspect
        val t = targetAspect
        val rad = Math.toRadians(rotationDeg.toDouble())
        val cos = Math.cos(rad).toFloat()
        val sin = Math.sin(rad).toFloat()
        // Rotated source iso half-extents (height-normalized) cover factor.
        val rotHalfX = Math.abs(cos) * (s / 2f) + Math.abs(sin) * 0.5f
        val rotHalfY = Math.abs(sin) * (s / 2f) + Math.abs(cos) * 0.5f
        val kappa = maxOf((t / 2f) / rotHalfX, 0.5f / rotHalfY)
        val inv = 1f / kappa
        // M = (1/k) * diag(1/s, 1) * R(-θ) * diag(t, 1), R(-θ)=[[cos,sin],[-sin,cos]].
        val m00 = inv * cos * t / s
        val m01 = inv * sin / s
        val m10 = inv * (-sin) * t
        val m11 = inv * cos
        // Column-major: [col0(row0,row1), col1(row0,row1)].
        return floatArrayOf(m00, m10, m01, m11)
    }

    /**
     * Compose the scene into the offscreen FBO. [backTex]/[frontTex] are
     * external-OES texture ids; [backSt]/[frontSt] their 4x4 transform matrices
     * (re-queried each frame — see §12).
     */
    fun drawScene(
        layout: CompositeLayout,
        backTex: Int,
        backSt: FloatArray,
        frontTex: Int,
        frontSt: FloatArray,
        primaryTex: Int = if (layout.primaryFront) frontTex else backTex,
    ) {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        val primaryFront = layout.primaryFront
        val pTex = if (primaryFront) frontTex else backTex
        val pSt = if (primaryFront) frontSt else backSt
        val sTex = if (primaryFront) backTex else frontTex
        val sSt = if (primaryFront) backSt else frontSt
        val pSrcAspect = if (primaryFront) frontSrcAspect else backSrcAspect
        val sSrcAspect = if (primaryFront) backSrcAspect else frontSrcAspect
        val pRot = if (primaryFront) frontRotation else backRotation
        val sRot = if (primaryFront) backRotation else frontRotation
        val primaryMirror = primaryFront && layout.mirrorFront
        val secondaryMirror = !primaryFront && layout.mirrorFront
        val canvasAspect = width.toFloat() / height

        if (layout.pictureInPicture) {
            // Primary fills the frame (rotated upright, cropped to canvas aspect).
            drawOes(
                pTex, pSt, IDENTITY, primaryMirror, rounded = false,
                xform = texXform(pSrcAspect, canvasAspect, pRot),
            )
            // Secondary inset, rotated upright + cropped to the inset's aspect.
            val insetW = (layout.insetRight - layout.insetLeft) * width
            val insetH = (layout.insetBottom - layout.insetTop) * height
            val mvp = rectToMvp(
                layout.insetLeft, layout.insetTop, layout.insetRight, layout.insetBottom,
            )
            drawOes(
                sTex, sSt, mvp, secondaryMirror,
                rounded = layout.cornerRadiusPx > 0f,
                rectPx = floatArrayOf(
                    layout.insetLeft * width, layout.insetTop * height,
                    layout.insetRight * width, layout.insetBottom * height,
                ),
                radiusPx = layout.cornerRadiusPx,
                xform = texXform(sSrcAspect, insetW / insetH, sRot),
            )
        } else {
            // Split: two halves.
            val (pRect, sRect) = if (layout.splitVertical) {
                floatArrayOf(0f, 0f, 1f, 0.5f) to floatArrayOf(0f, 0.5f, 1f, 1f)
            } else {
                floatArrayOf(0f, 0f, 0.5f, 1f) to floatArrayOf(0.5f, 0f, 1f, 1f)
            }
            val pMvp = rectToMvp(pRect[0], pRect[1], pRect[2], pRect[3])
            val sMvp = rectToMvp(sRect[0], sRect[1], sRect[2], sRect[3])
            val halfAspect = if (layout.splitVertical) canvasAspect * 2f else canvasAspect / 2f
            drawOes(
                pTex, pSt, pMvp, primaryMirror, rounded = false,
                xform = texXform(pSrcAspect, halfAspect, pRot),
            )
            drawOes(
                sTex, sSt, sMvp, secondaryMirror, rounded = false,
                xform = texXform(sSrcAspect, halfAspect, sRot),
            )
        }
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
    }

    /** Copy the composed FBO texture onto the currently-current EGLSurface. */
    fun blit(viewportW: Int, viewportH: Int) {
        GLES20.glUseProgram(blitProgram)
        GLES20.glViewport(0, 0, viewportW, viewportH)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTex)
        GLES20.glUniform1i(blitSamplerLoc, 0)

        bindAttrib(blitPosLoc, fullQuad, 2)
        bindAttrib(blitTexLoc, texQuad, 2)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(blitPosLoc)
        GLES20.glDisableVertexAttribArray(blitTexLoc)
    }

    val composedTextureId: Int get() = fboTex
    val widthPx: Int get() = width
    val heightPx: Int get() = height

    /**
     * Read the composed FBO back to CPU for a still capture (Phase 2). Returns
     * RGBA pixels, rows flipped so the result is top-down (GL origin is
     * bottom-left). Synchronous — call off the recording cadence (§8).
     */
    fun readComposite(): ByteBuffer {
        val buf = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.nativeOrder())
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        GLES20.glReadPixels(
            0, 0, width, height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf,
        )
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        buf.rewind()
        // Flip vertically into a second buffer.
        val flipped = ByteBuffer.allocateDirect(width * height * 4)
            .order(ByteOrder.nativeOrder())
        val rowBytes = width * 4
        val row = ByteArray(rowBytes)
        for (y in 0 until height) {
            buf.position((height - 1 - y) * rowBytes)
            buf.get(row, 0, rowBytes)
            flipped.position(y * rowBytes)
            flipped.put(row)
        }
        flipped.rewind()
        return flipped
    }

    private fun drawOes(
        texId: Int,
        st: FloatArray,
        mvp: FloatArray,
        mirror: Boolean,
        rounded: Boolean,
        rectPx: FloatArray = ZERO4,
        radiusPx: Float = 0f,
        xform: FloatArray = IDENTITY2,
    ) {
        GLES20.glUseProgram(oesProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES20.glUniform1i(oesSamplerLoc, 0)
        GLES20.glUniformMatrix4fv(oesMvpLoc, 1, false, mvp, 0)
        GLES20.glUniformMatrix4fv(oesStLoc, 1, false, st, 0)
        GLES20.glUniform1f(oesMirrorLoc, if (mirror) 1f else 0f)
        GLES20.glUniformMatrix2fv(oesXformLoc, 1, false, xform, 0)
        GLES20.glUniform1f(oesRoundLoc, if (rounded) 1f else 0f)
        GLES20.glUniform1f(oesRadiusLoc, radiusPx)
        GLES20.glUniform2f(
            oesInsetHalfLoc,
            (rectPx[2] - rectPx[0]) * 0.5f,
            (rectPx[3] - rectPx[1]) * 0.5f,
        )

        bindAttrib(oesPosLoc, fullQuad, 2)
        bindAttrib(oesTexLoc, texQuad, 2)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(oesPosLoc)
        GLES20.glDisableVertexAttribArray(oesTexLoc)
    }

    private fun bindAttrib(loc: Int, buf: FloatBuffer, size: Int) {
        buf.position(0)
        GLES20.glEnableVertexAttribArray(loc)
        GLES20.glVertexAttribPointer(loc, size, GLES20.GL_FLOAT, false, 0, buf)
    }

    private fun createFbo(w: Int, h: Int) {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        fboTex = ids[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTex)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )

        val fbo = IntArray(1)
        GLES20.glGenFramebuffers(1, fbo, 0)
        fboId = fbo[0]
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, fboTex, 0,
        )
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
    }

    private fun releaseFbo() {
        if (fboId != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(fboId), 0)
        if (fboTex != 0) GLES20.glDeleteTextures(1, intArrayOf(fboTex), 0)
        fboId = 0
        fboTex = 0
    }

    fun release() {
        releaseFbo()
        if (oesProgram != 0) GLES20.glDeleteProgram(oesProgram)
        if (blitProgram != 0) GLES20.glDeleteProgram(blitProgram)
        oesProgram = 0
        blitProgram = 0
    }

    /** Map a normalized surface rect (top-left origin) to a clip-space MVP. */
    private fun rectToMvp(l: Float, t: Float, r: Float, b: Float): FloatArray {
        // Convert [0,1] (y-down) to clip space [-1,1] (y-up).
        val sx = (r - l)
        val sy = (b - t)
        val cx = (l + r) - 1f // center x in clip space
        val cy = 1f - (t + b) // center y in clip space (flip)
        return floatArrayOf(
            sx, 0f, 0f, 0f,
            0f, sy, 0f, 0f,
            0f, 0f, 1f, 0f,
            cx, cy, 0f, 1f,
        )
    }

    private fun quad(l: Float, t: Float, r: Float, b: Float): FloatBuffer {
        // Full-surface quad in clip space; MVP scales it for insets.
        val verts = floatArrayOf(
            -1f, -1f,
            1f, -1f,
            -1f, 1f,
            1f, 1f,
        )
        return verts.toFloatBuffer()
    }

    private fun texCoords(): FloatBuffer {
        val tc = floatArrayOf(
            0f, 0f,
            1f, 0f,
            0f, 1f,
            1f, 1f,
        )
        return tc.toFloatBuffer()
    }

    private fun FloatArray.toFloatBuffer(): FloatBuffer {
        val bb = ByteBuffer.allocateDirect(size * 4).order(ByteOrder.nativeOrder())
        val fb = bb.asFloatBuffer()
        fb.put(this)
        fb.position(0)
        return fb
    }

    companion object {
        private val IDENTITY = floatArrayOf(
            1f, 0f, 0f, 0f,
            0f, 1f, 0f, 0f,
            0f, 0f, 1f, 0f,
            0f, 0f, 0f, 1f,
        )
        private val ZERO4 = floatArrayOf(0f, 0f, 0f, 0f)
        private val IDENTITY2 = floatArrayOf(1f, 0f, 0f, 1f)

        // Empirical rotation correction (see setSourceRotation). The front is
        // mirrored, so its upright correction is 180° off the back's.
        private const val BACK_ROTATION_OFFSET = -90
        private const val FRONT_ROTATION_OFFSET = 90

        private const val VERTEX = """
            uniform mat4 uMvp;
            uniform mat4 uTexMatrix;
            uniform float uMirror;
            uniform mat2 uTexXform;   // rotate-upright + aspect-cover
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            varying vec2 vTex;
            varying vec2 vScreen;
            void main() {
                gl_Position = uMvp * aPosition;
                vScreen = aPosition.xy;
                vec2 a = aTexCoord.xy - 0.5;
                if (uMirror > 0.5) { a.x = -a.x; }   // selfie mirror (displayed)
                vec2 b = uTexXform * a + 0.5;
                vTex = (uTexMatrix * vec4(b, 0.0, 1.0)).xy;
            }
        """

        // External-OES sampler with optional rounded-corner SDF alpha.
        private const val OES_FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uTexture;
            uniform float uRounded;
            uniform float uRadiusPx;
            uniform vec2 uInsetHalfPx;  // inset half-size in px (its OWN space)
            varying vec2 vTex;
            varying vec2 vScreen;       // local [-1,1] across the inset quad
            void main() {
                vec4 color = texture2D(uTexture, vTex);
                if (uRounded > 0.5) {
                    // Distance field in the inset's own pixel space, so the
                    // radius is isotropic (a circle is round, not an oval).
                    vec2 p = vScreen * uInsetHalfPx;
                    vec2 q = abs(p) - (uInsetHalfPx - vec2(uRadiusPx));
                    float dist = min(max(q.x, q.y), 0.0)
                        + length(max(q, 0.0)) - uRadiusPx;
                    float alpha = 1.0 - smoothstep(-1.0, 1.0, dist);
                    color.a *= alpha;
                    if (color.a < 0.01) discard;
                }
                gl_FragColor = color;
            }
        """

        // Pass-through vertex shader for the FBO->surface blit. Must NOT reuse
        // [VERTEX]: that one multiplies by uMvp/uTexMatrix, which blit() never
        // sets, so an unset (zero) mat4 collapses gl_Position to the origin and
        // the whole quad disappears (black output).
        private const val BLIT_VERTEX = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            varying vec2 vTex;
            void main() {
                gl_Position = aPosition;
                vTex = aTexCoord.xy;
            }
        """

        private const val BLIT_FRAGMENT = """
            precision mediump float;
            uniform sampler2D uTexture;
            varying vec2 vTex;
            void main() { gl_FragColor = texture2D(uTexture, vTex); }
        """

        private fun buildProgram(vsSrc: String, fsSrc: String): Int {
            val vs = compile(GLES20.GL_VERTEX_SHADER, vsSrc)
            val fs = compile(GLES20.GL_FRAGMENT_SHADER, fsSrc)
            val program = GLES20.glCreateProgram()
            GLES20.glAttachShader(program, vs)
            GLES20.glAttachShader(program, fs)
            GLES20.glLinkProgram(program)
            val status = IntArray(1)
            GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
            check(status[0] == GLES20.GL_TRUE) {
                "program link failed: ${GLES20.glGetProgramInfoLog(program)}"
            }
            GLES20.glDeleteShader(vs)
            GLES20.glDeleteShader(fs)
            return program
        }

        private fun compile(type: Int, src: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, src)
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            check(status[0] == GLES20.GL_TRUE) {
                "shader compile failed: ${GLES20.glGetShaderInfoLog(shader)}"
            }
            return shader
        }
    }
}
