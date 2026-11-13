# ML Kit's Flutter plugin references the Chinese, Devanagari, Japanese and
# Korean text models. Only the Latin model is bundled (medicine packs in
# Bangladesh are printed in Latin script), so let R8 skip the others.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# R8 optimisation breaks ML Kit's internal classes in release builds: text
# recognition then fails with "NullPointerException ... getClass() on a null
# object reference" (in mlkit_vision_common while preparing the image). Keep
# ML Kit and its internal Play-services classes as they are.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.android.odml.** { *; }
