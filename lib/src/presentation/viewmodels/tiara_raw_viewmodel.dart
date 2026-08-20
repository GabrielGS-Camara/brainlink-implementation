import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../domain/protocol/tiara_protocol.dart';
import 'spider_classic_viewmodel.dart';

/// Um frame bruto recebido da tiara, com timestamp — a unidade básica
/// usada pra depois cruzar com as marcações manuais de movimento da
/// aranha (ver SpiderClassicViewModel.markMoving/markStopped).
typedef RawFrame = ({DateTime time, String hex});

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

  // Quantos frames crus manter em memória pra análise de padrões — dá pra
  // rolar bastante tempo de captura sem imprimir nada no console.
  static const int _maxHistory = 4000;
  static const _notifyThrottle = Duration(milliseconds: 150);
  static const _warnThrottle = Duration(seconds: 2);
  // Máximo ~1 linha/segundo no console — é isso que fica copiável/colável.
  static const _consolePrintThrottle = Duration(milliseconds: 1000);

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

  // Último frame cru recebido — usado pelas marcações manuais de
  // movimento da aranha (SpiderClassicPanel) pra registrar exatamente
  // qual byte estava sendo mandado no momento observado.
  String? lastFrameHex;
  DateTime? lastFrameTime;

  // Histórico limitado de frames, pronto pra análise de padrões (comparar
  // contra os timestamps das marcações de "andando"/"parou").
  final List<RawFrame> frameHistory = [];

  // Decodificação AO VIVO do stream bruto, usando o layout de bytes
  // reconstruído por descompilação (ver tiara_protocol.dart). É puramente
  // observacional — não influencia o relay em nenhum momento, que continua
  // mandando os bytes originais intactos pra aranha.
  final TiaraFrameDecoder _decoder = TiaraFrameDecoder();
  int? lastAttention;
  int? lastMeditation;
  int? lastSignal;
  int? lastBattery;
  int? lastRawSample;
  DateTime? lastBrainWaveAt;
  int brainWavePacketsSeen = 0;
  int rawPacketsSeen = 0;

  // Buffer dos bytes REAIS mais recentes recebidos da tiara (não hex-string,
  // bytes de verdade) — pra poder reenviar um trecho genuíno pra aranha como
  // teste (ver SpiderClassicViewModel.replayBytes), em vez de só pacotes
  // sintéticos. Cap generoso (um chunk de notificação BLE já visto teve 505
  // bytes) sem crescer sem limite.
  static const int _maxRawByteHistory = 8000;
  final List<int> rawByteHistory = [];

  // Edição AO VIVO do relay: em vez de reencaminhar os bytes exatamente como
  // chegaram, sobrescreve só o(s) campo(s) escolhido(s) (ver
  // tiara_protocol.dart:patchTiaraStream) preservando o resto do pacote real
  // intacto — é a implementação de "leia o que a tiara manda e edite os
  // valores antes de reenviar pra aranha".
  bool editEnabled = false;
  int? forceAttention;
  int? forceMeditation;
  double? rawGain;

  // Achado do usuário testando o injetor mock: se a aranha recebe o MESMO
  // dado por tempo demais, ela PARA (provável watchdog de "sinal parado").
  // Como aqui o valor forçado é uma constante (forceAttention/Meditation),
  // sem isso o campo de atenção sairia idêntico em TODO pacote BrainWave
  // real que passar — por isso aplicamos um jitterzinho no valor forçado a
  // cada pacote, em vez de escrever a constante crua.
  final math.Random _rng = math.Random();
  int _jitterForce(int base) {
    const amount = 4;
    final delta = _rng.nextInt(amount * 2 + 1) - amount;
    return (base + delta).clamp(0, 100);
  }

  List<ScanResult> scanResults = [];

  StreamSubscription? _scanSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;

  DateTime? _lastConsolePrintAt;
  DateTime? _lastNotifyAt;
  DateTime? _lastRelayWarnAt;

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
    final now = DateTime.now();
    packetsReceived++;
    bytesReceived += bytes.length;
    lastPacketAt = now;

    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    lastFrameHex = hex;
    lastFrameTime = now;

    frameHistory.add((time: now, hex: hex));
    if (frameHistory.length > _maxHistory) {
      frameHistory.removeAt(0);
    }

    rawByteHistory.addAll(bytes);
    if (rawByteHistory.length > _maxRawByteHistory) {
      rawByteHistory.removeRange(0, rawByteHistory.length - _maxRawByteHistory);
    }

    // Decodificação ao vivo (observacional) — ver comentário no topo da
    // classe. Roda em cima de uma cópia dos mesmos bytes que acabaram de
    // chegar; não altera nem atrasa o relay abaixo.
    for (final frame in _decoder.feed(bytes)) {
      switch (frame.kind) {
        case 'raw':
          rawPacketsSeen++;
          lastRawSample = frame.fields['value']?.toInt();
          break;
        case 'brainwave':
          brainWavePacketsSeen++;
          lastBrainWaveAt = now;
          lastSignal = frame.fields['signal']?.toInt();
          lastAttention = frame.fields['attention']?.toInt();
          lastMeditation = frame.fields['meditation']?.toInt();
          lastBattery = frame.fields['battery']?.toInt();
          _debugLog(
            "🧠 BrainWave decodificado: sinal=$lastSignal atenção=$lastAttention "
            "meditação=$lastMeditation bateria=$lastBattery | ${frame.hex}",
          );
          break;
      }
    }

    // Throttle por TEMPO, não por conteúdo: dado bruto de EEG é
    // essencialmente ruído analógico — quase nunca dois pacotes seguidos
    // são byte-a-byte idênticos, então "só imprime se mudou" na prática
    // significava "imprime todo pacote" de novo. O que precisa ser raro é
    // a IMPRESSÃO no console (é o que você copia e cola aqui), não a
    // captura — por isso o histórico completo continua sendo gravado em
    // frameHistory acima independente desse throttle.
    if (_lastConsolePrintAt == null ||
        now.difference(_lastConsolePrintAt!) >= _consolePrintThrottle) {
      _lastConsolePrintAt = now;
      _debugLog("⬅️ RAW (${bytes.length} bytes): $hex");
    }

    // O relay em si NUNCA é throttled/pulado — só o log dele é. Retransmite
    // sempre que ligado, senão a aranha perde frames de verdade. canRelay/
    // relay() escolhem sozinhos qual canal da aranha está de fato conectado
    // (ver SpiderClassicViewModel.canRelay/relay).
    if (relayToSpider) {
      final spider = spiderClassicViewModel;
      if (spider != null && spider.canRelay) {
        final toSend = editEnabled
            ? patchTiaraStream(
                bytes,
                forceAttention:
                    forceAttention != null ? _jitterForce(forceAttention!) : null,
                forceMeditation: forceMeditation != null
                    ? _jitterForce(forceMeditation!)
                    : null,
                rawGain: rawGain,
              )
            : bytes;
        spider.relay(toSend);
      } else if (_lastRelayWarnAt == null ||
          now.difference(_lastRelayWarnAt!) >= _warnThrottle) {
        _lastRelayWarnAt = now;
        _debugLog(
          "↪️ Retransmissão ligada mas aranha não está conectada — ignorado.",
        );
      }
    }

    _notifyThrottled(now);
  }

  void _notifyThrottled(DateTime now) {
    if (_lastNotifyAt == null || now.difference(_lastNotifyAt!) >= _notifyThrottle) {
      _lastNotifyAt = now;
      notifyListeners();
    }
  }

  /// Descreve o último frame recebido, pra anexar nas marcações manuais de
  /// movimento (ver SpiderClassicViewModel.markMoving/markStopped).
  String describeCurrentFrame() {
    if (lastFrameHex == null) return "sem dado de tiara ainda";
    final ageMs = lastFrameTime != null
        ? DateTime.now().difference(lastFrameTime!).inMilliseconds
        : null;
    return ageMs != null ? "$lastFrameHex (há ${ageMs}ms)" : lastFrameHex!;
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

  void toggleEdit(bool value) {
    editEnabled = value;
    _log(
      value
          ? "=== Edição ao vivo LIGADA — atenção/meditação/onda serão "
                "sobrescritas antes de sair pra aranha ==="
          : "=== Edição ao vivo DESLIGADA — relay volta a ser bytes originais ===",
    );
    notifyListeners();
  }

  void setForceAttention(int? value) {
    forceAttention = value;
    notifyListeners();
  }

  void setForceMeditation(int? value) {
    forceMeditation = value;
    notifyListeners();
  }

  void setRawGain(double? value) {
    rawGain = value;
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
    frameHistory.clear();
    rawByteHistory.clear();
    packetsReceived = 0;
    bytesReceived = 0;
    rawPacketsSeen = 0;
    brainWavePacketsSeen = 0;
    lastAttention = null;
    lastMeditation = null;
    lastSignal = null;
    lastBattery = null;
    lastRawSample = null;
    lastBrainWaveAt = null;
    _lastConsolePrintAt = null;
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
