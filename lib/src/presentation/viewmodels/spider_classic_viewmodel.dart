import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Conecta na aranha via Bluetooth Clássico (SPP/RFCOMM), pulando o fluxo
/// de pareamento do Android inteiramente — mesma abordagem usada pelo SDK
/// oficial da MacrotellectLink para conectar na tiara clássica
/// (BlueManager$ConnectDeviceRunnable: createInsecureRfcommSocketToServiceRecord
/// com o UUID padrão de SPP, sem createBond()). Ver MainActivity.kt.
class SpiderClassicViewModel extends ChangeNotifier {
  static const _methodChannel = MethodChannel('spider_classic_channel');
  static const _eventChannel = EventChannel('spider_classic_events');

  bool isDiscovering = false;
  bool isConnected = false;
  String? connectedMac;
  String? connectedName;

  // MAC -> {name, rssi}
  final Map<String, Map<String, dynamic>> foundDevices = {};
  // MAC -> {name} — dispositivos já pareados (bond state = BONDED), não
  // depende de descoberta nova.
  final Map<String, Map<String, dynamic>> bondedDevices = {};

  // Log "de valor" — status de conexão/erro/marcações de movimento —
  // visível na tela. Bytes recebidos em si (ex: heartbeat repetido) só vão
  // pro console, senão a tela vira um fluxo ilegível de spam.
  List<String> commandLogs = [];

  int framesReceived = 0;
  DateTime? lastFrameAt;

  StreamSubscription? _eventSubscription;

  SpiderClassicViewModel() {
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen((event) {
      final map = event as Map<dynamic, dynamic>;
      final message = map['message'] as String? ?? event.toString();

      if (map.containsKey('mac') && map.containsKey('rssi')) {
        final mac = map['mac'] as String;
        foundDevices[mac] = {
          'name': map['name'] as String?,
          'rssi': map['rssi'],
        };
        notifyListeners();
      } else if (map.containsKey('mac') && map['bonded'] == true) {
        final mac = map['mac'] as String;
        bondedDevices[mac] = {'name': map['name'] as String?};
        notifyListeners();
      }

      // Bytes recebidos (heartbeat da aranha etc.) são de alto volume —
      // só contamos e mandamos pro console, sem poluir a tela.
      if (message.startsWith("⬅️ Recebido")) {
        framesReceived++;
        lastFrameAt = DateTime.now();
        debugPrint("SPIDER_SPP: $message");
        notifyListeners();
        return;
      }

      _log(message);

      if (message.startsWith("✅ CONECTADO")) {
        isConnected = true;
        connectedMac = map['mac'] as String?;
        connectedName = map['name'] as String?;
        notifyListeners();
      } else if (message.contains("Desconectado") ||
          message.contains("encerrada") ||
          message.startsWith("❌ Falha ao conectar")) {
        isConnected = false;
        connectedMac = null;
        connectedName = null;
        notifyListeners();
      }
    }, onError: (e) => _log("Erro no canal de eventos: $e"));
  }

  Future<bool> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    if (statuses[Permission.bluetoothScan]!.isDenied ||
        statuses[Permission.bluetoothConnect]!.isDenied) {
      _log("Permissões negadas — não é possível usar o modo clássico.");
      return false;
    }
    return true;
  }

  Future<void> startDiscovery() async {
    if (!await _ensurePermissions()) return;
    foundDevices.clear();
    isDiscovering = true;
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('startDiscovery');
    } catch (e) {
      _log("Erro ao iniciar busca clássica: $e");
    }
  }

  Future<void> stopDiscovery() async {
    try {
      await _methodChannel.invokeMethod('stopDiscovery');
    } catch (e) {
      _log("Erro ao parar busca clássica: $e");
    }
    isDiscovering = false;
    notifyListeners();
  }

  Future<void> listBonded() async {
    if (!await _ensurePermissions()) return;
    bondedDevices.clear();
    notifyListeners();
    try {
      await _methodChannel.invokeMethod('listBonded');
    } catch (e) {
      _log("Erro ao listar pareados: $e");
    }
  }

  Future<void> checkStatus() async {
    try {
      await _methodChannel.invokeMethod('checkStatus');
    } catch (e) {
      _log("Erro ao checar status: $e");
    }
  }

  Future<void> connect(String macAddress) async {
    if (!await _ensurePermissions()) return;
    _log("Tentando conectar via SPP em $macAddress (sem pareamento prévio)...");
    try {
      await _methodChannel.invokeMethod('connect', {'macAddress': macAddress});
    } catch (e) {
      _log("Erro ao conectar: $e");
    }
  }

  Future<void> sendHex(List<int> bytes) async {
    try {
      await _methodChannel.invokeMethod('sendHex', {'bytes': bytes});
    } catch (e) {
      _log("Erro ao enviar: $e");
    }
  }

  Future<void> disconnect() async {
    try {
      await _methodChannel.invokeMethod('disconnect');
    } catch (e) {
      _log("Erro ao desconectar: $e");
    }
    isConnected = false;
    connectedMac = null;
    connectedName = null;
    notifyListeners();
  }

  /// Marca manualmente (observando a aranha com os próprios olhos) que ela
  /// começou/continua andando numa das 3 velocidades — fica no log (tela +
  /// console) com timestamp, pra depois cruzar com os bytes crus da tiara
  /// (TIARA_RAW_BYTES no console) e achar qual valor dispara/controla o
  /// movimento.
  void markMoving(int speed) {
    final line = "🕷️▶️ ANDANDO — Velocidade $speed";
    _log(line);
    debugPrint("SPIDER_MOVEMENT: [${_timestamp()}] $line");
  }

  /// Marca manualmente que a aranha parou de andar.
  void markStopped() {
    const line = "🕷️⏹️ PAROU";
    _log(line);
    debugPrint("SPIDER_MOVEMENT: [${_timestamp()}] $line");
  }

  String _timestamp() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}";
  }

  void clearLogs() {
    commandLogs.clear();
    framesReceived = 0;
    notifyListeners();
  }

  void _log(String message) {
    final line = "[${_timestamp()}] $message";
    commandLogs.insert(0, line);
    if (commandLogs.length > 200) {
      commandLogs.removeRange(200, commandLogs.length);
    }
    debugPrint("SPIDER_SPP: $line");
    notifyListeners();
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }
}
