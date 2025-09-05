// UPDATED 2025-08-19
// Saves CSV to an accessible folder named "Log_Data" on internal storage when possible.
// Sensors: accelerometer, gyroscope, magnetometer (via sensors_plus). No barometer.
// Falls back to app-specific directory if creating /storage/emulated/0/Log_Data fails.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const IMUApp());
}

class IMUApp extends StatelessWidget {
  const IMUApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Telemetry Collector v5',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blueGrey),
      home: const TelemetryHomePage(),
    );
  }
}

class TelemetryHomePage extends StatefulWidget {
  const TelemetryHomePage({super.key});

  @override
  State<TelemetryHomePage> createState() => _TelemetryHomePageState();
}

class _TelemetryHomePageState extends State<TelemetryHomePage> {
  // ===== Config =====
  final List<int> _hzOptions = const [5, 10, 20, 25, 50, 100];
  int _selectedHz = 20; // default 20 Hz
  static const Duration _windowDuration = Duration(seconds: 10); // 10s window

  // ===== Sensor subscriptions =====
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  Timer? _sampler; // periodic sampler to enforce target Hz
  Timer? _windowTimer; // flush window every 10s

  // ===== Last sensor readings =====
  AccelerometerEvent? _lastAcc;
  GyroscopeEvent? _lastGyro;
  MagnetometerEvent? _lastMag;

  // ===== UI / state =====
  bool _isRecording = false;
  String _label = "";
  DateTime? _sessionStart;
  int _windowIndex = 0;
  late List<String> _buffer; // in-memory CSV lines for current 10s window
  File? _csvFile;
  String? _fixedDirPath; // resolved save directory path

  @override
  void initState() {
    super.initState();
    _buffer = <String>[];
    _attachRawStreams();
    _resolveSaveDirectory();
  }

  // Attach to sensor streams (high-rate). We'll sample them at _selectedHz via Timer
  void _attachRawStreams() {
    _accSub = accelerometerEventStream().listen((e) => _lastAcc = e);
    _gyroSub = gyroscopeEventStream().listen((e) => _lastGyro = e);
    _magSub = magnetometerEventStream().listen((e) => _lastMag = e);
  }

