package app.alextran.immich.copyparty

import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import app.alextran.immich.core.ImmichPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * The city name for a position, from Android's built-in geocoder, for naming copyparty import folders.
 * The caller rounds the position (about 1 km) before calling.
 *
 * Channel: immich/place_name
 * Method:  cityAt({lat, lon}) -> {city: String?, area: String?, country: String?} or null when the phone
 *          has no geocoder or it gave no answer. city = Address.locality, else subAdminArea.
 */
class PlaceNamePlugin(private val appContext: Context) : ImmichPlugin() {
    companion object {
        const val CHANNEL = "immich/place_name"
    }

    private var methodChannel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

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
            "cityAt" -> {
                val lat = call.argument<Double>("lat")
                val lon = call.argument<Double>("lon")
                if (lat == null || lon == null || !Geocoder.isPresent()) {
                    result.success(null)
                    return
                }
                cityAt(lat, lon, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun reply(result: MethodChannel.Result, address: Address?) {
        val map = address?.let {
            mapOf(
                "city" to (it.locality ?: it.subAdminArea),
                "area" to it.adminArea,
                "country" to it.countryName,
            )
        }
        main.post { result.success(map) }
    }

    private fun cityAt(lat: Double, lon: Double, result: MethodChannel.Result) {
        // English names, as used in the folder names elsewhere (e.g. "Mexico City", not a local spelling).
        val geocoder = Geocoder(appContext, Locale.ENGLISH)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            geocoder.getFromLocation(lat, lon, 1, object : Geocoder.GeocodeListener {
                override fun onGeocode(addresses: MutableList<Address>) = reply(result, addresses.firstOrNull())
                override fun onError(errorMessage: String?) = reply(result, null)
            })
        } else {
            Thread {
                val address = try {
                    @Suppress("DEPRECATION")
                    geocoder.getFromLocation(lat, lon, 1)?.firstOrNull()
                } catch (_: Exception) {
                    null
                }
                reply(result, address)
            }.start()
        }
    }
}
