import 'package:flutter/material.dart';
import '../viewmodels/spider_classic_viewmodel.dart';
import '../viewmodels/tiara_raw_viewmodel.dart';

class SpiderClassicPanel extends StatelessWidget {
  final SpiderClassicViewModel viewModel;
  final TiaraRawViewModel? tiaraRawViewModel;

  const SpiderClassicPanel({
    super.key,
    required this.viewModel,
    this.tiaraRawViewModel,
  });

  String _fmtTime(DateTime? t) {
    if (t == null) return "—";
    return "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}";
  }

  bool get _heartbeatAlive =>
      viewModel.lastFrameAt != null &&
      DateTime.now().difference(viewModel.lastFrameAt!) <
          const Duration(seconds: 3);

  @override
  Widget build(BuildContext context) {
    final logHeight = MediaQuery.of(context).size.height * 0.4;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Dois canais RFCOMM independentes, ambos expostos aqui:
          //   - "RAW" (connect/sendHex): tenta o UUID CUSTOMIZADO (canal 1,
          //     "decafade...") primeiro — nossa aposta principal de canal de
          //     controle real, ver docs/FUNCIONAMENTO.md §3.2.
          //   - "SDK" (connectSdk/sendSdkHex, BluetoothChatService oficial):
          //     UUID fixo internamente no SPP padrão → sempre cai no canal 2
          //     genérico. Até agora só esse canal tinha botão na UI — o
          //     canal 1 nunca chegou a ser testado com payload nenhum.
          if (viewModel.isConnected)
            _connectionStatusCard(
              label: "Conectado (RAW / canal 1 customizado)",
              deviceLabel:
                  "${viewModel.connectedName ?? 'Dispositivo'} (${viewModel.connectedMac})",
              alive: _heartbeatAlive,
              onDisconnect: viewModel.disconnect,
            ),
          if (viewModel.isSdkConnected) ...[
            if (viewModel.isConnected) const SizedBox(height: 8),
            _connectionStatusCard(
              label: "Conectado (SDK / canal 2 genérico)",
              deviceLabel:
                  "${viewModel.sdkConnectedName ?? 'Dispositivo'} (${viewModel.sdkConnectedMac})",
              alive: null,
              onDisconnect: viewModel.disconnectSdk,
            ),
          ],
          if (!viewModel.isConnected && !viewModel.isSdkConnected)
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: viewModel.isDiscovering
                          ? viewModel.stopDiscovery
                          : viewModel.startDiscovery,
                      icon: viewModel.isDiscovering
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.search),
                      label: Text(
                        viewModel.isDiscovering
                            ? "Buscando (toque p/ parar)..."
                            : "Buscar Aranha",
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: viewModel.listBonded,
                      icon: const Icon(Icons.link),
                      label: const Text("Ver Dispositivos Já Pareados"),
                    ),
                  ],
                ),
              ),
            ),
          if (!viewModel.isConnected &&
              !viewModel.isSdkConnected &&
              viewModel.bondedDevices.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Já Pareados",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 4),
            ...viewModel.bondedDevices.entries.map((entry) {
              final mac = entry.key;
              final name = entry.value['name'] as String? ?? "N/A";
              return _deviceCard(
                icon: Icons.link,
                iconColor: Colors.indigo,
                cardColor: Colors.indigo.shade50,
                name: name,
                subtitle: "MAC: $mac",
                onConnectRaw: () => viewModel.connect(mac),
                onConnectSdk: () => viewModel.connectSdk(mac),
              );
            }),
          ],
          if (!viewModel.isConnected &&
              !viewModel.isSdkConnected &&
              viewModel.foundDevices.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...viewModel.foundDevices.entries.map((entry) {
              final mac = entry.key;
              final name = entry.value['name'] as String? ?? "N/A";
              final rssi = entry.value['rssi'];
              return _deviceCard(
                icon: Icons.bluetooth,
                iconColor: Colors.blue,
                cardColor: null,
                name: name,
                subtitle: "MAC: $mac | RSSI: $rssi dBm",
                onConnectRaw: () => viewModel.connect(mac),
                onConnectSdk: () => viewModel.connectSdk(mac),
              );
            }),
          ],
          if (viewModel.isSdkConnected || viewModel.isConnected) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _statCard(
                      "Frames recebidos",
                      "${viewModel.framesReceived}",
                      Icons.data_usage,
                    ),
                    _statCard(
                      "Último heartbeat",
                      _fmtTime(viewModel.lastFrameAt),
                      Icons.favorite,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              color: Colors.purple.shade50,
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "🕷️ Marcar Movimento (observação manual)",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      "Toque no botão correspondente assim que ver a aranha "
                      "andar (e em qual velocidade) ou parar — fica marcado "
                      "no log com timestamp, pra cruzar depois com os bytes "
                      "crus da tiara (console) e achar o valor que controla "
                      "o movimento.",
                      style: TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade200,
                          ),
                          onPressed: () => viewModel.markMoving(
                            1,
                            tiaraFrame: tiaraRawViewModel
                                ?.describeCurrentFrame(),
                          ),
                          icon: const Icon(Icons.directions_walk),
                          label: const Text("Andando — Vel. 1"),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange.shade200,
                          ),
                          onPressed: () => viewModel.markMoving(
                            2,
                            tiaraFrame: tiaraRawViewModel
                                ?.describeCurrentFrame(),
                          ),
                          icon: const Icon(Icons.directions_run),
                          label: const Text("Andando — Vel. 2"),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade200,
                          ),
                          onPressed: () => viewModel.markMoving(
                            3,
                            tiaraFrame: tiaraRawViewModel
                                ?.describeCurrentFrame(),
                          ),
                          icon: const Icon(Icons.bolt),
                          label: const Text("Andando — Vel. 3"),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey.shade300,
                          ),
                          onPressed: () => viewModel.markStopped(
                            tiaraFrame: tiaraRawViewModel
                                ?.describeCurrentFrame(),
                          ),
                          icon: const Icon(Icons.stop_circle),
                          label: const Text("Parou"),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _sweepCard(),
            const SizedBox(height: 12),
            _mockInjectorCard(),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Status da Conexão",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              TextButton(
                onPressed: viewModel.clearLogs,
                child: const Text("Limpar"),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: logHeight,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: viewModel.commandLogs.isEmpty
                  ? const Text(
                      "Aguardando eventos de conexão...",
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    )
                  : ListView.builder(
                      itemCount: viewModel.commandLogs.length,
                      itemBuilder: (context, index) {
                        final line = viewModel.commandLogs[index];
                        final isMovement = line.contains("🕷️");
                        return Text(
                          line,
                          style: TextStyle(
                            color: isMovement
                                ? Colors.purpleAccent
                                : Colors.greenAccent,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Varredura automática pra descobrir o cálculo exato (atenção×meditação)
  /// que a aranha usa — ver o raciocínio completo no viewmodel e em
  /// docs/FUNCIONAMENTO.md §11. Roda uma sequência de pontos sozinha; o
  /// operador só observa a aranha e usa os botões de "Marcar Movimento"
  /// (card acima) pra registrar o que aconteceu em cada ponto.
  Widget _sweepCard() {
    return Card(
      color: Colors.cyan.shade50,
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "🔬 Varredura automática de limiares",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 4),
            const Text(
              "3 pontos manuais já sugerem um padrão: atenção+meditação "
              "fica sempre perto de 100 (V1: 35+60=95, V2: 64+37=101, V3: "
              ">80+<30≈100-110) — a DIFERENÇA (atenção-meditação) parece "
              "escolher a velocidade dentro disso. As varreduras abaixo "
              "testam essa hipótese e as alternativas (limiares "
              "independentes, ou só a diferença sem depender da soma).",
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 10),
            if (viewModel.sweepRunning) ...[
              LinearProgressIndicator(
                value: viewModel.sweepPointTotal > 0
                    ? viewModel.sweepPointIndex / viewModel.sweepPointTotal
                    : null,
              ),
              const SizedBox(height: 6),
              Text(
                viewModel.sweepStatus ?? "Rodando...",
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade100,
                  foregroundColor: Colors.red,
                ),
                onPressed: viewModel.stopSweep,
                icon: const Icon(Icons.stop),
                label: const Text("Parar varredura"),
              ),
            ] else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => viewModel.runDiagonalSweep(),
                    icon: const Icon(Icons.timeline),
                    label: const Text(
                      "1. Diagonal (soma≈100, varia diferença)",
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => viewModel.runSumInvarianceCheck(),
                    icon: const Icon(Icons.compare_arrows),
                    label: const Text("2. A soma importa? (diff=27 fixo)"),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => viewModel.runAttentionSweep(),
                    icon: const Icon(Icons.trending_up),
                    label: const Text("3. Só atenção (meditação=37 fixa)"),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => viewModel.runMeditationSweep(),
                    icon: const Icon(Icons.trending_down),
                    label: const Text("4. Só meditação (atenção=64 fixa)"),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => viewModel.runStaleDataTest(),
                    icon: const Icon(Icons.timer),
                    label: const Text(
                      "5. Teste de estagnação (dado 100% parado)",
                    ),
                  ),
                ],
              ),
            const Divider(height: 20),
            Row(
              children: [
                Switch(
                  value: viewModel.jitterEnabled,
                  onChanged: viewModel.setJitterEnabled,
                  activeThumbColor: Colors.cyan.shade800,
                ),
                Expanded(
                  child: Text(
                    "Jitter (± ${viewModel.jitterAmount}) em todo valor "
                    "'segurado' — sem isso o dado fica 100% estático e ela "
                    "para de andar depois de um tempo (achado do teste 5).",
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            if (viewModel.jitterEnabled)
              Slider(
                value: viewModel.jitterAmount.toDouble(),
                min: 1,
                max: 15,
                divisions: 14,
                label: "±${viewModel.jitterAmount}",
                onChanged: (v) => viewModel.setJitterAmount(v.round()),
              ),
          ],
        ),
      ),
    );
  }

  /// Card de status pra UM canal já conectado (RAW ou SDK) — os dois podem
  /// estar ativos ao mesmo tempo, em MACs diferentes ou até no mesmo.
  Widget _connectionStatusCard({
    required String label,
    required String deviceLabel,
    required bool? alive,
    required VoidCallback onDisconnect,
  }) {
    return Card(
      color: Colors.green.shade50,
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (alive != null) ...[
                        Icon(
                          Icons.circle,
                          size: 10,
                          color: alive ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(label, style: const TextStyle(color: Colors.grey)),
                    ],
                  ),
                  Text(
                    deviceLabel,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                ],
              ),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade100,
                foregroundColor: Colors.red,
              ),
              onPressed: onDisconnect,
              icon: const Icon(Icons.stop),
              label: const Text("Desconectar"),
            ),
          ],
        ),
      ),
    );
  }

  /// Injetor de pacotes sintéticos — manda pacotes construídos à mão direto
  /// pra aranha, SEM a tiara conectada, pra descobrir por tentativa e erro
  /// qual campo dispara o movimento (ver tiara_protocol.dart e
  /// docs/FUNCIONAMENTO.md). Os pacotes respeitam o framing real
  /// (sync/checksum/trailer) em vez de bytes soltos aleatórios.
  Widget _mockInjectorCard() {
    return Card(
      color: Colors.amber.shade50,
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "🧪 Injetor de Pacotes (mock, sem tiara)",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 4),
            const Text(
              "Manda pacotes sintéticos direto pra aranha, no formato real "
              "do protocolo (framing + checksum), pra testar qual campo "
              "dispara o movimento — sem precisar da tiara conectada.",
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 10),
            Text(
              "Atenção sintética: ${viewModel.mockAttentionValue}",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Slider(
              value: viewModel.mockAttentionValue.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: "${viewModel.mockAttentionValue}",
              onChanged: (v) => viewModel.setMockAttention(v.round()),
            ),
            Text(
              "Meditação sintética: ${viewModel.mockMeditationValue}",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Slider(
              value: viewModel.mockMeditationValue.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: "${viewModel.mockMeditationValue}",
              onChanged: (v) => viewModel.setMockMeditation(v.round()),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: viewModel.sendMockBrainWave,
                  icon: const Icon(Icons.send),
                  label: const Text("Enviar 1 pacote"),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Stream contínuo (2/s)"),
                    Switch(
                      value: viewModel.mockStreaming,
                      onChanged: viewModel.toggleMockStream,
                      activeThumbColor: Colors.amber.shade800,
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 20),
            const Text(
              "Presets de banda EEG (alpha/beta) — testa se o gatilho é "
              "derivado das bandas em vez do byte de atenção já pronto",
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: () => viewModel.sendMockBandPreset(foco: true),
                  icon: const Icon(Icons.center_focus_strong),
                  label: const Text("Preset 'Foco' (beta↑ alpha↓)"),
                ),
                ElevatedButton.icon(
                  onPressed: () => viewModel.sendMockBandPreset(foco: false),
                  icon: const Icon(Icons.self_improvement),
                  label: const Text("Preset 'Relaxado' (alpha↑ beta↓)"),
                ),
              ],
            ),
            const Divider(height: 20),
            Text(
              "Amplitude da onda RAW sintética: ±${viewModel.mockRawAmplitude}",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text(
              "É o VALOR numérico dentro do pacote (a 'força' da onda que a "
              "tiara diz ter captado) — não é potência de rádio Bluetooth, "
              "não muda alcance nem a distância de conexão com a aranha. "
              "Só deixa esse número maior ou menor pra testar se ela reage "
              "a picos grandes de onda bruta.",
              style: TextStyle(fontSize: 11, color: Colors.black45),
            ),
            Slider(
              value: viewModel.mockRawAmplitude.toDouble(),
              min: 100,
              max: 8000,
              divisions: 79,
              label: "±${viewModel.mockRawAmplitude}",
              onChanged: (v) => viewModel.setMockRawAmplitude(v.round()),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => viewModel.sendMockRawBurst(),
                  icon: const Icon(Icons.graphic_eq),
                  label: const Text("1 rajada RAW (30 amostras)"),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Stream RAW contínuo (5/s)"),
                    Switch(
                      value: viewModel.mockRawStreaming,
                      onChanged: viewModel.toggleMockRawStream,
                      activeThumbColor: Colors.deepOrange,
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 20),
            const Text(
              "Reenviar um bloco REAL já capturado da tiara (sem edição "
              "nenhuma) — mesmo que não tenha atenção alta, é tráfego "
              "genuíno (framing/checksum reais), então serve como teste de "
              "validação extra além dos pacotes sintéticos acima.",
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: (tiaraRawViewModel?.rawByteHistory.isEmpty ?? true)
                  ? null
                  : () => viewModel.replayBytes(
                      List<int>.from(tiaraRawViewModel!.rawByteHistory),
                    ),
              icon: const Icon(Icons.replay),
              label: Text(
                "Reenviar histórico real capturado "
                "(${tiaraRawViewModel?.rawByteHistory.length ?? 0} bytes)",
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Card de dispositivo com o botão de conexão (via SDK) numa Row própria
  /// em largura total, em vez de espremido no `trailing` de um ListTile —
  /// ListTile tem altura padrão fixa (56-72dp) e não cresce bem pra caber
  /// botões maiores. Aqui o Card cresce livremente com o conteúdo.
  Widget _deviceCard({
    required IconData icon,
    required Color iconColor,
    required Color? cardColor,
    required String name,
    required String subtitle,
    required VoidCallback onConnectRaw,
    required VoidCallback onConnectSdk,
  }) {
    return Card(
      color: cardColor,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple.shade100,
                    ),
                    onPressed: onConnectRaw,
                    child: const Text(
                      "Conectar (RAW / canal 1)",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onConnectSdk,
                    child: const Text(
                      "Conectar (SDK / canal 2)",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 18, color: Colors.grey.shade600),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
        ),
      ],
    );
  }
}
