# youtubedl-android (embedded Python / FFmpeg / QuickJS) + its dependencies use
# reflection and resources by name - don't let R8 rename or strip them.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keep class org.apache.commons.** { *; }
-dontwarn com.fasterxml.jackson.**
-dontwarn org.apache.commons.**
-dontwarn java.beans.**

# Our JNI bridge: whisper_jni.cpp looks up WhisperLib natives and
# ProgressListener.onProgress by name.
-keep class com.mustafa.toolbox.** { *; }
-keepclasseswithmembernames class * { native <methods>; }

# ML Kit translation
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
