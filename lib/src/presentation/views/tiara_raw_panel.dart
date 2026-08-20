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
            _amplifyCard(),
            const SizedBox(height: 12),
            _diagonalAssistCard(),
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
  /// Lê a atenção/meditação REAIS e, quando estiverem perto o bastante de
  /// uma das 3 combinações já CONFIRMADAS por observação direta (V1/V2/V3 —
  /// ver docs/FUNCIONAMENTO.md §11), ajusta pro valor exato antes de sair
  /// pra aranha. Sem multiplicador nenhum pra calibrar — só os pontos que já
  /// sabemos que funcionam. Longe de qualquer um deles, a leitura real passa
  /// sem mexer.
  Widget _amplifyCard() {
    return Card(
      color: Colors.purple.shade50,
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
                    "🎯 Assistência automática (recomendado)",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                Switch(
                  value: viewModel.autoAssistEnabled,
                  onChanged: viewModel.toggleAutoAssist,
                  activeThumbColor: Colors.purple,
                ),
              ],
            ),
            const Text(
              "Quando a atenção/meditação REAIS chegarem perto (±15) de uma "
              "das 3 combinações já confirmadas observando a aranha andar "
              "(V1 att=35/med=60, V2 att=64/med=37, V3 att=85/med=20), ajusta "
              "pro valor exato antes de sair pra aranha. Longe de todas as "
              "3, manda a leitura real sem mexer — nunca inventa um valor.",
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            if (viewModel.autoAssistEnabled && !viewModel.relayToSpider)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    "⚠️ Assistência ligada mas 'Retransmitir bytes crus' (card "
                    "acima) está DESLIGADA — nada está saindo pra aranha, "
                    "assistida ou não.",
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            if (viewModel.autoAssistEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  "atenção real=${viewModel.lastAttention ?? '-'}  "
                  "meditação real=${viewModel.lastMeditation ?? '-'}  →  "
                  "${viewModel.debugAssistTarget != null ? "ajustado pra ${viewModel.debugAssistTarget} (${viewModel.debugAssistAttention}/${viewModel.debugAssistMeditation})" : "fora de alcance, passando real"}",
                  style: const TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Modo alternativo, independente da assistência acima — usa só a
  /// atenção real ("foco") e calcula a meditação a mandar (mockada) pela
  /// relação da varredura diagonal (soma atenção+meditação≈100), a que mais
  /// deu resultado nos testes de calibração (docs/FUNCIONAMENTO.md §11.2/
  /// 11.4). A atenção que sai é sempre a real; só a meditação é calculada.
  Widget _diagonalAssistCard() {
    return Card(
      color: Colors.blueGrey.shade50,
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
                    "📐 Assistência diagonal (só foco)",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                Switch(
                  value: viewModel.diagonalAssistEnabled,
                  onChanged: viewModel.toggleDiagonalAssist,
                  activeThumbColor: Colors.indigo,
                ),
              ],
            ),
            const Text(
              "Alternativa à assistência acima — usa só a atenção REAL "
              "(o foco) e calcula a meditação a mandar (mockada) pela "
              "relação atenção+meditação≈100, que foi a que mais deu "
              "resultado na varredura diagonal. A atenção sempre sai real; "
              "só a meditação é calculada. Se ligar as duas assistências "
              "juntas, a de cima (🎯) tem prioridade.",
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            if (viewModel.diagonalAssistEnabled && !viewModel.relayToSpider)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    "⚠️ Assistência diagonal ligada mas 'Retransmitir bytes "
                    "crus' (card acima) está DESLIGADA — nada está saindo "
                    "pra aranha.",
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            if (viewModel.diagonalAssistEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  "atenção real=${viewModel.lastAttention ?? '-'}  →  "
                  "meditação calculada=${viewModel.debugDiagonalMeditation ?? '-'}",
                  style: const TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ),
          ],
        ),
      ),
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
