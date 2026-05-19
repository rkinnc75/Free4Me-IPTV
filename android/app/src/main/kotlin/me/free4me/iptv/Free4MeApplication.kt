package me.free4me.iptv

import android.app.Activity
import android.app.Application
import android.os.Bundle

/**
 * Custom Application subclass that tracks the currently active Activity.
 *
 * This reference is used by [CastPlugin] to show the MediaRoute device
 * picker dialog, which requires an Activity context. The app is referenced
 * in AndroidManifest.xml via android:name=".Free4MeApplication".
 */
class Free4MeApplication : Application() {

    /** The Activity currently in the foreground, or null if the app is in background. */
    @Volatile
    var currentActivity: Activity? = null
        private set

    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityCreated(a: Activity, b: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityResumed(a: Activity) { currentActivity = a }
            override fun onActivityPaused(a: Activity)  { if (currentActivity === a) currentActivity = null }
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
    }
}
