import 'package:flutter/material.dart';
import '../viewmodels/tiara_raw_viewmodel.dart';

/// Conecta direto na tiara via BLE central (sem SDK oficial) e retransmite
/// os bytes exatamente como chegam pra aranha. Os bytes crus vão só pro
/// console (logcat) — a tela mostra apenas status: conectado, sinal de
/// dados fluindo e eventos de conexão/desconexão.
class TiaraRawPanel extends StatelessWidget {
  final TiaraRawViewModel viewModel;

  const TiaraRawPanel({super.key, required this.viewModel});

  String _fmtTime(DateTime? t) {
    if (t == null) return "—";
    return "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}";
  }

  bool get _dataFlowing =>
      viewModel.lastPacketAt != null &&
      DateTime.now().difference(viewModel.lastPacketAt!) <
          const Duration(seconds: 3);

  @override
  Widget build(BuildContext context) {
    // Altura relativa à tela pro log (em vez de Expanded) — Expanded exige
    // altura limitada do pai, que o SingleChildScrollView não dá (altura
    // vira infinita), então isso é o que evita o overflow ao envolver a
    // tela inteira em scroll.
    final logHeight = MediaQuery.of(context).size.height * 0.4;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            color: viewModel.isConnected ? Colors.green.shade50 : Colors.white,
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: viewModel.isConnected
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.circle,
                                    size: 10,
                                    color: _dataFlowing
                                        ? Colors.green
                                        : Colors.orange,
                                  ),
                                  const SizedBox(width: 6),
                                  const Text(
                                    "Conectado (raw)",
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ),
                              Text(
                                viewModel.device?.remoteId.str ?? '',
                                style: const TextStyle(
                                  fontSize: 14,
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
                          onPressed: viewModel.disconnect,
                          icon: const Icon(Icons.stop),
                          label: const Text("Desconectar"),
                        ),
                      ],
                    )
                  : ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: viewModel.isScanning
                          ? null
                          : viewModel.startScan,
                      icon: viewModel.isScanning
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.bluetooth_searching),
                      label: Text(
                        viewModel.isScanning
                            ? "Buscando..."
                            : "Buscar Tiara (BLE direto)",
                      ),
                    ),
            ),
          ),
          if (!viewModel.isConnected && viewModel.scanResults.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...viewModel.scanResults.map((r) {
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.psychology, color: Colors.blue),
                  title: Text(r.device.advName),
                  subtitle: Text(r.device.remoteId.str),
                  trailing: ElevatedButton(
                    onPressed: () => viewModel.connect(r.device),
                    child: const Text("Conectar"),
                  ),
                ),
              );
            }),
          ],
          if (viewModel.isConnected) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _statCard(
                      "Pacotes",
                      "${viewModel.packetsReceived}",
                      Icons.data_usage,
                    ),
                    _statCard(
                      "Bytes",
                      "${viewModel.bytesReceived}",
                      Icons.storage,
                    ),
                    _statCard(
                      "Última atividade",
                      _fmtTime(viewModel.lastPacketAt),
                      Icons.access_time,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              color: Colors.deepOrange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        "Retransmitir bytes crus direto pra aranha "
                        "(precisa dela conectada na aba Aranha)",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Switch(
                      value: viewModel.relayToSpider,
                      onChanged: viewModel.toggleRelay,
                      activeThumbColor: Colors.deepOrange,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _liveEditCard(),
            const SizedBox(height: 12),
            Card(
              color: Colors.indigo.shade50,
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "🧠 Leitura decodificada (ao vivo, só observação)",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "RAW visto: ${viewModel.rawPacketsSeen} | "
                      "BrainWave visto: ${viewModel.brainWavePacketsSeen}",
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (viewModel.lastBrainWaveAt == null)
                      const Text(
                        "Ainda não chegou nenhum pacote 'BrainWave' completo "
                        "(atenção/meditação) — ele é bem mais raro que a "
                        "onda bruta, aguarde alguns segundos.",
                        style: TextStyle(fontSize: 11, color: Colors.black87),
                      )
                    else
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          _readout("Atenção", viewModel.lastAttention),
                          _readout("Meditação", viewModel.lastMeditation),
                          _readout("Sinal", viewModel.lastSignal),
                          _readout("Bateria", viewModel.lastBattery),
                        ],
                      ),
                    if (viewModel.lastRawSample != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        "Última amostra bruta (onda): ${viewModel.lastRawSample}",
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
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
              child: viewModel.statusLogs.isEmpty
                  ? const Text(
                      "Aguardando eventos de conexão...",
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    )
                  : ListView.builder(
                      itemCount: viewModel.statusLogs.length,
                      itemBuilder: (context, index) {
                        return Text(
                          viewModel.statusLogs[index],
                          style: const TextStyle(
                            color: Colors.greenAccent,
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

  /// Edição AO VIVO do relay real: conecta a tiara de verdade, deixa passar
  /// tudo que ela manda, mas sobrescreve só o(s) campo(s) escolhido(s) antes
  /// de sair pra aranha — preservando o resto do pacote genuíno intacto
  /// (ver tiara_protocol.dart:patchTiaraStream). É a implementação de "leia
  /// o que a tiara envia e edite os valores antes de reenviar".
  Widget _liveEditCard() {
    return Card(
      color: Colors.teal.shade50,
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    "✏️ Edição ao vivo (relay real, com valores trocados)",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                Switch(
                  value: viewModel.editEnabled,
                  onChanged: viewModel.toggleEdit,
                  activeThumbColor: Colors.teal,
                ),
              ],
            ),
            const Text(
              "Com isso ligado, os bytes que SAEM pra aranha não são mais os "
              "originais — só o(s) campo(s) marcado(s) abaixo são "
              "sobrescritos (com checksum recalculado); o resto do pacote "
              "real (sinal, bandas não mexidas, bateria etc.) sai igual ao "
              "que a tiara mandou. O valor forçado sai com um jitter "
              "automático (±4) a cada pacote — segurar um número 100% "
              "estático faz a aranha considerar o dado 'parado' e desistir "
              "de andar (achado confirmado no teste de estagnação da aba "
              "Aranha).",
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            _forceRow(
              label: "Forçar atenção",
              value: viewModel.forceAttention,
              onToggle: (on) =>
                  viewModel.setForceAttention(on ? 100 : null),
              onChanged: (v) => viewModel.setForceAttention(v.round()),
              max: 100,
            ),
            _forceRow(
              label: "Forçar meditação",
              value: viewModel.forceMeditation,
              onToggle: (on) =>
                  viewModel.setForceMeditation(on ? 100 : null),
              onChanged: (v) => viewModel.setForceMeditation(v.round()),
              max: 100,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Switch(
                  value: viewModel.rawGain != null,
                  onChanged: (on) => viewModel.setRawGain(on ? 3.0 : null),
                  activeThumbColor: Colors.teal,
                ),
                Expanded(
                  child: Text(
                    viewModel.rawGain != null
                        ? "Amplificar onda RAW: ×${viewModel.rawGain!.toStringAsFixed(1)}"
                        : "Amplificar onda RAW (desligado)",
                  ),
                ),
              ],
            ),
            if (viewModel.rawGain != null)
              Slider(
                value: viewModel.rawGain!,
                min: 1,
                max: 10,
                divisions: 18,
                label: "×${viewModel.rawGain!.toStringAsFixed(1)}",
                onChanged: viewModel.setRawGain,
              ),
            const Text(
              "'Amplificar' aqui multiplica o VALOR numérico que a tiara "
              "manda pra dizer a força da onda captada — não é potência de "
              "rádio/Bluetooth, não muda alcance nem velocidade da conexão. "
              "É só deixar o número maior antes da aranha ler.",
              style: TextStyle(fontSize: 11, color: Colors.black45),
            ),
          ],
        ),
      ),
    );
  }

  Widget _forceRow({
    required String label,
    required int? value,
    required ValueChanged<bool> onToggle,
    required ValueChanged<double> onChanged,
    required double max,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Switch(
              value: value != null,
              onChanged: onToggle,
              activeThumbColor: Colors.teal,
            ),
            Expanded(
              child: Text(
                value != null ? "$label: $value" : "$label (desligado)",
              ),
            ),
          ],
        ),
        if (value != null)
          Slider(
            value: value.toDouble(),
            min: 0,
            max: max,
            divisions: max.round(),
            label: "$value",
            onChanged: onChanged,
          ),
      ],
    );
  }

  Widget _readout(String label, int? value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
        ),
        Text(
          value?.toString() ?? "—",
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ],
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
