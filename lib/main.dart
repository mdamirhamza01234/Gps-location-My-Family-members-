import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show DartPluginRegistrant;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'package:another_telephony/telephony.dart';
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

String mapsLink(double lat, double lng) =>
    'https://www.google.com/maps/search/?api=1&query=$lat,$lng';

/// Internet band hone par SMS bhejne wale family numbers.
Future<List<String>> loadSmsContacts() async {
  final p = await SharedPreferences.getInstance();
  await p.reload();
  try {
    return (jsonDecode(p.getString('sms_contacts') ?? '[]') as List)
        .map((e) => e.toString())
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> saveSmsContacts(List<String> numbers) async {
  final p = await SharedPreferences.getInstance();
  await p.setString('sms_contacts', jsonEncode(numbers));
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
  if (phone == null || !(prefs.getBool('sharing_on') ?? false)) {
    service.stopSelf();
    return;
  }

  StreamSubscription<Position>? posSub;
  StreamSubscription<ServiceStatus>? svcSub;
  StreamSubscription<List<ConnectivityResult>>? connSub;
  bool offlineSmsSent = false;

  /// Internet band hote hi, sirf ek baar, aakhri GPS fix SMS se bhej do.
  Future<void> sendOfflineSms() async {
    if (offlineSmsSent) return;
    offlineSmsSent = true;
    try {
      final contacts = await loadSmsContacts();
      if (contacts.isEmpty) return;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 20));
      final link = mapsLink(pos.latitude, pos.longitude);
      final telephony = Telephony.backgroundInstance;
      final granted = await telephony.requestSmsPermissions ?? false;
      if (!granted) return;
      for (final num in contacts) {
        try {
          await telephony.sendSms(
              to: num,
              message:
                  'Family Locator: internet band hai, ye meri GPS location hai: $link');
        } catch (_) {}
      }
    } catch (_) {}
  }

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

  // Internet band hote hi turant SMS; wapas aane par Firebase apne aap
  // resume ho jaata hai (upar wala position listener).
  connSub = Connectivity().onConnectivityChanged.listen((results) {
    final isOffline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (isOffline) {
      sendOfflineSms();
    } else {
      offlineSmsSent = false;
    }
  });
  final initial = await Connectivity().checkConnectivity();
  if (initial.isEmpty || initial.every((r) => r == ConnectivityResult.none)) {
    await sendOfflineSms();
  }

  service.on('stop').listen((_) async {
    await posSub?.cancel();
    await svcSub?.cancel();
    await connSub?.cancel();
    await setStatus('off');
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
  if (phone != null && (prefs.getBool('sharing_on') ?? false)) {
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
      try {
        await Telephony.instance.requestSmsPermissions;
      } catch (_) {}

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('my_phone', phone);
      await prefs.setBool('sharing_on', true);

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
  final _nameCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _info;
  bool _sharing = true;
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      var h = <Map<String, dynamic>>[];
      try {
        h = (jsonDecode(p.getString('history') ?? '[]') as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } catch (_) {}
      setState(() {
        _sharing = p.getBool('sharing_on') ?? false;
        _history = h;
      });
    });
  }

  /// Recent fetch history: sabse naya upar, max 20, number ke hisaab se ek hi entry.
  Future<void> _addHistory(String phone, String name) async {
    final p = await SharedPreferences.getInstance();
    var keepName = name;
    for (final e in _history) {
      if (e['phone'] == phone && keepName.isEmpty) {
        keepName = (e['name'] as String?) ?? '';
      }
    }
    final list = _history.where((e) => e['phone'] != phone).toList();
    list.insert(0, {
      'phone': phone,
      'name': keepName,
      't': DateTime.now().millisecondsSinceEpoch,
    });
    if (list.length > 20) list.removeRange(20, list.length);
    await p.setString('history', jsonEncode(list));
    if (mounted) setState(() => _history = list);
  }

  Future<void> _deleteHistory(String phone) async {
    final p = await SharedPreferences.getInstance();
    final list = _history.where((e) => e['phone'] != phone).toList();
    await p.setString('history', jsonEncode(list));
    setState(() => _history = list);
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

      await _addHistory(phone, _nameCtrl.text.trim());
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

  Future<void> _editSmsContacts() async {
    final contacts = await loadSmsContacts();
    final ctrl = TextEditingController(text: contacts.join('\n'));
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('SMS fallback numbers'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Jab is phone ka internet band ho jaaye, in numbers par '
                'turant SMS se location bheji jayegi. Ek line me ek number.',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                  hintText: '9876543210\n9123456780',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final numbers = ctrl.text
        .split('\n')
        .map(normalizePhone)
        .where((n) => n.length == 10)
        .toSet()
        .toList();
    await saveSmsContacts(numbers);
    try {
      await Telephony.instance.requestSmsPermissions;
    } catch (_) {}
  }

  Future<void> _toggleSharing(bool on) async {
    final p = await SharedPreferences.getInstance();
    final svc = FlutterBackgroundService();
    if (!on) {
      svc.invoke('stop');
      await p.setBool('sharing_on', false);
      setState(() => _sharing = false);
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _error = 'Phone ka Location (GPS) ON karo, phir switch ON karo.');
      return;
    }
    final loc = await Permission.locationWhenInUse.request();
    if (!loc.isGranted) {
      setState(() => _error = 'Location permission zaroori hai.');
      if (loc.isPermanentlyDenied) await openAppSettings();
      return;
    }
    await Permission.notification.request();
    await p.setBool('sharing_on', true);
    if (await svc.isRunning()) {
      svc.invoke('stop');
      await Future.delayed(const Duration(seconds: 1));
    }
    await svc.startService();
    setState(() {
      _sharing = true;
      _error = null;
    });
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family Locator'),
        actions: [
          IconButton(
            tooltip: 'SMS fallback numbers',
            icon: const Icon(Icons.sms_outlined),
            onPressed: _editSmsContacts,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: SwitchListTile(
          secondary: const Icon(Icons.share_location),
          title: const Text('Meri location share'),
          subtitle: Text(_sharing ? 'ON: family dekh sakti hai' : 'OFF'),
          value: _sharing,
          onChanged: _toggleSharing,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Naam (optional)',
              prefixIcon: Icon(Icons.person),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            style: const TextStyle(fontSize: 20),
            decoration: const InputDecoration(
              labelText: 'Mobile number *',
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
          if (_history.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('Recent fetch',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final e in _history)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.history)),
                title: Text((e['name'] as String).isNotEmpty
                    ? e['name'] as String
                    : e['phone'] as String),
                subtitle: Text(
                    '${(e['name'] as String).isNotEmpty ? '${e['phone']} \u2022 ' : ''}'
                    '${ago(DateTime.fromMillisecondsSinceEpoch(e['t'] as int))}'),
                trailing: IconButton(
                  tooltip: 'History se hatao',
                  icon: const Icon(Icons.close),
                  onPressed: () => _deleteHistory(e['phone'] as String),
                ),
                onTap: () {
                  _nameCtrl.text = e['name'] as String;
                  _phoneCtrl.text = e['phone'] as String;
                  _open();
                },
              ),
          ],
        ],
      ),
    );
  }
}
