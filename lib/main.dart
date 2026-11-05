import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show DartPluginRegistrant;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'firebase_options.dart';

/// Sab family members ke liye fixed code (app me hi set hai).
const String kFamilyCode = 'bhagalpur2026xyz';

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

String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'abhi abhi';
  if (d.inMinutes < 60) return '${d.inMinutes} minute pehle';
  if (d.inHours < 24) return '${d.inHours} ghante pehle';
  return '${d.inDays} din pehle';
}

// ------------------------------------------------- BACKGROUND LOCATION SVC ----

/// Ye function app band hone (swipe) ke baad bhi alag background service me
/// chalta rehta hai. Notification hamesha dikhta hai (Notisave ki tarah).
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (FirebaseAuth.instance.currentUser == null) {
    try {
      await FirebaseAuth.instance.signInAnonymously();
    } catch (_) {}
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final phone = prefs.getString('my_phone');
  if (phone == null) {
    service.stopSelf();
    return;
  }

  StreamSubscription<Position>? posSub;
  StreamSubscription<ServiceStatus>? svcSub;

  void notify(String text) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
          title: 'Family Locator', content: text);
    }
  }

  Future<void> setStatus(String s) async {
    try {
      await memberDoc(phone).set(
          {'status': s, 'statusAt': FieldValue.serverTimestamp()},
          SetOptions(merge: true));
    } catch (_) {}
  }

  void listenPositions() {
    posSub?.cancel();
    posSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 60),
      ),
    ).listen(
      (pos) async {
        try {
          await memberDoc(phone).set({
            'lat': pos.latitude,
            'lng': pos.longitude,
            'accuracy': pos.accuracy,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          notify('Aapki location family ke saath share ho rahi hai');
        } catch (_) {}
      },
      onError: (_) {},
    );
  }

  Future<void> onLocationState(bool enabled) async {
    if (enabled) {
      notify('Aapki location family ke saath share ho rahi hai');
      listenPositions();
      await setStatus('ok');
    } else {
      notify('Location band hai. ON karte hi sharing chalu hogi.');
      await setStatus('location_off');
    }
  }

  svcSub = Geolocator.getServiceStatusStream()
      .listen((s) => onLocationState(s == ServiceStatus.enabled));
  await onLocationState(await Geolocator.isLocationServiceEnabled());

  service.on('stop').listen((_) async {
    await posSub?.cancel();
    await svcSub?.cancel();
    service.stopSelf();
  });
}

Future<void> configureService() async {
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      initialNotificationTitle: 'Family Locator',
      initialNotificationContent:
          'Aapki location family ke saath share ho rahi hai',
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

// ------------------------------------------------------------------- MAIN ----

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  try {
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  } catch (_) {}

  await configureService();

  final prefs = await SharedPreferences.getInstance();
  final phone = prefs.getString('my_phone');
  if (phone != null) {
    try {
      final svc = FlutterBackgroundService();
      if (!await svc.isRunning()) await svc.startService();
    } catch (_) {}
  }
  runApp(FamilyLocatorApp(setupDone: phone != null));
}

class FamilyLocatorApp extends StatelessWidget {
  final bool setupDone;
  const FamilyLocatorApp({super.key, required this.setupDone});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Family Locator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: setupDone ? const FindScreen() : const SetupScreen(),
    );
  }
}

// ----------------------------------------------------------- SETUP SCREEN ----

/// Sirf pehli baar: apna number daalo, permission do, sharing hamesha ke liye ON.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _phoneCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _askAlways() async {
    if (await Permission.locationAlways.isGranted) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Location: "Hamesha allow karo"'),
        content: const Text(
            'App band hone ke baad bhi location bhejne ke liye agli screen me '
            '"Allow all the time" (Hamesha allow karo) chuno.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Theek hai'))
        ],
      ),
    );
    await Permission.locationAlways.request();
  }

  Future<void> _start() async {
    final phone = normalizePhone(_phoneCtrl.text);
    if (phone.length != 10) {
      setState(() => _error = '10 digit ka apna mobile number daalo.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() => _error = 'Phone ka Location (GPS) ON karo, phir dobara dabao.');
        return;
      }
      final loc = await Permission.locationWhenInUse.request();
      if (!loc.isGranted) {
        setState(() => _error = 'Location permission zaroori hai.');
        if (loc.isPermanentlyDenied) await openAppSettings();
        return;
      }
      await Permission.notification.request();
      await _askAlways();
      await Permission.ignoreBatteryOptimizations.request();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('my_phone', phone);

      final svc = FlutterBackgroundService();
      if (await svc.isRunning()) {
        svc.invoke('stop');
        await Future.delayed(const Duration(seconds: 1));
      }
      await svc.startService();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const FindScreen()));
    } catch (e) {
      setState(() => _error = 'Kuch gadbad hui: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Family Locator')),
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
                labelText: 'Apna mobile number',
                prefixIcon: Icon(Icons.phone),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: _busy ? null : _start,
                icon: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.share_location),
                label: const Text('Location share shuru karo',
                    style: TextStyle(fontSize: 18)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            const Text(
              'Ek baar shuru karne ke baad aapki location family ke saath '
              'hamesha share hoti rahegi. Notification hamesha dikhega.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ FETCH SCREEN ----

class FindScreen extends StatefulWidget {
  const FindScreen({super.key});

  @override
  State<FindScreen> createState() => _FindScreenState();
}

class _FindScreenState extends State<FindScreen> {
  final _phoneCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _info;

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
      setState(() {
        _error = '10 digit ka mobile number daalo.';
        _info = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      final snap =
          await memberDoc(phone).get().timeout(const Duration(seconds: 15));
      if (!snap.exists || snap.data()?['lat'] == null) {
        setState(() => _error = 'Is number ki location abhi nahi mili.');
        return;
      }
      final d = snap.data()!;
      final lat = (d['lat'] as num).toDouble();
      final lng = (d['lng'] as num).toDouble();
      final updated = (d['updatedAt'] as Timestamp?)?.toDate();
      final locOff = d['status'] == 'location_off';

      final lines = <String>[];
      if (locOff) {
        final since = (d['statusAt'] as Timestamp?)?.toDate();
        lines.add('Unka Location band hai'
            '${since != null ? ' (${ago(since)} se)' : ''}.');
      }
      if (updated != null) {
        lines.add('Ye aakhri location hai: ${ago(updated)}.');
      }
      setState(() => _info = lines.isEmpty ? null : lines.join('\n'));

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

  Future<void> _stopSharing() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sharing band karein?'),
        content: const Text(
            'Aapki location family ko dikhna band ho jayegi.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Nahi')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Haan, band karo')),
        ],
      ),
    );
    if (ok != true) return;
    FlutterBackgroundService().invoke('stop');
    final p = await SharedPreferences.getInstance();
    await p.remove('my_phone');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SetupScreen()), (_) => false);
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
          PopupMenuButton<String>(
            onSelected: (_) => _stopSharing(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'stop', child: Text('Meri sharing band karo')),
            ],
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
                label: const Text('Location fetch karo',
                    style: TextStyle(fontSize: 18)),
              ),
            ),
            if (_info != null) ...[
              const SizedBox(height: 16),
              Text(_info!, textAlign: TextAlign.center),
            ],
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
