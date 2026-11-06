import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui' show DartPluginRegistrant;

import 'package:another_telephony/telephony.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'firebase_options.dart';

const String kAppName = 'Family GPS Tracker';

/// Sab family members ke liye fixed code (app me hi set hai).
const String kFamilyCode = 'bhagalpur2026xyz';

/// Last 10 digits only, so "+91 98765-43210" and "9876543210" match.
String normalizePhone(String input) {
  final digits = input.replaceAll(RegExp(r'\D'), '');
  return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
}

String ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'abhi abhi';
  if (d.inMinutes < 60) return '${d.inMinutes} minute pehle';
  if (d.inHours < 24) return '${d.inHours} ghante pehle';
  return '${d.inDays} din pehle';
}

String mapsLink(double lat, double lng) =>
    'https://www.google.com/maps/search/?api=1&query=$lat,$lng';

// -------------------------------------------------------- DATA MODEL ----
//
// Har sharing karne wale ka ek sthayi "member id" hota hai (phone me hi
// save hota hai, kabhi badalta nahi). Location isi member id ke naam se
// save hoti hai. Har phone number sirf ek chhota "numbers/<phone>" pointer
// hai jo us member id ki taraf ishara karta hai. Number edit/add karne par
// purana pointer kabhi mitaya nahi jaata, isliye purane number se fetch
// karne par bhi wahi (taaza) location milti rehti hai.

DocumentReference<Map<String, dynamic>> _membersCol(String memberId) =>
    FirebaseFirestore.instance
        .collection('families')
        .doc(kFamilyCode)
        .collection('members')
        .doc(memberId);

DocumentReference<Map<String, dynamic>> _numberDoc(String phone) =>
    FirebaseFirestore.instance
        .collection('families')
        .doc(kFamilyCode)
        .collection('numbers')
        .doc(phone);

Future<String> getOrCreateMemberId() async {
  final p = await SharedPreferences.getInstance();
  var id = p.getString('member_id');
  if (id == null) {
    final rnd = Random();
    id = '${DateTime.now().millisecondsSinceEpoch}-${rnd.nextInt(999999)}';
    await p.setString('member_id', id);
  }
  return id;
}

/// Purana pointer kabhi nahi mitaya jaata — isliye purana number bhi
/// hamesha ke liye isi member ki taraf ishara karta rahega.
Future<void> linkNumberToMember(String phone, String memberId) async {
  try {
    await _numberDoc(phone)
        .set({'memberId': memberId}, SetOptions(merge: true));
  } catch (_) {}
}

/// 'my_numbers' (naya format) ya 'my_phone' (purana format, apne aap migrate).
Future<List<String>> loadMyNumbers() async {
  final p = await SharedPreferences.getInstance();
  await p.reload();
  final raw = p.getString('my_numbers');
  if (raw != null) {
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
    } catch (_) {}
  }
  final legacy = p.getString('my_phone');
  if (legacy != null && legacy.isNotEmpty) {
    await p.setString('my_numbers', jsonEncode([legacy]));
    return [legacy];
  }
  return [];
}

Future<void> saveMyNumbers(List<String> numbers) async {
  final p = await SharedPreferences.getInstance();
  await p.setString('my_numbers', jsonEncode(numbers));
}

/// Number se location dhundo: pehle numbers/<phone> se member id nikalo,
/// phir uska location doc padho. Nahi mila to purane (migrate na hue)
/// setup ke liye seedha members/<phone> bhi try karo.
Future<Map<String, dynamic>?> resolveMemberData(String phone) async {
  try {
    final link =
        await _numberDoc(phone).get().timeout(const Duration(seconds: 15));
    final memberId = link.data()?['memberId'] as String?;
    if (memberId != null) {
      final snap = await _membersCol(memberId)
          .get()
          .timeout(const Duration(seconds: 15));
      if (snap.exists) return snap.data();
    }
  } catch (_) {}
  try {
    final legacy =
        await _membersCol(phone).get().timeout(const Duration(seconds: 15));
    if (legacy.exists) return legacy.data();
  } catch (_) {}
  return null;
}

