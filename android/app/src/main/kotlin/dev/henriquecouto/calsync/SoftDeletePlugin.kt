package dev.henriquecouto.calsync

import android.content.ContentResolver
import android.content.ContentValues
import android.provider.CalendarContract
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class SoftDeletePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var appContext: android.content.Context? = null

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "calsync/calendar")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        appContext = null
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        when (call.method) {
            "deleteEvent" -> {
                val eventId = call.argument<String>("eventId")
                if (eventId == null) {
                    result.error("INVALID_ARG", "eventId is required", null)
                    return
                }
                val ctx = appContext ?: run {
                    result.error("NO_CONTEXT", "Plugin not attached", null)
                    return
                }
                try {
                    val deletedRows = ctx.contentResolver.delete(
                        CalendarContract.Events.CONTENT_URI,
                        "${CalendarContract.Events._ID} = ?",
                        arrayOf(eventId)
                    )
                    result.success(deletedRows > 0)
                } catch (e: Exception) {
                    result.error("DELETE_ERROR", e.message, null)
                }
            }
            "excludeOccurrence" -> {
                val eventId = call.argument<String>("eventId")
                val start = call.argument<Number>("start")?.toLong()
                if (eventId == null || start == null) {
                    result.error("INVALID_ARG", "eventId and start are required", null)
                    return
                }
                val ctx = appContext ?: run {
                    result.error("NO_CONTEXT", "Plugin not attached", null)
                    return
                }
                try {
                    val format = java.text.SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", java.util.Locale.US)
                    format.timeZone = java.util.TimeZone.getTimeZone("UTC")
                    val exdate = format.format(java.util.Date(start))
                    var existing: String? = null
                    var found = false
                    ctx.contentResolver.query(
                        CalendarContract.Events.CONTENT_URI,
                        arrayOf(CalendarContract.Events.EXDATE),
                        "${CalendarContract.Events._ID} = ? AND ${CalendarContract.Events.DELETED} = 0",
                        arrayOf(eventId),
                        null
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            found = true
                            existing = cursor.getString(0)
                        }
                    }
                    if (!found) {
                        result.success(false)
                        return
                    }
                    val current = existing
                    if (current != null && current.split(",").contains(exdate)) {
                        result.success(true)
                        return
                    }
                    val values = ContentValues().apply {
                        put(
                            CalendarContract.Events.EXDATE,
                            if (current.isNullOrEmpty()) exdate else "$current,$exdate"
                        )
                    }
                    val rows = ctx.contentResolver.update(
                        CalendarContract.Events.CONTENT_URI,
                        values,
                        "${CalendarContract.Events._ID} = ?",
                        arrayOf(eventId)
                    )
                    result.success(rows > 0)
                } catch (e: Exception) {
                    result.error("EXDATE_ERROR", e.message, null)
                }
            }
            "getEventIdentities" -> {
                val ids = call.argument<List<String>>("eventIds")
                if (ids == null) {
                    result.error("INVALID_ARG", "eventIds is required", null)
                    return
                }
                val ctx = appContext ?: run {
                    result.error("NO_CONTEXT", "Plugin not attached", null)
                    return
                }
                try {
                    // UID_2445 is the iCalendar UID the server assigns to the
                    // meeting; _SYNC_ID is the sync adapter's server-side ID.
                    // Both may survive when the adapter re-creates the local
                    // row under a new _ID.
                    val identities = HashMap<String, Map<String, String?>>()
                    for (chunk in ids.chunked(200)) {
                        ctx.contentResolver.query(
                            CalendarContract.Events.CONTENT_URI,
                            arrayOf(
                                CalendarContract.Events._ID,
                                CalendarContract.Events.UID_2445,
                                CalendarContract.Events._SYNC_ID,
                            ),
                            "${CalendarContract.Events._ID} IN (${chunk.joinToString(",") { "?" }})",
                            chunk.toTypedArray(),
                            null
                        )?.use { cursor ->
                            while (cursor.moveToNext()) {
                                identities[cursor.getLong(0).toString()] = mapOf(
                                    "uid" to cursor.getString(1),
                                    "syncId" to cursor.getString(2),
                                )
                            }
                        }
                    }
                    result.success(identities)
                } catch (e: Exception) {
                    result.error("QUERY_ERROR", e.message, null)
                }
            }
            "updateEvent" -> {
                val eventId = call.argument<String>("eventId")?.toLongOrNull()
                val title = call.argument<String>("title")
                val start = call.argument<Number>("start")?.toLong()
                val end = call.argument<Number>("end")?.toLong()
                if (eventId == null || title == null || start == null || end == null) {
                    result.error("INVALID_ARG", "eventId, title, start and end are required", null)
                    return
                }
                val ctx = appContext ?: run {
                    result.error("NO_CONTEXT", "Plugin not attached", null)
                    return
                }
                try {
                    // Only for one-off timed events; all-day and recurring
                    // events are replaced from Dart instead.
                    val values = ContentValues().apply {
                        put(CalendarContract.Events.TITLE, title)
                        put(CalendarContract.Events.DTSTART, start)
                        put(CalendarContract.Events.DTEND, end)
                        put(CalendarContract.Events.DESCRIPTION, call.argument<String>("description"))
                        if (call.argument<Boolean>("setLocation") == true) {
                            put(CalendarContract.Events.EVENT_LOCATION, call.argument<String>("location"))
                        }
                    }
                    val rows = ctx.contentResolver.update(
                        CalendarContract.Events.CONTENT_URI,
                        values,
                        "${CalendarContract.Events._ID} = ? AND ${CalendarContract.Events.DELETED} = 0",
                        arrayOf(eventId.toString())
                    )
                    result.success(rows > 0)
                } catch (e: Exception) {
                    result.error("UPDATE_ERROR", e.message, null)
                }
            }
            "isEventDeleted" -> {
                val eventId = call.argument<String>("eventId")
                if (eventId == null) {
                    result.error("INVALID_ARG", "eventId is required", null)
                    return
                }
                val ctx = appContext ?: run {
                    result.error("NO_CONTEXT", "Plugin not attached", null)
                    return
                }
                try {
                    // Some sync adapters (e.g. Outlook/Exchange) replace an
                    // event by flagging the old row DELETED=1 and inserting a
                    // new row. The flagged row stays readable until the
                    // adapter purges it, so check the flag explicitly.
                    ctx.contentResolver.query(
                        CalendarContract.Events.CONTENT_URI,
                        arrayOf(CalendarContract.Events.DELETED),
                        "${CalendarContract.Events._ID} = ?",
                        arrayOf(eventId),
                        null
                    ).use { cursor ->
                        if (cursor == null || !cursor.moveToFirst()) {
                            result.success(true)
                        } else {
                            result.success(cursor.getInt(0) != 0)
                        }
                    }
                } catch (e: Exception) {
                    result.error("QUERY_ERROR", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
