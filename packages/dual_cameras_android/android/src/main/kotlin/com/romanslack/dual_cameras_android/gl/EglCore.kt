package com.romanslack.dual_cameras_android.gl

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.view.Surface

/**
 * Core EGL state: one [EGLDisplay] + one [EGLContext] shared across every
 * consumer surface (encoder input + Flutter preview + the photo FBO target).
 *
 * Derived from Google's Grafika `EglCore`. A single instance is created on, and
 * only ever touched from, the GL render thread (see ARCHITECTURE.md §4, §12).
 */
class EglCore {
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null

    init {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "unable to get EGL14 display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            "unable to initialize EGL14"
        }

        // Request a GLES3 context, recordable so the encoder accepts it.
        val attribList = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        check(
            EGL14.eglChooseConfig(
                eglDisplay, attribList, 0, configs, 0, configs.size, numConfigs, 0,
            ),
        ) { "unable to find a suitable EGLConfig" }
        eglConfig = configs[0]

        val ctxAttribs = intArrayOf(
            EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL14.EGL_NONE,
        )
        eglContext = EGL14.eglCreateContext(
            eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0,
        )
        checkEglError("eglCreateContext")
        check(eglContext != EGL14.EGL_NO_CONTEXT) { "null EGL context" }
    }

    /** Create a window EGLSurface backed by [surface] (encoder input / preview). */
    fun createWindowSurface(surface: Surface): EGLSurface {
        val attribs = intArrayOf(EGL14.EGL_NONE)
        val eglSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, eglConfig, surface, attribs, 0,
        )
        checkEglError("eglCreateWindowSurface")
        check(eglSurface != null && eglSurface != EGL14.EGL_NO_SURFACE) {
            "surface was null"
        }
        return eglSurface
    }

    /** Create a window EGLSurface backed by a [SurfaceTexture]. */
    fun createWindowSurface(surfaceTexture: SurfaceTexture): EGLSurface {
        val attribs = intArrayOf(EGL14.EGL_NONE)
        val eglSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, eglConfig, surfaceTexture, attribs, 0,
        )
        checkEglError("eglCreateWindowSurface(st)")
        check(eglSurface != null && eglSurface != EGL14.EGL_NO_SURFACE) {
            "surface was null"
        }
        return eglSurface
    }

    /** A tiny pbuffer used to make the context current during bootstrap. */
    fun createOffscreenSurface(width: Int, height: Int): EGLSurface {
        val attribs = intArrayOf(
            EGL14.EGL_WIDTH, width,
            EGL14.EGL_HEIGHT, height,
            EGL14.EGL_NONE,
        )
        val eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig, attribs, 0)
        checkEglError("eglCreatePbufferSurface")
        check(eglSurface != null && eglSurface != EGL14.EGL_NO_SURFACE) {
            "pbuffer surface was null"
        }
        return eglSurface
    }

    fun makeCurrent(eglSurface: EGLSurface) {
        check(EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            "eglMakeCurrent failed"
        }
    }

    fun makeNothingCurrent() {
        EGL14.eglMakeCurrent(
            eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
        )
    }

    fun swapBuffers(eglSurface: EGLSurface): Boolean =
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)

    /** Stamp the next frame's presentation time, in nanoseconds (see §5). */
    fun setPresentationTime(eglSurface: EGLSurface, nsecs: Long) {
        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, nsecs)
    }

    fun releaseSurface(eglSurface: EGLSurface) {
        EGL14.eglDestroySurface(eglDisplay, eglSurface)
    }

    fun release() {
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(
                eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
            )
            EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglReleaseThread()
            EGL14.eglTerminate(eglDisplay)
        }
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglConfig = null
    }

    private fun checkEglError(msg: String) {
        val error = EGL14.eglGetError()
        check(error == EGL14.EGL_SUCCESS) {
            "$msg: EGL error 0x${Integer.toHexString(error)}"
        }
    }

    companion object {
        private const val EGL_RECORDABLE_ANDROID = 0x3142
    }
}