// --------------------------------------- SMS FALLBACK (auto, no typing) ----
//
// SMS fallback numbers manually nahi daale jaate — jo numbers kisi ne bhi
// kabhi is family code me register kiye hain (families/{code}/numbers),
// wahi apne aap SMS recipients hain (apna number chhod kar). Purana number
// edit hone par bhi registry se kabhi hataya nahi jaata, isliye SMS bhi
// usi purane number par jaata rehta hai — fetch wale system jaisa hi.
//
// Ye list internet rahte waqt local cache me save hoti hai, taaki internet
// band hone ke turant baad (jab Firestore padhna mumkin na ho) bhi pata ho
// ki SMS kisko bhejna hai.

/// Family registry se sab numbers padho (apna chhod kar) aur cache update karo.
Future<List<String>> refreshSmsContactsCache() async {
  final mine = await loadMyNumbers();
  final snap = await FirebaseFirestore.instance
      .collection('families')
      .doc(kFamilyCode)
      .collection('numbers')
      .get()
      .timeout(const Duration(seconds: 15));
  final others =
      snap.docs.map((d) => d.id).where((n) => !mine.contains(n)).toList();
  final p = await SharedPreferences.getInstance();
  await p.setString('sms_contacts_cache', jsonEncode(others));
  return others;
}

