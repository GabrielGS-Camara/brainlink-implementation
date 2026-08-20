import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../domain/protocol/tiara_protocol.dart';

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

  // ==========================================================
  // INJETOR DE PACOTES SINTÉTICOS (mock, SEM tiara) — pra testar por
  // tentativa e erro qual campo do protocolo (ver tiara_protocol.dart) a
  // aranha realmente usa como gatilho de movimento. Manda pacotes construídos
  // à mão, respeitando o framing real (AA AA / checksum / 23 23) em vez de
  // flipar bytes cegamente — assim o parser da aranha (se ele validar
  // checksum/formato como o da tiara) não descarta o pacote de cara.
  // ==========================================================
  int mockAttentionValue = 0;
  int mockMeditationValue = 0;
  int mockLowAlpha = 0;
  int mockHighAlpha = 0;
  int mockLowBeta = 0;
  int mockHighBeta = 0;
  bool mockStreaming = false;
  Timer? _mockStreamTimer;

  int mockRawAmplitude = 4000;
  bool mockRawStreaming = false;
  Timer? _mockRawStreamTimer;

  // Achado do usuário: se ela fica recebendo o MESMO dado por tempo demais,
  // ela PARA — provavelmente um watchdog de "sinal parado/desconectado",
  // já que a tiara real nunca manda dois pacotes byte-a-byte idênticos (é
  // ruído analógico). Isso significa que "segurar" um valor artificialmente
  // (`mockStreaming`, os testes de varredura abaixo, o modo de edição ao
  // vivo) SÓ funciona de verdade se o valor balançar um pouquinho a cada
  // envio — daí o jitter (± alguns pontos), ligado por padrão em tudo que
  // "segura" um valor por streaming.
  bool jitterEnabled = true;
  int jitterAmount = 4;
  final _rng = math.Random();

  int _jitter(int base) {
    if (!jitterEnabled || jitterAmount <= 0) return base.clamp(0, 100);
    final delta = _rng.nextInt(jitterAmount * 2 + 1) - jitterAmount;
    return (base + delta).clamp(0, 100);
  }

  void setJitterEnabled(bool value) {
    jitterEnabled = value;
    notifyListeners();
  }

  void setJitterAmount(int value) {
    jitterAmount = value;
    notifyListeners();
  }

  void setMockAttention(int value) {
    mockAttentionValue = value;
    notifyListeners();
  }

  void setMockMeditation(int value) {
    mockMeditationValue = value;
    notifyListeners();
  }

  void setMockRawAmplitude(int value) {
    mockRawAmplitude = value;
    notifyListeners();
  }

  /// Manda UM pacote sintético "BrainWave" (assinatura 20 02) com os valores
  /// atuais de atenção/meditação/bandas (com jitter aplicado nos dois, ver
  /// nota acima) — os campos não usados ficam zerados. Vai pelo canal que
  /// estiver conectado de fato (ver `relay`).
  Future<void> sendMockBrainWave() async {
    final att = _jitter(mockAttentionValue);
    final med = _jitter(mockMeditationValue);
    final bytes = buildBrainWaveFrame(
      attention: att,
      meditation: med,
      lowAlpha: mockLowAlpha,
      highAlpha: mockHighAlpha,
      lowBeta: mockLowBeta,
      highBeta: mockHighBeta,
    );
    await relay(bytes);
    _log(
      "🧪 Mock enviado: BrainWave sintético (atenção=$att, "
      "meditação=$med, lowAlpha=$mockLowAlpha "
      "highAlpha=$mockHighAlpha lowBeta=$mockLowBeta highBeta=$mockHighBeta)",
    );
  }

  /// Preset rápido: perfil "foco" (beta alto, alpha baixo) ou "relaxamento"
  /// (alpha alto, beta baixo) — testa a hipótese de que a aranha (ou algum
  /// firmware intermediário) deriva o gatilho das BANDAS de EEG em vez do
  /// campo de atenção já calculado pela tiara.
  Future<void> sendMockBandPreset({required bool foco}) async {
    mockLowAlpha = foco ? 50 : 500000;
    mockHighAlpha = foco ? 50 : 500000;
    mockLowBeta = foco ? 500000 : 50;
    mockHighBeta = foco ? 500000 : 50;
    notifyListeners();
    await sendMockBrainWave();
    _log(foco
        ? "🧪 Preset 'Foco' aplicado (beta alto, alpha baixo)"
        : "🧪 Preset 'Relaxamento' aplicado (alpha alto, beta baixo)");
  }

  /// Liga/desliga o envio contínuo (2/s) do pacote acima — útil pra testar a
  /// hipótese de que a aranha só reage a atenção alta se ela vier de forma
  /// sustentada, não num pacote isolado (é assim que a tiara real transmite).
  void toggleMockStream(bool enabled) {
    mockStreaming = enabled;
    _mockStreamTimer?.cancel();
    _mockStreamTimer = null;
    if (enabled) {
      _log("🧪 Streaming mock de atenção/meditação LIGADO (2/s)");
      _mockStreamTimer = Timer.periodic(const Duration(milliseconds: 500), (
        _,
      ) {
        sendMockBrainWave();
      });
    } else {
      _log("🧪 Streaming mock DESLIGADO");
    }
    notifyListeners();
  }

  /// Manda uma rajada de amostras RAW sintéticas (código 0x80) com amplitude
  /// configurável — testa a hipótese alternativa de que a aranha reage à
  /// amplitude/variação da onda bruta, não a um valor decodificado.
  Future<void> sendMockRawBurst({int? amplitude, int count = 30}) async {
    final amp = amplitude ?? mockRawAmplitude;
    final bytes = <int>[];
    for (var i = 0; i < count; i++) {
      bytes.addAll(buildRawFrame(i.isEven ? amp : -amp));
    }
    await relay(bytes);
    _log("🧪 Mock enviado: rajada RAW ($count amostras, amplitude ±$amp)");
  }

  /// Liga/desliga o envio contínuo de rajadas RAW — a tiara real manda onda
  /// bruta em fluxo CONTÍNUO e em alta taxa (é o que dominava a captura de
  /// 505 bytes original); uma rajada única de 300 bytes é bem menor/mais
  /// esparsa que isso, então esse modo tenta imitar o padrão real mandando
  /// uma rajada nova a cada 200ms em vez de só uma vez.
  void toggleMockRawStream(bool enabled) {
    mockRawStreaming = enabled;
    _mockRawStreamTimer?.cancel();
    _mockRawStreamTimer = null;
    if (enabled) {
      _log("🧪 Streaming RAW contínuo LIGADO (amplitude ±$mockRawAmplitude)");
      _mockRawStreamTimer = Timer.periodic(const Duration(milliseconds: 200), (
        _,
      ) {
        sendMockRawBurst();
      });
    } else {
      _log("🧪 Streaming RAW contínuo DESLIGADO");
    }
    notifyListeners();
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

  // ==========================================================
  // VARREDURA DE LIMIARES — descobrir o cálculo real que a aranha usa pra
  // escolher velocidade, a partir de 3 pontos que o usuário achou por
  // tentativa e erro:
  //   V1 ~ atenção=35  meditação=60  → diferença=-25  soma=95
  //   V2   atenção=64  meditação=37  → diferença=+27  soma=101
  //   V3 ~ atenção>80  meditação<30  → diferença>+50  soma~100-110
  // Reparo: a SOMA fica sempre perto de 100 nos 3 pontos — pode ser
  // coincidência de amostragem, ou pode ser que a aranha só aceite o dado
  // como "válido/coerente" quando atenção+meditação ≈ 100 (parecido com um
  // "gate" de sanidade), e dentro disso a DIFERENÇA (atenção-meditação)
  // escolha a velocidade. Hipóteses a distinguir:
  //   H1 — limiares INDEPENDENTES por variável (o jeito mais simples de ler
  //        o que o usuário descreveu: "atenção>80 E meditação<30").
  //   H2 — só a DIFERENÇA importa, a soma pode ser qualquer coisa.
  //   H3 — a diferença importa, MAS só dentro de uma soma≈100 (gate duplo).
  // Os 4 testes abaixo, combinados, distinguem as 3 hipóteses.
  // ==========================================================
  bool sweepRunning = false;
  String? sweepStatus;
  int sweepPointIndex = 0;
  int sweepPointTotal = 0;
  bool _sweepCancelled = false;

  void stopSweep() {
    _sweepCancelled = true;
  }

  Future<void> _runSweepPoints(
    List<({int att, int med, String label})> points, {
    required Duration dwell,
  }) async {
    if (sweepRunning) return;
    sweepRunning = true;
    _sweepCancelled = false;
    sweepPointTotal = points.length;
    notifyListeners();

    for (var i = 0; i < points.length; i++) {
      if (_sweepCancelled) break;
      final p = points[i];
      sweepPointIndex = i + 1;
      sweepStatus = p.label;
      _log(
        "🧭 VARREDURA ($sweepPointIndex/$sweepPointTotal): ${p.label} — "
        "segure e marque o movimento (botões acima) se ela reagir",
      );
      notifyListeners();

      final stepEnd = DateTime.now().add(dwell);
      do {
        if (_sweepCancelled) break;
        final bytes = buildBrainWaveFrame(
          attention: _jitter(p.att),
          meditation: _jitter(p.med),
        );
        await relay(bytes);
        await Future.delayed(const Duration(milliseconds: 400));
      } while (DateTime.now().isBefore(stepEnd));
    }

    sweepRunning = false;
    sweepStatus = null;
    _log(_sweepCancelled ? "🧭 Varredura interrompida." : "🧭 Varredura concluída.");
    notifyListeners();
  }

  /// H2/H3 — varre a DIFERENÇA (atenção-meditação) de -100 a +100 mantendo
  /// a SOMA fixa em 100 (atenção=50+diff/2, meditação=50-diff/2). Se H3
  /// estiver certa, essa única varredura já deve revelar os 3 limiares de
  /// velocidade (e onde ela para de andar, nas pontas). É o teste mais
  /// barato e o primeiro a rodar.
  Future<void> runDiagonalSweep({int step = 10, Duration dwell = const Duration(seconds: 5)}) {
    final points = <({int att, int med, String label})>[];
    for (var diff = -100; diff <= 100; diff += step) {
      final att = (50 + diff / 2).round().clamp(0, 100);
      final med = (50 - diff / 2).round().clamp(0, 100);
      points.add((
        att: att,
        med: med,
        label: "diagonal diff=$diff → atenção=$att meditação=$med (soma=${att + med})",
      ));
    }
    return _runSweepPoints(points, dwell: dwell);
  }

  /// H2 vs H3 — mantém a diferença fixa (padrão: 27, igual ao V2 que já
  /// funcionou) e varia só a SOMA (70/100/130). Se ela andar na velocidade 2
  /// nas 3 somas, a soma não importa (H2). Se só andar perto de soma=100,
  /// a soma é um gate de verdade (H3).
  Future<void> runSumInvarianceCheck({
    int diff = 27,
    List<int> sums = const [70, 100, 130],
    Duration dwell = const Duration(seconds: 5),
  }) {
    final points = sums.map((sum) {
      final att = ((sum + diff) / 2).round().clamp(0, 100);
      final med = ((sum - diff) / 2).round().clamp(0, 100);
      return (
        att: att,
        med: med,
        label: "soma=$sum diff=$diff → atenção=$att meditação=$med",
      );
    }).toList();
    return _runSweepPoints(points, dwell: dwell);
  }

  /// H1 — mantém a meditação FIXA (padrão: 37, valor do V2) e varre só a
  /// atenção de 0 a 100. Se existir um limiar de atenção isolado (sem
  /// depender da meditação), aparece aqui.
  Future<void> runAttentionSweep({
    int fixedMed = 37,
    int step = 10,
    Duration dwell = const Duration(seconds: 5),
  }) {
    final points = <({int att, int med, String label})>[];
    for (var att = 0; att <= 100; att += step) {
      points.add((
        att: att,
        med: fixedMed,
        label: "atenção=$att (meditação fixa=$fixedMed)",
      ));
    }
    return _runSweepPoints(points, dwell: dwell);
  }

  /// H1 — o espelho do teste acima: atenção FIXA (padrão: 64, valor do V2),
  /// varre a meditação de 0 a 100.
  Future<void> runMeditationSweep({
    int fixedAtt = 64,
    int step = 10,
    Duration dwell = const Duration(seconds: 5),
  }) {
    final points = <({int att, int med, String label})>[];
    for (var med = 0; med <= 100; med += step) {
      points.add((
        att: fixedAtt,
        med: med,
        label: "meditação=$med (atenção fixa=$fixedAtt)",
      ));
    }
    return _runSweepPoints(points, dwell: dwell);
  }

  /// Teste de estagnação: manda um valor 100% ESTÁTICO (ignora jitter de
  /// propósito) num combo que já se sabe que funciona (padrão: V2) e fica
  /// remandando os MESMOS bytes até você apertar "Parar" — cronometra
  /// quanto tempo ela aguenta antes de considerar o dado "parado" e desistir
  /// (achado do usuário). Esse número calibra o quão rápido o jitter/o
  /// modo de edição ao vivo precisam variar pra sustentar uma caminhada.
  DateTime? staleTestStartedAt;

  Future<void> runStaleDataTest({int att = 64, int med = 37}) async {
    if (sweepRunning) return;
    sweepRunning = true;
    _sweepCancelled = false;
    staleTestStartedAt = DateTime.now();
    sweepStatus = "Teste de estagnação: atenção=$att meditação=$med (SEM jitter)";
    _log(
      "🧭 TESTE DE ESTAGNAÇÃO iniciado: atenção=$att meditação=$med, "
      "100% estático. Cronometre até ELA parar de andar e só então aperte "
      "'Parar varredura' — o tempo decorrido fica registrado no log.",
    );
    notifyListeners();

    final bytes = buildBrainWaveFrame(attention: att, meditation: med);
    while (!_sweepCancelled) {
      await relay(bytes); // sempre os MESMOS bytes, byte a byte, de propósito
      await Future.delayed(const Duration(milliseconds: 400));
    }

    final elapsed = DateTime.now().difference(staleTestStartedAt!);
    _log(
      "🧭 Teste de estagnação encerrado após ${elapsed.inSeconds}s de envio "
      "— anote separadamente em quantos segundos ELA parou de andar (não "
      "precisa ser o mesmo instante em que você apertou parar).",
    );
    staleTestStartedAt = null;
    sweepRunning = false;
    sweepStatus = null;
    notifyListeners();
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
    _sweepCancelled = true;
    _mockStreamTimer?.cancel();
    _mockRawStreamTimer?.cancel();
    if (isSdkConnected) disconnectSdk();
    _eventSubscription?.cancel();
    super.dispose();
  }
}
