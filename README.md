# Family GPS Tracker

Family members ke liye simple location-sharing app (Flutter + Firebase), sirf Android.

- Pehli baar app me 1-2 apna mobile number daalo aur sharing shuru karo. Uske baad
  app background me (app band hone ke baad bhi) raw GPS Firebase me bhejta rehta hai.
- Dekhne wala number daalta hai, **"Location fetch karo"** dabata hai, aur
  **official Google Maps app** khul jaata hai (Android `geo:` intent).
  **Google Maps SDK nahi, Maps API key nahi.**
- Hamburger menu se apna number kabhi bhi edit/add kar sakte ho. Number badalne
  ke baad bhi purana number fetch karne par kaam karta rahega.
- Internet band ho to SMS se turant aakhri location bhej di jaati hai, family
  ke baaki registered numbers par — kuch manually dalna nahi padta, app
  khud apne family ke numbers jaan jaata hai.
- Notification hamesha dikhta hai jab tak sharing ON hai (Android ka rule hai,
  taaki jis insaan ki location ja rahi hai use hamesha pata rahe).

## APK kaise milega

GitHub Actions har push par APK banata hai aur **Releases** me daal deta hai:
Repo page > **Releases** > latest version > `app-release.apk` download karke install karo.
(Pehli baar "Install unknown apps" allow karna padega.)

## Firebase me ek baar ye karna zaroori hai

1. **Authentication > Sign-in method > Anonymous** ko Enable karo.
2. **Firestore Database** banao (location `asia-south1`).
3. Firestore **Rules** me `firestore.rules` ka content paste karke Publish karo
   (isme `members` aur `numbers`, dono collections ke rules hain).

## Use kaise kare

1. App kholo, apna number (ya do number) daalo, "Location share shuru karo" dabao.
   Permission maange to sab Allow karo ("Allow all the time" bhi).
2. Dusre ki location dekhni ho: naam (optional) aur unka number daalo, "Location
   fetch karo" dabao.
3. Apna number badalna ho: hamburger menu (top-left) > "Mera number edit karo".
4. App bar ke SMS icon se dekh sakte ho ki abhi SMS fallback me kaunse
   numbers hain (apne aap aate hain) — "Refresh" se turant update bhi kar
   sakte ho.

## Data model (Firestore)

- `families/{code}/members/{memberId}` — ek member ki taaza location.
  `memberId` phone se alag, sthayi hota hai (phone me hi save).
- `families/{code}/numbers/{phone}` — ek chhota pointer jo phone number ko
  uske `memberId` se jodta hai. Number edit karne par purana pointer kabhi
  mitaya nahi jaata, isliye purana number bhi hamesha fetch ho sakta hai.

## Note

- Family code ek tarah ka password hai, isliye lamba aur secret rakho.
- `config/google-services.json` Firebase ki public client config hai. Asli security `firestore.rules` se aati hai.
- `android/` folder build ke waqt apne aap banta hai (`scripts/patch_android.py` permissions, app label aur Firebase plugin jodta hai).
