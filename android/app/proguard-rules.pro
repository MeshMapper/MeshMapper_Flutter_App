# flutter_local_notifications uses Gson to serialize/deserialize scheduled
# notification data.  R8 strips the generic signature from TypeToken
# subclasses, causing "TypeToken must be created with a type argument" at
# runtime when cancel() tries to load the notification cache.
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keepattributes Signature
