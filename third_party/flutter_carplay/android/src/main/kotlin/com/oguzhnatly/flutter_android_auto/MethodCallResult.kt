package com.oguzhnatly.flutter_android_auto

import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

private const val METHOD_CALL_ERROR_CODE = "android_auto_error"
private const val METHOD_CALL_CANCELLED_CODE = "operation_cancelled"

internal fun <T> CoroutineScope.launchMethodCall(
    result: MethodChannel.Result,
    block: suspend () -> T,
): Job = launch {
    val value = try {
        block()
    } catch (exception: CancellationException) {
        result.error(METHOD_CALL_CANCELLED_CODE, exception.message, null)
        throw exception
    } catch (exception: Exception) {
        result.completeWithError(exception)
        return@launch
    }

    result.success(value)
}

internal fun MethodChannel.Result.completeWithError(exception: Exception) {
    error(
        METHOD_CALL_ERROR_CODE,
        exception.message ?: exception.javaClass.simpleName,
        exception.stackTraceToString(),
    )
}
