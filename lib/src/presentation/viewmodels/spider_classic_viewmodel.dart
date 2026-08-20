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
  static const _notifyThrottle = Duration(milliseconds: 150);
  static const _consolePrintThrottle = Duration(milliseconds: 1000);

  bool isDiscovering = false;
  bool isConnected = false;
  String? connectedMac;
  String? connectedName;

  bool isSdkConnected = false;
  String? sdkConnectedMac;
  String? sdkConnectedName;

  final Map<String, Map<String, dynamic>> foundDevices = {};
  final Map<String, Map<String, dynamic>> bondedDevices = {};

  List<String> commandLogs = [];

  int framesReceived = 0;
  DateTime? lastFrameAt;

  StreamSubscription? _eventSubscription;

  DateTime? _lastRecvPrintAt;
  DateTime? _lastSentPrintAt;
  DateTime? _lastNotifyAt;

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

      if (message.contains("⬅️ Recebido")) {
        final now = DateTime.now();
        framesReceived++;
        lastFrameAt = now;
        if (_lastRecvPrintAt == null ||
            now.difference(_lastRecvPrintAt!) >= _consolePrintThrottle) {
          _lastRecvPrintAt = now;
          debugPrint("SPIDER_SPP: $message");
        }
        _notifyThrottled();
        return;
      }
      if (message.contains("➡️ Enviado")) {
        final now = DateTime.now();
        if (_lastSentPrintAt == null ||
            now.difference(_lastSentPrintAt!) >= _consolePrintThrottle) {
          _lastSentPrintAt = now;
          debugPrint("SPIDER_SPP: $message");
        }
        _notifyThrottled();
        return;
      }

      if (message.startsWith("[SDK]")) {
        _log(message);
        if (message.contains("✅ CONECTADO")) {
          isSdkConnected = true;
          sdkConnectedMac = map['mac'] as String?;
          sdkConnectedName = map['name'] as String?;
          notifyListeners();
        } else if (message.contains("Desconectado") ||
            message.contains("❌ Falha ao conectar") ||
            message.contains("desligado")) {
          isSdkConnected = false;
          sdkConnectedMac = null;
          sdkConnectedName = null;
          notifyListeners();
        }
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

  void _notifyThrottled() {
    final now = DateTime.now();
    if (_lastNotifyAt == null ||
        now.difference(_lastNotifyAt!) >= _notifyThrottle) {
      _lastNotifyAt = now;
      notifyListeners();
    }
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

  /// Conecta via com.boby.bluetoothconnect.services.BluetoothChatService —
  /// a classe real do SDK, usada internamente por LinkManager.writeToDevice
  /// (ver MainActivity.kt: connectClassicViaSdk). Independente da conexão
  /// raw; pode coexistir com ela pro mesmo MAC.
  Future<void> connectSdk(String macAddress) async {
    if (!await _ensurePermissions()) return;
    _log("Tentando conectar via BluetoothChatService oficial do SDK...");
    try {
      await _methodChannel.invokeMethod('connectSdk', {
        'macAddress': macAddress,
      });
    } catch (e) {
      _log("Erro ao conectar via SDK: $e");
    }
  }

  Future<void> disconnectSdk() async {
    try {
      await _methodChannel.invokeMethod('disconnectSdk');
    } catch (e) {
      _log("Erro ao desconectar SDK: $e");
    }
    isSdkConnected = false;
    sdkConnectedMac = null;
    sdkConnectedName = null;
    notifyListeners();
  }

  Future<void> sendSdkHex(List<int> bytes) async {
    try {
      await _methodChannel.invokeMethod('sendSdkHex', {'bytes': bytes});
    } catch (e) {
      _log("Erro ao enviar via SDK: $e");
    }
  }

  /// true quando ALGUM canal (raw/canal customizado OU SDK/canal genérico)
  /// está pronto pra receber bytes agora — usado pelo relay real da tiara
  /// (ver TiaraRawViewModel) e pelo injetor mock. IMPORTANTE: até agora só
  /// o canal SDK (`connectSdk`, RFCOMM canal 2, UUID SPP padrão) tinha botão
  /// na UI — o canal raw (`connect`, que tenta o UUID customizado/canal 1
  /// PRIMEIRO — nossa aposta principal de canal de controle real, ver
  /// docs/FUNCIONAMENTO.md §3.2) nunca chegou a ser testado com payload
  /// nenhum. Por isso `relay`/`canRelay` agora preferem o canal raw quando
  /// ele está conectado.
  bool get canRelay => isConnected || isSdkConnected;

  /// Manda [bytes] pelo canal que estiver de fato conectado — prioriza o
  /// canal raw (canal 1 customizado) sobre o SDK (canal 2 genérico), já que
  /// o primeiro é o candidato mais forte a canal de controle real.
  Future<void> relay(List<int> bytes) async {
    if (isConnected) {
      await sendHex(bytes);
    } else if (isSdkConnected) {
      await sendSdkHex(bytes);
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
  /// e achar qual valor dispara/controla o movimento. [tiaraFrame], quando
  /// informado (ver TiaraRawViewModel.describeCurrentFrame), grava o byte
  /// exato que estava sendo mandado nesse instante — sem isso teríamos que
  /// cruzar timestamps manualmente contra o console.
  void markMoving(int speed, {String? tiaraFrame}) {
    final frameInfo = tiaraFrame != null ? " | Byte tiara: $tiaraFrame" : "";
    final line = "🕷️▶️ ANDANDO — Velocidade $speed$frameInfo";
    _log(line);
    debugPrint("SPIDER_MOVEMENT: [${_timestamp()}] $line");
  }

  /// Marca manualmente que a aranha parou de andar.
  void markStopped({String? tiaraFrame}) {
    final frameInfo = tiaraFrame != null ? " | Byte tiara: $tiaraFrame" : "";
    final line = "🕷️⏹️ PAROU$frameInfo";
    _log(line);
    debugPrint("SPIDER_MOVEMENT: [${_timestamp()}] $line");
  }

  String _timestamp() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}";
  }

  /// Reenvia bytes REAIS já capturados da tiara (ver
  /// TiaraRawViewModel.rawByteHistory) tal como foram recebidos — sem
  /// nenhuma edição/reconstrução. Serve como teste de validação: mesmo que o
  /// trecho não contenha um pacote de atenção alta, é tráfego genuinamente
  /// válido (framing e checksum reais), então não custa nada testar se ALGO
  /// nesse padrão real (em vez de sintético) já é suficiente pra aranha
  /// reagir.
  Future<void> replayBytes(List<int> bytes) async {
    if (bytes.isEmpty) {
      _log("🔁 Nada pra reenviar — sem histórico real capturado ainda.");
      return;
    }
    await relay(bytes);
    _log("🔁 Reenviado bloco REAL capturado da tiara (${bytes.length} bytes, sem edição)");
  }

  void clearLogs() {
    commandLogs.clear();
    framesReceived = 0;
    _lastRecvPrintAt = null;
    _lastSentPrintAt = null;
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
    if (isSdkConnected) disconnectSdk();
    _eventSubscription?.cancel();
    super.dispose();
  }
}
