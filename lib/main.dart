import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'firebase_options.dart';

/// Sab family members ke liye fixed code (app me hi set hai).
const String kFamilyCode = 'bhagalpur2026xyz';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }
  runApp(const FamilyLocatorApp());
}

class FamilyLocatorApp extends StatelessWidget {
  const FamilyLocatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Family Locator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const FindScreen(),
    );
  }
}

/// Last 10 digits only, so "+91 98765-43210" and "9876543210" match.
String normalizePhone(String input) {
  final digits = input.replaceAll(RegExp(r'\D'), '');
  return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
}

DocumentReference<Map<String, dynamic>> memberDoc(String phone) =>
    FirebaseFirestore.instance
        .collection('families')
        .doc(kFamilyCode)
        .collection('members')
        .doc(phone);

// ------------------------------------------------------------ MAIN SCREEN ----

class FindScreen extends StatefulWidget {
  const FindScreen({super.key});

  @override
  State<FindScreen> createState() => _FindScreenState();
}

class _FindScreenState extends State<FindScreen> {
  final _phoneCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _phoneCtrl.text = p.getString('last_search') ?? '';
    });
  }

  Future<void> _open() async {
    final phone = normalizePhone(_phoneCtrl.text);
    if (phone.length != 10) {
      setState(() => _error = '10 digit ka mobile number daalo.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await memberDoc(phone)
          .get()
          .timeout(const Duration(seconds: 15));
      if (!snap.exists) {
        setState(() => _error = 'Is number ki location abhi nahi mili.');
        return;
      }
      final d = snap.data()!;
      final lat = (d['lat'] as num).toDouble();
      final lng = (d['lng'] as num).toDouble();
      final p = await SharedPreferences.getInstance();
      await p.setString('last_search', phone);
      final opened = await _openGoogleMaps(lat, lng);
      if (!opened) setState(() => _error = 'Google Maps nahi khul paya.');
    } catch (e) {
      setState(() => _error = 'Internet check karo aur dobara try karo.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Official Google Maps app. No SDK / API key.
  Future<bool> _openGoogleMaps(double lat, double lng) async {
    final candidates = <Uri>[
      if (Platform.isAndroid) Uri.parse('geo:$lat,$lng?q=$lat,$lng'),
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
    ];
    for (final uri in candidates) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family Locator'),
        actions: [
          IconButton(
            tooltip: 'Meri location share karo',
            icon: const Icon(Icons.share_location),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ShareScreen())),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              style: const TextStyle(fontSize: 20),
              decoration: const InputDecoration(
                labelText: 'Mobile number',
                prefixIcon: Icon(Icons.phone),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _open(),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: _loading ? null : _open,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.map),
                label: const Text('Google Maps me dekho',
                    style: TextStyle(fontSize: 18)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- SHARE SCREEN ----

class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key});

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  final _phoneCtrl = TextEditingController();
  StreamSubscription<Position>? _sub;
  bool _sharing = false;
  String _status = 'Sharing band hai.';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _phoneCtrl.text = p.getString('my_phone') ?? '';
    });
  }

  Future<bool> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _status = 'Phone ka Location (GPS) ON karo.');
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permission nahi mili.');
      return false;
    }
    return true;
  }

  Future<void> _start() async {
    final phone = normalizePhone(_phoneCtrl.text);
    if (phone.length != 10) {
      setState(() => _status = '10 digit ka apna mobile number daalo.');
      return;
    }
    if (!await _ensurePermission()) return;

    final p = await SharedPreferences.getInstance();
    await p.setString('my_phone', phone);

    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 20,
      intervalDuration: const Duration(seconds: 30),
      // Notification hamesha dikhta hai, taaki pata rahe sharing ON hai.
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Family Locator',
        notificationText: 'Aapki location family ke saath share ho rahi hai',
        enableWakeLock: true,
      ),
    );

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) async {
        try {
          await memberDoc(phone).set({
            'lat': pos.latitude,
            'lng': pos.longitude,
            'accuracy': pos.accuracy,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          if (mounted) setState(() => _status = 'Sharing ON hai.');
        } catch (e) {
          if (mounted) setState(() => _status = 'Upload nahi ho paya: $e');
        }
      },
      onError: (e) {
        if (mounted) setState(() => _status = 'GPS error: $e');
      },
    );
    setState(() {
      _sharing = true;
      _status = 'Sharing shuru ho raha hai...';
    });
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    setState(() {
      _sharing = false;
      _status = 'Sharing band hai.';
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Meri location share karo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _phoneCtrl,
              enabled: !_sharing,
              keyboardType: TextInputType.phone,
              style: const TextStyle(fontSize: 20),
              decoration: const InputDecoration(
                labelText: 'Mera mobile number',
                prefixIcon: Icon(Icons.phone),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: _sharing ? _stop : _start,
                icon: Icon(_sharing ? Icons.stop : Icons.play_arrow),
                label: Text(_sharing ? 'Sharing band karo' : 'Sharing shuru karo',
                    style: const TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 16),
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              'Sharing tabhi hoti hai jab aap shuru dabate ho. '
              'Kabhi bhi band kar sakte ho.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
