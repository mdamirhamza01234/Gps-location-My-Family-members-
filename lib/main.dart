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
  // Agar family member ne pehle sharing ON ki thi, to app khulte hi resume.
  Sharer.I.resumeIfEnabled();
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

String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'abhi abhi';
  if (d.inMinutes < 60) return '${d.inMinutes} minute pehle';
  if (d.inHours < 24) return '${d.inHours} ghante pehle';
  return '${d.inDays} din pehle';
}

// ---------------------------------------------------------------- SHARER ----

/// Is phone ki location Firebase tak bhejta hai (sirf tab, jab user ne ON kiya).
class Sharer {
  Sharer._();
  static final Sharer I = Sharer._();

  final ValueNotifier<bool> sharing = ValueNotifier(false);
  final ValueNotifier<String> status = ValueNotifier('Sharing band hai.');

  StreamSubscription<Position>? _pos;
  StreamSubscription<ServiceStatus>? _svc;
  String? _phone;

  Future<void> resumeIfEnabled() async {
    final p = await SharedPreferences.getInstance();
    final phone = p.getString('my_phone');
    if ((p.getBool('sharing_on') ?? false) && phone != null) {
      await start(phone);
    }
  }

  Future<bool> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      status.value = 'Phone ka Location (GPS) ON karo.';
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      status.value = 'Location permission nahi mili.';
      return false;
    }
    return true;
  }

  Future<void> _setStatus(String s) async {
    try {
      await memberDoc(_phone!).set(
          {'status': s, 'statusAt': FieldValue.serverTimestamp()},
          SetOptions(merge: true));
    } catch (_) {}
  }

  void _listenPositions() {
    _pos?.cancel();
    final phone = _phone!;
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
    _pos = Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) async {
        try {
          await memberDoc(phone).set({
            'lat': pos.latitude,
            'lng': pos.longitude,
            'accuracy': pos.accuracy,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          status.value = 'Sharing ON hai.';
        } catch (e) {
          status.value = 'Upload nahi ho paya: $e';
        }
      },
      onError: (_) {},
    );
  }

  Future<bool> start(String phone) async {
    if (sharing.value) return true;
    _phone = phone;
    if (!await _ensurePermission()) {
      // Location OFF hai: family ko batao aur ON hone ka intezaar karo.
      if (!await Geolocator.isLocationServiceEnabled()) {
        _watchService();
        sharing.value = true;
        status.value = 'Location band hai. ON karte hi sharing chalu hogi.';
        await _setStatus('location_off');
        return true;
      }
      return false;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('my_phone', phone);
    await p.setBool('sharing_on', true);
    sharing.value = true;
    status.value = 'Sharing shuru ho raha hai...';
    _listenPositions();
    _watchService();
    await _setStatus('ok');
    return true;
  }

  void _watchService() {
    _svc?.cancel();
    _svc = Geolocator.getServiceStatusStream().listen((s) async {
      if (s == ServiceStatus.disabled) {
        status.value = 'Location band hai. ON karte hi sharing chalu hogi.';
        await _setStatus('location_off');
      } else {
        status.value = 'Sharing ON hai.';
        _listenPositions();
        await _setStatus('ok');
      }
    });
  }

  Future<void> stop() async {
    await _pos?.cancel();
    await _svc?.cancel();
    _pos = null;
    _svc = null;
    final p = await SharedPreferences.getInstance();
    await p.setBool('sharing_on', false);
    sharing.value = false;
    status.value = 'Sharing band hai.';
  }
}

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

// ----------------------------------------------------------- SHARE SCREEN ----

class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key});

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  final _phoneCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _phoneCtrl.text = p.getString('my_phone') ?? '';
    });
  }

  Future<void> _toggle() async {
    if (Sharer.I.sharing.value) {
      await Sharer.I.stop();
      return;
    }
    final phone = normalizePhone(_phoneCtrl.text);
    if (phone.length != 10) {
      Sharer.I.status.value = '10 digit ka apna mobile number daalo.';
      return;
    }
    await Sharer.I.start(phone);
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Meri location share karo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: ValueListenableBuilder<bool>(
          valueListenable: Sharer.I.sharing,
          builder: (context, sharing, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _phoneCtrl,
                enabled: !sharing,
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
                  onPressed: _toggle,
                  icon: Icon(sharing ? Icons.stop : Icons.play_arrow),
                  label: Text(
                      sharing ? 'Sharing band karo' : 'Sharing shuru karo',
                      style: const TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<String>(
                valueListenable: Sharer.I.status,
                builder: (_, s, __) => Text(s, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 12),
              const Text(
                'Ek baar "shuru karo" dabane ke baad app khulte hi sharing '
                'apne aap chalu ho jaati hai. Kabhi bhi band kar sakte ho.\n\n'
                'Behtar chalne ke liye: phone Settings me is app ko '
                'Battery "Unrestricted" karo aur Battery Saver band rakho.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
