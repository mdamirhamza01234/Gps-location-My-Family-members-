// Values taken from the Firebase Android app config (google-services.json).
// Android only.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
            'Ye app abhi sirf Android ke liye configure hai.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCVAJe1LRAF77fWIxwYDZBNw-4H2fTMDA0',
    appId: '1:473060406584:android:431079d9e41c67075cbdcd',
    messagingSenderId: '473060406584',
    projectId: 'gps-location-my-family',
    storageBucket: 'gps-location-my-family.firebasestorage.app',
  );
}