/// Offline hote waqt isi cache se SMS recipients liye jaate hain.
Future<List<String>> loadSmsContactsCache() async {
  final p = await SharedPreferences.getInstance();
  await p.reload();
  try {
    return (jsonDecode(p.getString('sms_contacts_cache') ?? '[]') as List)
        .map((e) => e.toString())
        .toList();
  } catch (_) {
    return [];
  }
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
  final numbers = await loadMyNumbers();
  if (numbers.isEmpty || !(prefs.getBool('sharing_on') ?? false)) {
    service.stopSelf();
    return;
  }
  final memberId = await getOrCreateMemberId();
  for (final n in numbers) {
    await linkNumberToMember(n, memberId);
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
      final contacts = await loadSmsContactsCache();
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
                  '$kAppName: internet band hai, ye meri GPS location hai: $link');
        } catch (_) {}
      }
    } catch (_) {}
  }

  void notify(String text) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(title: kAppName, content: text);
    }
  }

  Future<void> setStatus(String s) async {
    try {
      await _membersCol(memberId).set(
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
          await _membersCol(memberId).set({
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
  // resume ho jaata hai (upar wala position listener), aur SMS cache bhi
  // taaza ho jaati hai taaki agli baar internet jaane par sahi numbers mile.
  connSub = Connectivity().onConnectivityChanged.listen((results) {
    final isOffline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (isOffline) {
      sendOfflineSms();
    } else {
      offlineSmsSent = false;
      refreshSmsContactsCache();
    }
  });
  final initial = await Connectivity().checkConnectivity();
  if (initial.isEmpty || initial.every((r) => r == ConnectivityResult.none)) {
    await sendOfflineSms();
  } else {
    await refreshSmsContactsCache();
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
      initialNotificationTitle: kAppName,
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

  final numbers = await loadMyNumbers();
  if (numbers.isNotEmpty) {
    final memberId = await getOrCreateMemberId();
    for (final n in numbers) {
      await linkNumberToMember(n, memberId);
    }
    // App khulne par agar internet hai, SMS fallback list bhi taaza kar lo.
    unawaited(refreshSmsContactsCache());
  }

  final prefs = await SharedPreferences.getInstance();
  if (numbers.isNotEmpty && (prefs.getBool('sharing_on') ?? false)) {
    try {
      final svc = FlutterBackgroundService();
      if (!await svc.isRunning()) await svc.startService();
    } catch (_) {}
  }

  final Widget next = numbers.isNotEmpty ? const FindScreen() : const SetupScreen();
  final seenInstructions = prefs.getBool('seen_instructions') ?? false;
  final home = seenInstructions ? next : InstructionsScreen(next: next);
  runApp(FamilyLocatorApp(home: home));
}

class FamilyLocatorApp extends StatelessWidget {
  final Widget home;
  const FamilyLocatorApp({super.key, required this.home});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: home,
    );
  }
}

// -------------------------------------------------------- INSTRUCTIONS ----

class InstructionsScreen extends StatefulWidget {
  final Widget next;
  const InstructionsScreen({super.key, required this.next});

  @override
  State<InstructionsScreen> createState() => _InstructionsScreenState();
}

class _InstructionsScreenState extends State<InstructionsScreen> {
  bool _agreed = false;

  static const _points = [
    'Ye app aapke family ke logo ke beech location share karne ke liye hai. '
        'Koi Google Maps SDK ya API key use nahi hoti.',
    'Aapki location tabhi share hogi jab aap apna number daal kar '
        '"Location share shuru karo" dabayenge. Jab tak khud ON nahi karte, '
        'kisi ko kuch nahi jaata.',
    'Sharing ON hone par notification bar me hamesha ek chhota message '
        'dikhega. Ye Android ka rule hai, hata nahi sakte — isse hamesha '
        'pata rahega ki sharing chal rahi hai.',
    'Location permission maangi jaaye to "Allow all the time" chunein, '
        'warna app band hone ke baad location bhejna band ho jayega.',
    'Phone ki Battery setting me is app ko "Unrestricted" rakhein, warna '
        'Android isse background me band kar sakta hai.',
    'Internet band ho jaaye to app SMS se bhi aakhri location bhej sakta '
        'hai. Iske liye SMS icon se family ke number daalna hoga (optional).',
    'Dusre family member ki location dekhne ke liye unka number daalo aur '
        '"Location fetch karo" dabao — Google Maps khul jayega.',
    'Apna number badalna ho to left-top menu se "Mera number edit karo" me '
        'jao. Purana number badalne ke baad bhi kaam karta rahega.',
  ];

  Future<void> _continue() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('seen_instructions', true);
    if (!mounted) return;
    Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => widget.next));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Instructions')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              itemCount: _points.length,
              itemBuilder: (c, i) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle, color: Colors.teal, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(_points[i],
                            style: const TextStyle(fontSize: 15, height: 1.3))),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _agreed,
                    onChanged: (v) => setState(() => _agreed = v ?? false),
                    title: const Text('Maine ye sab padh liya hai'),
                  ),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _agreed ? _continue : null,
                      child: const Text('Continue', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------- NUMBER ENTRY FORM ----

/// Dono SetupScreen aur "number edit karo" screen isi form ko use karte hain.
class NumbersForm extends StatefulWidget {
  final String number1Initial;
  final String number2Initial;
  final String buttonLabel;
  final Future<void> Function(String number1, String number2) onSave;
  const NumbersForm({
    super.key,
    this.number1Initial = '',
    this.number2Initial = '',
    required this.buttonLabel,
    required this.onSave,
  });

  @override
  State<NumbersForm> createState() => _NumbersFormState();
}

class _NumbersFormState extends State<NumbersForm> {
  late final _ctrl1 = TextEditingController(text: widget.number1Initial);
  late final _ctrl2 = TextEditingController(text: widget.number2Initial);
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    final n1 = normalizePhone(_ctrl1.text);
    final n2 = normalizePhone(_ctrl2.text);
    if (n1.length != 10) {
      setState(() => _error = 'Pehla number 10 digit ka hona chahiye.');
      return;
    }
    if (_ctrl2.text.trim().isNotEmpty && n2.length != 10) {
      setState(() => _error = 'Dusra number 10 digit ka hona chahiye (ya khali chhodo).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(n1, n2.length == 10 ? n2 : '');
    } catch (e) {
      setState(() => _error = 'Kuch gadbad hui: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _ctrl1.dispose();
    _ctrl2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ctrl1,
          keyboardType: TextInputType.phone,
          style: const TextStyle(fontSize: 20),
          decoration: const InputDecoration(
            labelText: 'Mobile number 1 *',
            prefixIcon: Icon(Icons.phone),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ctrl2,
          keyboardType: TextInputType.phone,
          style: const TextStyle(fontSize: 20),
          decoration: const InputDecoration(
            labelText: 'Mobile number 2 (optional)',
            prefixIcon: Icon(Icons.phone_android),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: Text(widget.buttonLabel, style: const TextStyle(fontSize: 18)),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red)),
        ],
      ],
    );
  }
}

