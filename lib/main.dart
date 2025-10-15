// UPDATED 2025-10-15
// Saves CSV directly to file and includes a share button for the last recorded file.
// Sensors: accelerometer, gyroscope, magnetometer, linear accelerometer (userAcc), gravity (computed), orientation (pitch/roll/yaw computed).
// Pressure column is included but left blank unless a pressure plugin is later added.
// Falls back to app-specific directory if creating /storage/emulated/0/Log_Data fails.

import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const IMUApp());
}

class IMUApp extends StatelessWidget {
  const IMUApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Telemetry Collector v9 (Shareable)',
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

  // ===== Sensor subscriptions =====
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<UserAccelerometerEvent>?
      _userAccSub; // linear acceleration
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  Timer? _sampler; // periodic sampler to enforce target Hz

  // ===== Last sensor readings =====
  AccelerometerEvent? _lastAcc; // includes gravity
  UserAccelerometerEvent? _lastUserAcc; // linear acceleration (gravity removed)
  GyroscopeEvent? _lastGyro; // angular velocity (rad/s)
  MagnetometerEvent? _lastMag; // magnetic field (µT)

  // Computed
  List<double>? _lastGravity; // gx, gy, gz (m/s^2), computed as acc - userAcc
  List<double>? _lastOrient; // yaw (azimuth), pitch, roll in degrees

  // ===== UI / state =====
  bool _isRecording = false;
  String _label = "";
  DateTime? _sessionStart;
  int _sampleIndex = 0; // global sample index for the session
  File? _csvFile;
  IOSink? _sink; // File sink for direct writing
  String? _fixedDirPath; // resolved save directory path
  String? _lastRecordedFilePath; // To enable the share button

  @override
  void initState() {
    super.initState();
    _requestStoragePermission(); // Request permission on start
    _attachRawStreams();
    _resolveSaveDirectory();
  }

  Future<void> _requestStoragePermission() async {
    var status = await Permission.storage.status;
    if (!status.isGranted) {
      await Permission.storage.request();
    }
  }

