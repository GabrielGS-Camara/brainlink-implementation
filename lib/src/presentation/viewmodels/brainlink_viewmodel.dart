import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../domain/models/ble_device.dart';
import '../../domain/models/brain_data.dart';

class BrainLinkViewModel extends ChangeNotifier {
  final _methodChannel = const MethodChannel('brainlink_channel');
  final _scanEventChannel = const EventChannel('brainlink_scan_channel');
  final _dataEventChannel = const EventChannel('brainlink_data_channel');

  bool isScanning = false;
  bool isConnected = false;
  bool isReconnecting = false;
  BleDevice? connectedDevice;

  // Log bruto de TUDO que a tiara real manda, campo a campo, pra usar como
  // referência exata na hora de montar os pacotes mockados pra aranha.
  List<String> rawLogs = [];

  List<BleDevice> discoveredDevices = [];
  BrainData currentData = BrainData(
    attention: 0,
    meditation: 0,
    signal: 100,
    delta: 0,
    theta: 0,
    lowAlpha: 0,
    highAlpha: 0,
    lowBeta: 0,
    highBeta: 0,
    lowGamma: 0,
    middleGamma: 0,
    battery: 0,
    gravityX: 0,
    gravityY: 0,
    gravityZ: 0,
    blink: 0,
    heartRate: 0,
    grind: 0,
    isDistracted: false,
  );

  StreamSubscription? _scanSubscription;
  StreamSubscription? _dataSubscription;
  Timer? _reconnectTimer;

  BrainLinkViewModel() {
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method == 'onConnectionLost') {
        _handleConnectionLost();
      }
    });
  }

  void _handleConnectionLost() {
    if (isReconnecting) return;
    isConnected = false;
    isReconnecting = true;
    _dataSubscription?.cancel();
    notifyListeners();

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (connectedDevice != null) {
        final success = await _methodChannel.invokeMethod<bool>('connect', {
          'macAddress': connectedDevice!.mac,
        });

        if (success == true) {
          timer.cancel();
          isReconnecting = false;
          isConnected = true;
          _startListeningToBrain();
          notifyListeners();
        }
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> startScan() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    if (statuses[Permission.location]!.isDenied ||
        statuses[Permission.bluetoothScan]!.isDenied) {
      return;
    }

    discoveredDevices.clear();
    isScanning = true;
    notifyListeners();

    _scanSubscription?.cancel();
    _scanSubscription = _scanEventChannel.receiveBroadcastStream().listen((
      event,
    ) {
      final map = event as Map<dynamic, dynamic>;
      final device = BleDevice(name: map['name'], mac: map['mac']);

      if (!discoveredDevices.any((d) => d.mac == device.mac)) {
        discoveredDevices.add(device);
        notifyListeners();
      }
    });

    await _methodChannel.invokeMethod('startScan');
    Future.delayed(const Duration(seconds: 10), () {
      isScanning = false;
      _scanSubscription?.cancel();
      notifyListeners();
    });
  }

  Future<void> connectToDevice(BleDevice device) async {
    isScanning = false;
    _scanSubscription?.cancel();

    final success = await _methodChannel.invokeMethod<bool>('connect', {
      'macAddress': device.mac,
    });
    if (success == true) {
      isConnected = true;
      isReconnecting = false;
      connectedDevice = device;
      _reconnectTimer?.cancel();
      _startListeningToBrain();
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await _methodChannel.invokeMethod('disconnect');
    isConnected = false;
    isReconnecting = false;
    connectedDevice = null;
    _dataSubscription?.cancel();
    _reconnectTimer?.cancel();
    notifyListeners();
  }

  void _startListeningToBrain() {
    _dataSubscription?.cancel();
    _dataSubscription = _dataEventChannel.receiveBroadcastStream().listen((
      event,
    ) {
      final map = event as Map<dynamic, dynamic>;
      currentData = BrainData.fromMap(map);
      _logRaw(map);

      notifyListeners();
    });
  }

  /// Loga TODOS os campos que vieram nesse evento, sem filtrar nada — é a
  /// referência de "como a tiara real manda os dados" pra montar os
  /// pacotes mockados que vão pra aranha.
  void _logRaw(Map<dynamic, dynamic> map) {
    final now = DateTime.now();
    final time =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}";
    final fields = map.entries.map((e) => "${e.key}=${e.value}").join(" | ");
    final line = "[$time] $fields";
    rawLogs.insert(0, line);
    if (rawLogs.length > 500) {
      rawLogs.removeRange(500, rawLogs.length);
    }
    debugPrint("TIARA_RAW: $line");
  }

  void clearRawLogs() {
    rawLogs.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _dataSubscription?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
