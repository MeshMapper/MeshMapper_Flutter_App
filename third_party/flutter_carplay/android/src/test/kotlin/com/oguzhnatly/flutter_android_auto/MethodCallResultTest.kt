package com.oguzhnatly.flutter_android_auto

import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MethodCallResultTest {
    @Test
    fun `successful call completes the result exactly once`() = runBlocking {
        val result = RecordingResult()

        CoroutineScope(coroutineContext).launchMethodCall(result) { true }.join()

        assertEquals(listOf(true), result.successes)
        assertTrue(result.errors.isEmpty())
        assertEquals(1, result.completionCount)
    }

    @Test
    fun `failed call reports the exception exactly once`() = runBlocking {
        val result = RecordingResult()

        CoroutineScope(coroutineContext).launchMethodCall(result) {
            throw IllegalStateException("Template creation failed")
        }.join()

        assertTrue(result.successes.isEmpty())
        assertEquals(1, result.errors.size)
        assertEquals("android_auto_error", result.errors.single().code)
        assertEquals("Template creation failed", result.errors.single().message)
        assertEquals(1, result.completionCount)
    }

    @Test
    fun `cancelled call reports cancellation exactly once`() = runBlocking {
        val result = RecordingResult()

        CoroutineScope(coroutineContext).launchMethodCall(result) {
            throw CancellationException("Plugin detached")
        }.join()

        assertTrue(result.successes.isEmpty())
        assertEquals(1, result.errors.size)
        assertEquals("operation_cancelled", result.errors.single().code)
        assertEquals("Plugin detached", result.errors.single().message)
        assertEquals(1, result.completionCount)
    }
}

private class RecordingResult : MethodChannel.Result {
    data class Error(
        val code: String,
        val message: String?,
        val details: Any?,
    )

    val successes = mutableListOf<Any?>()
    val errors = mutableListOf<Error>()
    var notImplementedCount = 0

    val completionCount: Int
        get() = successes.size + errors.size + notImplementedCount

    override fun success(result: Any?) {
        successes.add(result)
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        errors.add(Error(errorCode, errorMessage, errorDetails))
    }

    override fun notImplemented() {
        notImplementedCount++
    }
}
