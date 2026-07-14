package app.alextran.immich.copyparty

import android.content.Context
import app.alextran.immich.core.ImmichPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Exposes free disk space via java.io.File.getFreeSpace() — there is no
 * cross-platform Dart API for this, and the copyparty phone-cache slider
 * needs a real number to size its max against instead of a fixed guess.
 *
 * Always reports space for the app's internal data partition (filesDir),
 * which is where the copyparty staging cache lives (under
 * getApplicationDocumentsDirectory(), the same partition) — so a single,
 * always-existing anchor path is enough; no path needs to cross the bridge.
 *
 * Channel: immich/disk_space
 * Method:  freeSpaceBytes() -> Long
 */
class DiskSpacePlugin(private val appContext: Context) : ImmichPlugin() {
    companion object {
        const val CHANNEL = "immich/disk_space"
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
            "freeSpaceBytes" -> freeSpaceBytes(result)
            else -> result.notImplemented()
        }
    }

    private fun freeSpaceBytes(result: MethodChannel.Result) {
        try {
            result.success(appContext.filesDir.freeSpace)
        } catch (e: Exception) {
            result.error("FREE_SPACE_FAILED", e.message, null)
        }
    }
}
