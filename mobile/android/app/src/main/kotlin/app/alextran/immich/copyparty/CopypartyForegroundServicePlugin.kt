package app.alextran.immich.copyparty

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import app.alextran.immich.core.ImmichPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Starts/stops CopypartyForegroundService from Dart, kept in sync with the
 * copyparty import session lifecycle (see copyparty.provider.dart's
 * startUpload/teardown, alongside the WakelockPlus calls).
 *
 * Channel: immich/copyparty_foreground
 * Methods: start() -> null, stop() -> null
 */
class CopypartyForegroundServicePlugin(private val appContext: Context) : ImmichPlugin() {
    companion object {
        const val CHANNEL = "immich/copyparty_foreground"
    }

    private var methodChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        super.onAttachedToEngine(binding)
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler(::handleCall)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        super.onDetachedFromEngine(binding)
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                startService()
                result.success(null)
            }
            "stop" -> {
                stopService()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startService() {
        try {
            ContextCompat.startForegroundService(
                appContext,
                Intent(appContext, CopypartyForegroundService::class.java)
            )
        } catch (_: Exception) {
            // Never let a failure here break the import — the wakelock and
            // normal upload logic still function without the FG promotion.
        }
    }

    private fun stopService() {
        try {
            appContext.stopService(Intent(appContext, CopypartyForegroundService::class.java))
        } catch (_: Exception) {}
    }
}
