# Family Locator

Family members ke liye simple location-sharing app (Flutter + Firebase), sirf Android.

- Sharing wala phone raw GPS (lat/lng) Firestore me apne phone number ke naam se save karta hai.
- Dekhne wala phone number daalta hai, latest coordinates aate hain, aur **official Google Maps app** khulta hai (Android `geo:` intent).
- **Google Maps SDK nahi, Maps API key nahi.**
- Sharing sirf "Start sharing" dabane par shuru hoti hai, notification hamesha dikhta hai, "Stop sharing" se band.

## APK kaise milega

GitHub Actions har push par APK banata hai aur **Releases** me daal deta hai:
Repo page > **Releases** > latest version > `app-release.apk` download karke install karo.
(Pehli baar "Install unknown apps" allow karna padega.)

## Firebase me ek baar ye karna zaroori hai

1. **Authentication > Sign-in method > Anonymous** ko Enable karo.
2. **Firestore Database** banao (location `asia-south1`).
3. Firestore **Rules** me `firestore.rules` ka content paste karke Publish karo.

## Use kaise kare

1. Sab members me **same Family code** rakho (koi bhi lamba secret word).
2. Jis ki location dikhani ho: **Share mine** > apna number > **Start sharing**.
3. Dekhne wala: **Find member** > unka number > **Fetch latest location** > **Open in Google Maps**.

## Note

- Family code ek tarah ka password hai, isliye lamba aur secret rakho.
- `config/google-services.json` Firebase ki public client config hai. Asli security `firestore.rules` se aati hai.
- `android/` folder build ke waqt apne aap banta hai (`scripts/patch_android.py` permissions aur Firebase plugin jodta hai).
