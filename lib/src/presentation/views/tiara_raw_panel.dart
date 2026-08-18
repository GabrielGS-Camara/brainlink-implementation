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
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                      onPressed: viewModel.isScanning ? null : viewModel.startScan,
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
          Expanded(
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

  Widget _statCard(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 18, color: Colors.grey.shade600),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ],
    );
  }
}