  void _attachRawStreams() {
    _accSub = accelerometerEventStream().listen((e) {
      _lastAcc = e;
    });
    _userAccSub = userAccelerometerEventStream().listen((e) {
      _lastUserAcc = e;
    });
    _gyroSub = gyroscopeEventStream().listen((e) => _lastGyro = e);
    _magSub = magnetometerEventStream().listen((e) => _lastMag = e);
  }

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
        final docs = await getApplicationDocumentsDirectory();
        final folder = Directory('${docs.path}/Log_Data');
        if (!(await folder.exists())) {
          await folder.create(recursive: true);
        }
        dirPath = folder.path;
      } else {
        final base = await getApplicationDocumentsDirectory();
        final folder = Directory('${base.path}/Log_Data');
        if (!(await folder.exists())) await folder.create(recursive: true);
        dirPath = folder.path;
      }
    } catch (_) {
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

    // Reset last file path to disable share button for the new session
    setState(() {
      _lastRecordedFilePath = null;
    });

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

    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final safeLabel =
        _label.trim().isEmpty ? 'unlabeled' : _label.trim().replaceAll(' ', '_');
    final path = '$_fixedDirPath/telemetry_${safeLabel}_$ts.csv';
    _csvFile = File(path);

    _sink = _csvFile!.openWrite(mode: FileMode.write);

    final header = 'timestamp_iso,session_ms,sample_idx,'
        'acc_x,acc_y,acc_z,'
        'useracc_x,useracc_y,useracc_z,'
        'gravity_x,gravity_y,gravity_z,'
        'gyro_x,gyro_y,gyro_z,'
        'mag_x,mag_y,mag_z,'
        'yaw_deg,pitch_deg,roll_deg,'
        'pressure_hpa,'
        'label';
    _sink!.writeln(header);

    _sessionStart = DateTime.now();
    _sampleIndex = 0;

    final intervalMs = (1000 / _selectedHz).round();
    _sampler = Timer.periodic(
      Duration(milliseconds: intervalMs),
      _onSampleTick,
    );

    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    _sampler?.cancel();

    await _sink?.flush();
    await _sink?.close();
    _sink = null;

    // Update state to enable the share button with the correct file path
    setState(() {
      _isRecording = false;
      _lastRecordedFilePath = _csvFile?.path;
    });
  }

  Future<void> _shareLastFile() async {
    if (_lastRecordedFilePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paylaşılacak bir dosya bulunmuyor.')),
      );
      return;
    }
    try {
      final fileToShare = XFile(_lastRecordedFilePath!);
      await Share.shareXFiles(
        [fileToShare],
        text: 'Toplanan Telemetri Verisi: ${fileToShare.name}',
      );
    } catch (e) {
      print('Dosya paylaşılırken hata oluştu: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Dosya paylaşılamadı: $e')),
      );
    }
  }

  void _onSampleTick(Timer t) {
    if (_lastAcc == null ||
        _lastGyro == null ||
        _lastMag == null ||
        _lastUserAcc == null ||
        _sink == null) {
      return;
    }

    final now = DateTime.now();
    final sessionMs =
        _sessionStart == null ? 0 : now.difference(_sessionStart!).inMilliseconds;

    final acc = _lastAcc!;
    final uacc = _lastUserAcc!;
    final gyr = _lastGyro!;
    final mag = _lastMag!;

    final gx = acc.x - uacc.x;
    final gy = acc.y - uacc.y;
    final gz = acc.z - uacc.z;
    _lastGravity = [gx, gy, gz];

    final ax = acc.x, ay = acc.y, az = acc.z;
    final an = math.sqrt(ax * ax + ay * ay + az * az);
    final axn = an == 0 ? 0.0 : ax / an;
    final ayn = an == 0 ? 0.0 : ay / an;
    final azn = an == 0 ? 0.0 : az / an;

    final roll = math.atan2(ayn, azn);
    final pitch = math.atan2(-axn, math.sqrt(ayn * ayn + azn * azn));

    final mx = mag.x, my = mag.y, mz = mag.z;
    final sinRoll = math.sin(roll), cosRoll = math.cos(roll);
    final sinPitch = math.sin(pitch), cosPitch = math.cos(pitch);
    final mx2 = mx * cosPitch + mz * sinPitch;
    final my2 =
        mx * sinRoll * sinPitch + my * cosRoll - mz * sinRoll * cosPitch;
    final yaw = math.atan2(-my2, mx2);

    double toDeg(num r) => r * 180.0 / math.pi;
    double wrap180(double d) {
      var x = d;
      while (x <= -180) x += 360;
      while (x > 180) x -= 360;
      return x;
    }

    final yawDeg = wrap180(toDeg(yaw));
    final pitchDeg = wrap180(toDeg(pitch));
    final rollDeg = wrap180(toDeg(roll));
    _lastOrient = [yawDeg, pitchDeg, rollDeg];

    final row = [
      now.toIso8601String(),
      sessionMs,
      _sampleIndex,
      acc.x.toStringAsFixed(6),
      acc.y.toStringAsFixed(6),
      acc.z.toStringAsFixed(6),
      uacc.x.toStringAsFixed(6),
      uacc.y.toStringAsFixed(6),
      uacc.z.toStringAsFixed(6),
      gx.toStringAsFixed(6),
      gy.toStringAsFixed(6),
      gz.toStringAsFixed(6),
      gyr.x.toStringAsFixed(6),
      gyr.y.toStringAsFixed(6),
      gyr.z.toStringAsFixed(6),
      mag.x.toStringAsFixed(6),
      mag.y.toStringAsFixed(6),
      mag.z.toStringAsFixed(6),
      yawDeg.toStringAsFixed(3),
      pitchDeg.toStringAsFixed(3),
      rollDeg.toStringAsFixed(3),
      '',
      _label.replaceAll(',', ' '),
    ].join(',');

    _sink!.writeln(row);
    _sampleIndex++;

    if (mounted &&
        _sampleIndex % (_selectedHz ~/ 2 == 0 ? 1 : _selectedHz ~/ 2) == 0) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _sampler?.cancel();
    _sink?.close();
    _accSub?.cancel();
    _userAccSub?.cancel();
    _gyroSub?.cancel();
    _magSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Telemetry Collector')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              physics: const AlwaysScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
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
                              .map(
                                (h) => DropdownMenuItem<int>(
                                  value: h,
                                  child: Text('$h'),
                                ),
                              )
                              .toList(),
                          onChanged: _isRecording
                              ? null
                              : (v) => setState(
                                    () => _selectedHz = v ?? _selectedHz,
                                  ),
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
                        const SizedBox(width: 12),
                        IconButton(
                          icon: const Icon(Icons.share),
                          tooltip: 'Son kaydı paylaş',
                          onPressed:
                              _lastRecordedFilePath != null && !_isRecording
                                  ? _shareLastFile
                                  : null,
                          style: IconButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onSecondaryContainer,
                          ),
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
                              : [_lastAcc!.x, _lastAcc!.y, _lastAcc!.z],
                        ),
                        _SensorCard(
                          title: 'Linear Acc (m/s²)',
                          values: _lastUserAcc == null
                              ? null
                              : [
                                  _lastUserAcc!.x,
                                  _lastUserAcc!.y,
                                  _lastUserAcc!.z,
                                ],
                        ),
                        _SensorCard(
                          title: 'Gravity (m/s²)',
                          values: _lastGravity == null
                              ? null
                              : [
                                  _lastGravity![0],
                                  _lastGravity![1],
                                  _lastGravity![2],
                                ],
                        ),
                        _SensorCard(
                          title: 'Gyroscope (rad/s)',
                          values: _lastGyro == null
                              ? null
                              : [_lastGyro!.x, _lastGyro!.y, _lastGyro!.z],
                        ),
                        _SensorCard(
                          title: 'Magnetometer (µT)',
                          values: _lastMag == null
                              ? null
                              : [_lastMag!.x, _lastMag!.y, _lastMag!.z],
                        ),
                        _OrientCard(values: _lastOrient),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_csvFile != null)
                      Text('Dosya: ${_csvFile!.path.split('/').last}'),
                    Text(
                      'Durum: ${_isRecording ? 'Kayıt yapılıyor ($_sampleIndex örneklem)' : 'Hazır'}',
                    ),
                    Text(
                      'Seans başlangıcı: ${_sessionStart?.toIso8601String() ?? '-'}',
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  final String title;
  final List<double>? values;
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
              Text(
                values == null
                    ? '—'
                    : 'x: ${values![0].toStringAsFixed(4)}\n'
                        'y: ${values![1].toStringAsFixed(4)}\n'
                        'z: ${values![2].toStringAsFixed(4)}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrientCard extends StatelessWidget {
  final List<double>? values;
  const _OrientCard({required this.values});

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
              const Text(
                'Orientation (°)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                values == null
                    ? '—'
                    : 'yaw: ${values![0].toStringAsFixed(1)}\n'
                        'pitch: ${values![1].toStringAsFixed(1)}\n'
                        'roll: ${values![2].toStringAsFixed(1)}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}