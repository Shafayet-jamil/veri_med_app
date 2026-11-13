# ML Kit's Flutter plugin references the Chinese, Devanagari, Japanese and
# Korean text models. Only the Latin model is bundled (medicine packs in
# Bangladesh are printed in Latin script), so let R8 skip the others.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