  /// Try to use an accessible public-like path on Android: /storage/emulated/0/Log_Data
  /// If not possible, fall back to app-specific directory (Documents or external files).
  Future<void> _resolveSaveDirectory() async {
    String? dirPath;
    try {
      if (Platform.isAndroid) {
        final public = Directory('/storage/emulated/0/Log_Data');
        if (!(await public.exists())) {
          await public.create(recursive: true);
        }
        // Simple writability check
        final probe = File('${public.path}/.probe');
        await probe.writeAsString('ok', mode: FileMode.write);
        await probe.delete();
        dirPath = public.path;
      } else if (Platform.isIOS) {
        // iOS: use app Documents (visible via Files app under app container)
        final docs = await getApplicationDocumentsDirectory();
        final folder = Directory('${docs.path}/Log_Data');
        if (!(await folder.exists())) {
          await folder.create(recursive: true);
        }
        dirPath = folder.path;
      } else {
        // Other platforms (desktop): use Downloads/Log_Data if available
        final base = await getApplicationDocumentsDirectory();
        final folder = Directory('${base.path}/Log_Data');
        if (!(await folder.exists())) await folder.create(recursive: true);
        dirPath = folder.path;
      }
    } catch (_) {
      // Fallback to app-specific external (Android) or Documents (others)
      try {
        if (Platform.isAndroid) {
          final ext = await getExternalStorageDirectory();
          final folder = Directory('${ext!.path}/Log_Data');
          if (!(await folder.exists())) await folder.create(recursive: true);
          dirPath = folder.path;
        } else {
          final docs = await getApplicationDocumentsDirectory();
          final folder = Directory('${docs.path}/Log_Data');
          if (!(await folder.exists())) await folder.create(recursive: true);
          dirPath = folder.path;
        }
      } catch (e) {
        // Last resort: app temp
        final tmp = await getTemporaryDirectory();
        final folder = Directory('${tmp.path}/Log_Data');
        if (!(await folder.exists())) await folder.create(recursive: true);
        dirPath = folder.path;
      }
    }

    if (mounted) {
      setState(() => _fixedDirPath = dirPath);
    } else {
      _fixedDirPath = dirPath;
    }
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;

    if (_fixedDirPath == null) {
      await _resolveSaveDirectory();
      if (_fixedDirPath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Kayıt klasörü oluşturulamadı.')),
          );
        }
        return;
      }
    }

    // Prepare CSV file with timestamp & label in name
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final safeLabel = _label.trim().isEmpty ? 'unlabeled' : _label.trim().replaceAll(' ', '_');
    final path = '$_fixedDirPath/telemetry_${safeLabel}_$ts.csv';
    _csvFile = File(path);

    // Write header once
    final header = 'timestamp_iso,session_ms,window_idx,sample_idx_in_window,'
        'acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,mag_x,mag_y,mag_z,label';
    await _csvFile!.writeAsString('$header\n', mode: FileMode.write, flush: true);

    _buffer.clear();
    _sessionStart = DateTime.now();
    _windowIndex = 0;

    // Start sampler for target Hz
    final intervalMs = (1000 / _selectedHz).round();
    _sampler = Timer.periodic(Duration(milliseconds: intervalMs), _onSampleTick);

    // Start window timer to flush every 10 seconds
    _windowTimer = Timer.periodic(_windowDuration, (_) => _flushWindow());

    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    _sampler?.cancel();
    _windowTimer?.cancel();

    // Flush remaining buffer (partial window)
    await _flushWindow(force: true);

    setState(() => _isRecording = false);
  }

  void _onSampleTick(Timer t) {
    // If we don't have all sensor values yet, skip this tick
    if (_lastAcc == null || _lastGyro == null || _lastMag == null) {
      return;
    }

    final now = DateTime.now();
    final sessionMs = _sessionStart == null ? 0 : now.difference(_sessionStart!).inMilliseconds;

    final acc = _lastAcc!;
    final gyr = _lastGyro!;
    final mag = _lastMag!;

    final sampleIdx = _buffer.length; // index within current 10s window

    final row = [
      now.toIso8601String(),
      sessionMs,
      _windowIndex,
      sampleIdx,
      acc.x.toStringAsFixed(6),
      acc.y.toStringAsFixed(6),
      acc.z.toStringAsFixed(6),
      gyr.x.toStringAsFixed(6),
      gyr.y.toStringAsFixed(6),
      gyr.z.toStringAsFixed(6),
      mag.x.toStringAsFixed(6),
      mag.y.toStringAsFixed(6),
      mag.z.toStringAsFixed(6),
      _label.replaceAll(',', ' '),
    ].join(',');

    _buffer.add(row);

    // Keep UI live values fresh
    if (mounted && sampleIdx % (_selectedHz ~/ 2 == 0 ? 1 : _selectedHz ~/ 2) == 0) {
      setState(() {});
    }
  }

  Future<void> _flushWindow({bool force = false}) async {
    if (_buffer.isEmpty || _csvFile == null) {
      if (force) return; // nothing to flush
      return;
    }
    // Append buffer to file and clear
    final sink = _csvFile!.openWrite(mode: FileMode.append);
    for (final line in _buffer) {
      sink.writeln(line);
    }
    await sink.flush();
    await sink.close();

    _buffer.clear();
    _windowIndex += 1;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Window $_windowIndex yazıldı (${_csvFile!.path.split('/').last})'),
          duration: const Duration(milliseconds: 900),
        ),
      );
    }
  }

  @override
  void dispose() {
    _sampler?.cancel();
    _windowTimer?.cancel();
    _accSub?.cancel();
    _gyroSub?.cancel();
    _magSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Telemetry Collector'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_fixedDirPath != null)
              Text('Kayıt klasörü: $_fixedDirPath'),
            Row(
              children: [
                const Text('Örnekleme (Hz): '),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: _selectedHz,
                  items: _hzOptions
                      .map((h) => DropdownMenuItem<int>(value: h, child: Text('$h')))
                      .toList(),
                  onChanged: _isRecording
                      ? null
                      : (v) => setState(() => _selectedHz = v ?? _selectedHz),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: TextField(
                    enabled: !_isRecording,
                    decoration: const InputDecoration(
                      labelText: 'Etiket (örn. car/bus/train/walk)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => _label = v,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _isRecording ? null : _startRecording,
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Başlat'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _isRecording ? _stopRecording : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Durdur'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _SensorCard(
                  title: 'Accelerometer (m/s²)',
                  values: _lastAcc == null
                      ? null
                      : [
                          _lastAcc!.x,
                          _lastAcc!.y,
                          _lastAcc!.z,
                        ],
                ),
                _SensorCard(
                  title: 'Gyroscope (rad/s)',
                  values: _lastGyro == null
                      ? null
                      : [
                          _lastGyro!.x,
                          _lastGyro!.y,
                          _lastGyro!.z,
                        ],
                ),
                _SensorCard(
                  title: 'Magnetometer (µT)',
                  values: _lastMag == null
                      ? null
                      : [
                          _lastMag!.x,
                          _lastMag!.y,
                          _lastMag!.z,
                        ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_csvFile != null)
              Text('Dosya: ${_csvFile!.path}'),
            Text('Durum: ${_isRecording ? 'Kayıt yapılıyor' : 'Hazır'}'),
            Text('Pencere: 10 saniye  •  Seans başlangıcı: ${_sessionStart?.toIso8601String() ?? '-'}'),
          ],
        ),
      ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  final String title;
  final List<double>? values; // x,y,z
  const _SensorCard({required this.title, required this.values});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: SizedBox(
          width: 260,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(values == null
                  ? '—'
                  : 'x: ${values![0].toStringAsFixed(4)}\n'
                    'y: ${values![1].toStringAsFixed(4)}\n'
                    'z: ${values![2].toStringAsFixed(4)}'),
            ],
          ),
        ),
      ),
    );
  }
}
