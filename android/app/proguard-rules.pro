# fix590 (#16) — R8 keep rules for Free4Me-IPTV release builds.
#
# FIRST PASS POLICY: shrink (remove unused) but DO NOT obfuscate (rename). With
# -dontobfuscate a runtime crash can never be a renamed-symbol / reflection /
# manifest mismatch, so this isolates pure shrinking. Revisit renaming only
# after the build has soaked on-device. The keeps below protect every class
# reached by JNI, reflection, a platform channel, or the AndroidManifest — i.e.
# everything R8 cannot see a static reference to and would otherwise strip.

-dontobfuscate

# ---- App entry points referenced from AndroidManifest.xml / reflection -------
# Application + Activity are instantiated by name; CastPlugin reads
# (applicationContext as Free4MeApplication).currentActivity reflectively.
-keep class me.free4me.iptv.Free4MeApplication { *; }
-keep class me.free4me.iptv.MainActivity { *; }
-keep class me.free4me.iptv.CastPlugin { *; }
-keep class me.free4me.iptv.CastOptionsProvider { *; }

# ---- JNI: never strip classes that declare native methods -------------------
-keepclasseswithmembernames class * { native <methods>; }

# ---- Flutter embedding + generated registrant -------------------------------
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# ---- Plugins reached via reflection / platform channels / manifest ----------
# workmanager: the Dart callbackDispatcher is invoked through the plugin.
-keep class dev.fluttercommunity.workmanager.** { *; }
# flutter_foreground_task: ForegroundService/Receivers declared in the manifest.
-keep class com.pravera.flutter_foreground_task.** { *; }
# plus plugins initialised at cold start / used in background refresh.
-keep class dev.fluttercommunity.plus.packageinfo.** { *; }
-keep class dev.fluttercommunity.plus.device_info.** { *; }
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# ---- Google Cast SDK (reflection via OptionsProvider) -----------------------
-keep class com.google.android.gms.cast.framework.** { *; }
-keep class * implements com.google.android.gms.cast.framework.OptionsProvider { *; }
-keepclassmembers class * implements com.google.android.gms.cast.framework.OptionsProvider { *; }

# ---- media_kit / libmpv native bridge ---------------------------------------
-keep class com.alexmercerind.** { *; }
-keep class com.github.libmpv.** { *; }

# ---- sqlite3 native bindings -------------------------------------------------
-keep class com.example.sqlite3_flutter_libs.** { *; }
-keep class org.sqlite.** { *; }

# ---- enums reached via valueOf()/values() (settings persistence) ------------
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# ---- Parcelable CREATOR ------------------------------------------------------
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}

# Quieten notes for missing optional classes pulled in transitively.
-dontwarn io.flutter.**
-dontwarn com.google.android.gms.**
