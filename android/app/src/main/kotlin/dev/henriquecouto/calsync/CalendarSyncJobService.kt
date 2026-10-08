package dev.henriquecouto.calsync

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import androidx.core.app.NotificationCompat
import androidx.work.WorkInfo
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.WorkManagerWrapper
import dev.fluttercommunity.workmanager.pigeon.ExistingWorkPolicy
import dev.fluttercommunity.workmanager.pigeon.OneOffTaskRequest
import java.util.concurrent.TimeUnit

class CalendarSyncJobService : JobService() {
    override fun onStartJob(params: JobParameters?): Boolean {
        schedule(applicationContext)
        showProgressNotification()

        enqueueSync(applicationContext)

        Handler(Looper.getMainLooper()).postDelayed({
            checkAndDismiss()
        }, 5_000L)

        return false
    }

    // Every calendar change (including the sync's own writes) lands here.
    // A running sync must not be replaced (that kills it midway), and the
    // trigger must not be dropped either: the running sync may have read
    // the calendar before this change. So while the primary sync runs,
    // queue a single follow-up that starts after it and reads the calendar
    // afresh. KEEP only drops a trigger when an identical sync is still
    // waiting to start, which will see the change anyway.
    private fun enqueueSync(context: Context) {
        Thread {
            val primaryRunning = try {
                WorkManager.getInstance(context)
                    .getWorkInfosForUniqueWork(PRIMARY_WORK)
                    .get()
                    .any { it.state == WorkInfo.State.RUNNING }
            } catch (e: Exception) {
                false
            }
            val name = if (primaryRunning) FOLLOW_UP_WORK else PRIMARY_WORK
            val request = OneOffTaskRequest(
                uniqueName = name,
                taskName = name,
                tag = name,
                initialDelaySeconds = 5,
                existingWorkPolicy = ExistingWorkPolicy.KEEP,
            )
            WorkManagerWrapper(context).enqueueOneOffTask(request)
        }.start()
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        return false
    }

    private fun showProgressNotification() {
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            "calendar_sync",
            "Calendar Sync",
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)

        val notification = NotificationCompat.Builder(applicationContext, "calendar_sync")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Calendar Sync")
            .setContentText("Syncing calendars...")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        manager.notify(1, notification)
    }

    private fun checkAndDismiss() {
        val prefs = applicationContext.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE
        )
        val done = prefs.getString("flutter.pending_sync_notification", null)
        if (done != null) {
            val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(1)
            prefs.edit().remove("flutter.pending_sync_notification").apply()
        }
    }

    companion object {
        private const val PRIMARY_WORK = "calendar_sync_reactive"
        private const val FOLLOW_UP_WORK = "calendar_sync_reactive_followup"

        fun schedule(context: Context) {
            val component = ComponentName(
                context.packageName,
                CalendarSyncJobService::class.java.name
            )
            val jobInfo = JobInfo.Builder(1, component)
                .addTriggerContentUri(
                    JobInfo.TriggerContentUri(
                        CalendarContract.Events.CONTENT_URI,
                        JobInfo.TriggerContentUri.FLAG_NOTIFY_FOR_DESCENDANTS
                    )
                )
                .setTriggerContentUpdateDelay(TimeUnit.SECONDS.toMillis(5))
                .build()

            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            scheduler.schedule(jobInfo)
        }
    }
}
