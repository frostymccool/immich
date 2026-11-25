package app.alextran.immich.copyparty

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import app.alextran.immich.core.ImmichPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Exposes a SAF directory picker that correctly resolves the selected tree URI
 * to a real filesystem path via the public StorageVolume.getDirectory() API
 * (available since API 30).
 *
 * file_picker's getDirectoryPath() uses reflection to call the private
 * StorageVolume.getPath() method, which Android has blocked since API 30,
 * causing it to return "/" for non-primary volumes (USB drives, SD cards).
 * This plugin avoids that entirely.
 *
 * Channel: immich/saf_picker
 * Method:  pickDirectory() → String? (filesystem path, or null if cancelled)
 * Method:  deleteFile({path}) → {ok: Boolean, error: String?}
 *          Deletes a file through the folder grant the picker took (persisted tree URI with write
 *          access). On Android 11+ a plain File.delete() on a removable SD card or USB drive is
 *          often refused even with "All files access", while the tree grant allows it.
 * Method:  canDelete({path}) → Boolean (a persisted writable folder grant covers this path)
 */
class SafPickerPlugin(private val appContext: Context)
    : ImmichPlugin(), ActivityAware, PluginRegistry.ActivityResultListener {

    companion object {
        const val CHANNEL = "immich/saf_picker"
        private const val REQUEST_CODE = 9201
    }

    private var methodChannel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingResult: MethodChannel.Result? = null

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
            "pickDirectory" -> pickDirectory(result)
            "deleteFile" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("ARG", "path is required", null)
                } else {
                    // Off the main thread: a delete on a slow card must not block the UI.
                    Thread {
                        val outcome = deleteViaTree(path)
                        // Flutter results must be delivered on the main thread.
                        Handler(Looper.getMainLooper()).post { completeWhenActive(result::success, outcome) }
                    }.start()
                }
            }
            "canDelete" -> {
                val path = call.argument<String>("path")
                result.success(path != null && writableTreeFor(path) != null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }
        if (pendingResult != null) {
            result.error("PENDING", "A directory pick is already in progress", null)
            return
        }
        pendingResult = result
        activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val pending = pendingResult ?: return true
        pendingResult = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            completeWhenActive(pending::success, null)
            return true
        }

        val treeUri = data.data!!

        // Take persistent permission so the grant survives app restarts.
        try {
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            appContext.contentResolver.takePersistableUriPermission(treeUri, flags)
        } catch (_: Exception) {}

        completeWhenActive(pending::success, resolveToFilesystemPath(treeUri))
        return true
    }

    /**
     * Converts a SAF tree URI to a real filesystem path.
     *
     * The tree document ID has the form "<volumeId>:<relativePath>" where
     * volumeId is "primary" for internal storage or the volume UUID for
     * removable storage.  We map the volume ID to a mount point using
     * StorageVolume.getDirectory() — the public API that file_picker does NOT
     * use (it uses a private API via reflection that was restricted in API 30).
     */
    private fun resolveToFilesystemPath(treeUri: Uri): String? {
        return try {
            val docId = DocumentsContract.getTreeDocumentId(treeUri) ?: return null
            val sep = docId.indexOf(':')
            if (sep < 0) return null

            val volumeId = docId.substring(0, sep)
            val relPath  = docId.substring(sep + 1)

            val volumeRoot = if (volumeId.equals("primary", ignoreCase = true)) {
                "/storage/emulated/0"
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val sm = appContext.getSystemService(Context.STORAGE_SERVICE) as StorageManager
                val vol = sm.storageVolumes.firstOrNull {
                    it.uuid?.equals(volumeId, ignoreCase = true) == true
                }
                // getDirectory() is the public API; never null for a mounted volume.
                vol?.directory?.absolutePath ?: "/storage/$volumeId"
            } else {
                "/storage/$volumeId"
            }

            if (relPath.isEmpty()) volumeRoot else "$volumeRoot/$relPath"
        } catch (_: Exception) {
            null
        }
    }

    /** The persisted writable folder grant whose folder contains [path], with that folder's path. */
    private fun writableTreeFor(path: String): Pair<Uri, String>? {
        val grants = appContext.contentResolver.persistedUriPermissions.filter { it.isWritePermission }
        var best: Pair<Uri, String>? = null
        for (grant in grants) {
            val root = resolveToFilesystemPath(grant.uri) ?: continue
            val inside = path == root || path.startsWith(root.trimEnd('/') + "/")
            if (inside && (best == null || root.length > best.second.length)) {
                best = grant.uri to root
            }
        }
        return best
    }

    private fun deleteViaTree(path: String): Map<String, Any?> {
        return try {
            val (treeUri, root) = writableTreeFor(path)
                ?: return mapOf(
                    "ok" to false,
                    "error" to "no folder permission covers this file (pick the folder again in Import)",
                )
            val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
            val rel = path.removePrefix(root.trimEnd('/')).trimStart('/')
            val docId = if (treeDocId.endsWith(":")) "$treeDocId$rel" else "$treeDocId/$rel"
            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
            val ok = DocumentsContract.deleteDocument(appContext.contentResolver, docUri)
            mapOf("ok" to ok, "error" to if (ok) null else "the storage provider refused the delete")
        } catch (e: Exception) {
            mapOf("ok" to false, "error" to (e.message ?: e.javaClass.simpleName))
        }
    }

    // ---- ActivityAware ----

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        // Fail any in-flight pick so the Dart future resolves cleanly.
        pendingResult?.let {
            pendingResult = null
            completeWhenActive(it::success, null)
        }
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
}
