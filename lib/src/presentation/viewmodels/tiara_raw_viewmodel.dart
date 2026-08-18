import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'spider_classic_viewmodel.dart';

/// Conecta DIRETO na tiara via BLE central (sem passar pelo SDK oficial/
/// LinkManager), nos mesmos UUIDs já confirmados por decompilação e pelo
/// log real de conexão (serviço 6e400001, característica de notificação
/// 6e400003) — pra capturar os bytes EXATAMENTE como chegam pelo ar, sem
/// nenhuma formatação/decodificação, e opcionalmente retransmitir esses
/// mesmos bytes crus direto pra aranha (via SpiderClassicViewModel), sem
/// reconstruir/simular nada.
class TiaraRawViewModel extends ChangeNotifier {
  static final Guid serviceUuid = Guid("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
  static final Guid notifyCharUuid = Guid(
    "6e400003-b5a3-f393-e0a9-e50e24dcca9e",
  );

  SpiderClassicViewModel? spiderClassicViewModel;

  bool isScanning = false;
  bool isConnected = false;
  BluetoothDevice? device;
  bool relayToSpider = false;

  // Status "de valor" (conectar/desconectar/erros) — não os bytes crus,
  // esses só vão pro console (debugPrint) pra não poluir a tela.
  List<String> statusLogs = [];

  // Contadores pra dar sinal visual de que dados estão fluindo sem
  // precisar mostrar cada pacote na tela.
  int packetsReceived = 0;
  int bytesReceived = 0;
  DateTime? lastPacketAt;

  List<ScanResult> scanResults = [];

  StreamSubscription? _scanSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;

  /// Liga esse viewmodel ao da aranha, pra poder retransmitir bytes.
  void attachSpider(SpiderClassicViewModel vm) {
    spiderClassicViewModel = vm;
  }

  Future<bool> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    if (statuses[Permission.bluetoothScan]!.isDenied ||
        statuses[Permission.location]!.isDenied) {
      _log("Permissões negadas.");
      return false;
    }
    return true;
  }

  Future<void> startScan() async {
    if (!await _ensurePermissions()) return;
    scanResults.clear();
    isScanning = true;
    notifyListeners();

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      scanResults = results
          .where((r) => r.device.advName.toLowerCase().contains('brainlink'))
          .toList();
      notifyListeners();
    }, onError: (e) => _log("Erro no scan: $e"));

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      _log("Erro ao iniciar scan: $e");
    }
    isScanning = false;
    notifyListeners();
  }

  Future<void> connect(BluetoothDevice d) async {
    await FlutterBluePlus.stopScan();
    isScanning = false;
    device = d;
    _log("Conectando direto (raw, sem SDK) em ${d.remoteId}...");
    try {
      await d.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 12),
      );

      _connStateSub?.cancel();
      _connStateSub = d.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && isConnected) {
          _log("Tiara desconectou (evento externo).");
          isConnected = false;
          notifyListeners();
        }
      });

      final services = await d.discoverServices();
      BluetoothCharacteristic? notifyChar;
      for (final s in services) {
        if (s.uuid == serviceUuid) {
          for (final c in s.characteristics) {
            if (c.uuid == notifyCharUuid) {
              notifyChar = c;
            }
          }
        }
      }

      if (notifyChar == null) {
        _log(
          "Característica de notificação (6e400003) não encontrada — "
          "confira se é o mesmo modelo de tiara.",
        );
        return;
      }

      await notifyChar.setNotifyValue(true);
      _notifySub?.cancel();
      _notifySub = notifyChar.onValueReceived.listen(_onRawBytes);

      isConnected = true;
      _log("=== CONECTADO direto na tiara (raw) -> capturando bytes crus ===");
    } catch (e) {
      _log("Erro ao conectar: $e");
    }
    notifyListeners();
  }

  void _onRawBytes(List<int> bytes) {
    packetsReceived++;
    bytesReceived += bytes.length;
    lastPacketAt = DateTime.now();

    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    _debugLog("⬅️ RAW (${bytes.length} bytes): $hex");

    if (relayToSpider) {
      final spider = spiderClassicViewModel;
      if (spider != null && spider.isConnected) {
        spider.sendHex(bytes);
        _debugLog(
          "↪️ Retransmitido pra aranha SEM modificação (${bytes.length} bytes)",
        );
      } else {
        _debugLog(
          "↪️ Retransmissão ligada mas aranha não está conectada — ignorado.",
        );
      }
    }
    notifyListeners();
  }

  void toggleRelay(bool value) {
    relayToSpider = value;
    _log(
      value
          ? "=== Retransmissão pra aranha LIGADA (bytes crus, sem reconstrução) ==="
          : "=== Retransmissão pra aranha DESLIGADA ===",
    );
    notifyListeners();
  }

  Future<void> disconnect() async {
    try {
      await device?.disconnect();
    } catch (e) {
      _log("Erro ao desconectar: $e");
    }
    await _notifySub?.cancel();
    await _connStateSub?.cancel();
    isConnected = false;
    device = null;
    _log("Desconectado da tiara (raw).");
    notifyListeners();
  }

  void clearLogs() {
    statusLogs.clear();
    packetsReceived = 0;
    bytesReceived = 0;
    notifyListeners();
  }

  String _timestamp() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}";
  }

  /// Log "de valor" — status de conexão/erro — visível na tela.
  void _log(String message) {
    final line = "[${_timestamp()}] $message";
    statusLogs.insert(0, line);
    if (statusLogs.length > 200) {
      statusLogs.removeRange(200, statusLogs.length);
    }
    debugPrint("TIARA_RAW_BYTES: $line");
    notifyListeners();
  }

  /// Log só pro console (logcat) — bytes crus e confirmações de relay, alto
  /// volume demais pra mostrar na tela, mas essencial pra reverse engineering.
  void _debugLog(String message) {
    debugPrint("TIARA_RAW_BYTES: [${_timestamp()}] $message");
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _notifySub?.cancel();
    _connStateSub?.cancel();
    super.dispose();
  }
}
