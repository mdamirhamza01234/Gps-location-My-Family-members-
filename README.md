# Family Locator

Family members ke liye simple location-sharing app (Flutter + Firebase).

- Sharing wala phone: raw GPS (lat/lng) Firestore me apne phone number ke naam se save karta hai.
- Dekhne wala phone: phone number daalo, latest coordinates fetch karo, aur **official Google Maps app** khul jata hai.
- **Google Maps SDK nahi, koi API key nahi.** Android par `geo:` intent, iOS par `comgooglemaps://` URL scheme.
- Privacy: sharing sirf "Start sharing" dabane par shuru hoti hai, Android par hamesha notification dikhta hai, aur "Stop sharing" se band.

## Setup (ek baar)

1. Flutter project ka platform folder banao (is repo ke andar):
   ```
   flutter create . --org com.family --project-name family_locator
   ```
   (existing `lib/main.dart` aur `pubspec.yaml` ko overwrite nahi karega; agar kare to GitHub se wapas le lo.)

2. Firebase console me project banao, phir:
   ```
   dart pub global activate flutterfire_cli
   flutterfire configure
   ```
   Ye `lib/firebase_options.dart` bana dega.

3. Firebase console me:
   - **Authentication > Sign-in method > Anonymous** ko Enable karo.
   - **Firestore Database** banao, aur `firestore.rules` ki rules paste karke Publish karo.

4. Android permissions: `android/app/src/main/AndroidManifest.xml` me `<manifest>` ke andar (application se pehle) ye daalo:
   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
   <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>

   <queries>
     <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="geo"/></intent>
     <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
   </queries>
   ```
   Aur `android/app/build.gradle` me `minSdkVersion 23` (ya `flutter.minSdkVersion` agar 23+ ho) rakho.

5. iOS (agar chahiye): `ios/Runner/Info.plist` me:
   ```xml
   <key>NSLocationWhenInUseUsageDescription</key>
   <string>Family ke saath apni location share karne ke liye.</string>
   <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
   <string>Background me bhi location share karne ke liye.</string>
   <key>UIBackgroundModes</key>
   <array><string>location</string></array>
   <key>LSApplicationQueriesSchemes</key>
   <array><string>comgooglemaps</string></array>
   ```

6. Run:
   ```
   flutter pub get
   flutter run
   ```

## Use kaise kare

1. Sab family members me **same Family code** rakho (koi bhi secret word, jaise `sharma2026`).
2. Jis ki location dikhani ho: **Share mine** tab > apna number > **Start sharing**.
3. Dekhne wala: **Find member** tab > unka number > **Fetch latest location** > **Open in Google Maps**.

## Note

Family code hi ek tarah ka password hai, isliye lamba aur secret rakho. Zyada security chahiye ho to baad me Firebase Phone Auth add kar sakte hain.