// ----------------------------------------------------------- SETUP SCREEN ----

/// Sirf pehli baar: apna number (ya do number) daalo, permission do,
/// sharing hamesha ke liye ON.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  Future<void> _askAlways(BuildContext context) async {
    if (await Permission.locationAlways.isGranted) return;
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

  Future<void> _start(BuildContext context, String n1, String n2) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw 'Phone ka Location (GPS) ON karo, phir dobara dabao.';
    }
    final loc = await Permission.locationWhenInUse.request();
    if (!loc.isGranted) {
      if (loc.isPermanentlyDenied) await openAppSettings();
      throw 'Location permission zaroori hai.';
    }
    await Permission.notification.request();
    if (context.mounted) await _askAlways(context);
    await Permission.ignoreBatteryOptimizations.request();
    try {
      await Telephony.instance.requestSmsPermissions;
    } catch (_) {}

    final numbers = [n1, if (n2.isNotEmpty) n2];
    await saveMyNumbers(numbers);
    final memberId = await getOrCreateMemberId();
    for (final n in numbers) {
      await linkNumberToMember(n, memberId);
    }

    final p = await SharedPreferences.getInstance();
    await p.setBool('sharing_on', true);

    final svc = FlutterBackgroundService();
    if (await svc.isRunning()) {
      svc.invoke('stop');
      await Future.delayed(const Duration(seconds: 1));
    }
    await svc.startService();

    if (context.mounted) {
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const FindScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(kAppName)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NumbersForm(
              buttonLabel: 'Location share shuru karo',
              onSave: (n1, n2) => _start(context, n1, n2),
            ),
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

// --------------------------------------------------- EDIT NUMBERS SCREEN ----

/// Hamburger menu se: apne number edit/add karo. Purana number bhi
/// hamesha ke liye kaam karta rahega (upar NUMBERS data model dekho).
class EditNumbersScreen extends StatelessWidget {
  const EditNumbersScreen({super.key, required this.current});
  final List<String> current;

  Future<void> _save(BuildContext context, String n1, String n2) async {
    final numbers = [n1, if (n2.isNotEmpty) n2];
    await saveMyNumbers(numbers);
    final memberId = await getOrCreateMemberId();
    for (final n in numbers) {
      await linkNumberToMember(n, memberId);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Number save ho gaya.')));
      Navigator.of(context).pop(numbers);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mera number edit karo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NumbersForm(
              number1Initial: current.isNotEmpty ? current[0] : '',
              number2Initial: current.length > 1 ? current[1] : '',
              buttonLabel: 'Save karo',
              onSave: (n1, n2) => _save(context, n1, n2),
            ),
            const SizedBox(height: 16),
            const Text(
              'Number badalne ke baad bhi purana number fetch karne par '
              'kaam karta rahega.',
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
  List<String> _myNumbers = [];
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    var h = <Map<String, dynamic>>[];
    try {
      h = (jsonDecode(p.getString('history') ?? '[]') as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {}
    final numbers = await loadMyNumbers();
    if (!mounted) return;
    setState(() {
      _phoneCtrl.text = p.getString('last_search') ?? '';
      _sharing = p.getBool('sharing_on') ?? false;
      _myNumbers = numbers;
      _history = h;
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

  /// History me naam/number sudharo (naya number alag entry nahi banata).
  Future<void> _editHistoryEntry(Map<String, dynamic> entry) async {
    final nameCtrl = TextEditingController(text: entry['name'] as String);
    final phoneCtrl = TextEditingController(text: entry['phone'] as String);
    final saved = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('History entry edit karo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Naam', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Mobile number', border: OutlineInputBorder()),
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
    final newPhone = normalizePhone(phoneCtrl.text);
    if (newPhone.length != 10) return;
    final p = await SharedPreferences.getInstance();
    final list = _history.where((e) => e['phone'] != entry['phone']).toList();
    list.removeWhere((e) => e['phone'] == newPhone);
    list.insert(0, {
      'phone': newPhone,
      'name': nameCtrl.text.trim(),
      't': DateTime.now().millisecondsSinceEpoch,
    });
    if (list.length > 20) list.removeRange(20, list.length);
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
      final d = await resolveMemberData(phone);
      if (d == null || d['lat'] == null) {
        setState(() => _error = 'Is number ki location abhi nahi mili.');
        return;
      }
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

  /// SMS fallback numbers manual nahi daale jaate — apne aap family registry
  /// se aate hain (apna number chhod kar). Ye dialog sirf dikhata hai ki
  /// abhi kiska number SMS cache me hai, aur "Refresh" se turant update karo.
  Future<void> _showSmsContacts() async {
    try {
      await Telephony.instance.requestSmsPermissions;
    } catch (_) {}
    var contacts = await loadSmsContactsCache();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          title: const Text('SMS fallback numbers'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Jab is phone ka internet band ho jaaye, family ke in '
                  'numbers par turant SMS se location bheji jayegi. Ye list '
                  'apne aap family ke registered numbers se banti hai — '
                  'kuch type nahi karna.',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              if (contacts.isEmpty)
                const Text('Abhi koi number cache me nahi hai.')
              else
                for (final n in contacts) Text('• $n'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                try {
                  final fresh = await refreshSmsContactsCache();
                  setDialogState(() => contacts = fresh);
                } catch (_) {
                  if (c.mounted) {
                    ScaffoldMessenger.of(c).showSnackBar(const SnackBar(
                        content: Text('Internet check karo aur dobara try karo.')));
                  }
                }
              },
              child: const Text('Refresh'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(c), child: const Text('Theek hai')),
          ],
        ),
      ),
    );
  }

  Future<void> _editMyNumbers() async {
    final result = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(
            builder: (_) => EditNumbersScreen(current: _myNumbers)));
    if (result != null && mounted) setState(() => _myNumbers = result);
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
    if (_myNumbers.isEmpty) {
      setState(() => _error = 'Pehle hamburger menu se apna number daalo.');
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
        title: const Text(kAppName),
        actions: [
          IconButton(
            tooltip: 'SMS fallback numbers',
            icon: const Icon(Icons.sms_outlined),
            onPressed: _showSmsContacts,
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            children: [
              DrawerHeader(
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer),
                child: const Text(kAppName,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              ListTile(
                leading: const Icon(Icons.person),
                title: const Text('Mera number edit karo'),
                subtitle:
                    Text(_myNumbers.isEmpty ? 'Koi number nahi' : _myNumbers.join(', ')),
                onTap: () {
                  Navigator.pop(context);
                  _editMyNumbers();
                },
              ),
            ],
          ),
        ),
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
                    '${(e['name'] as String).isNotEmpty ? '${e['phone']} • ' : ''}'
                    '${ago(DateTime.fromMillisecondsSinceEpoch(e['t'] as int))}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Edit karo',
                      icon: const Icon(Icons.edit, size: 20),
                      onPressed: () => _editHistoryEntry(e),
                    ),
                    IconButton(
                      tooltip: 'History se hatao',
                      icon: const Icon(Icons.close),
                      onPressed: () => _deleteHistory(e['phone'] as String),
                    ),
                  ],
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
