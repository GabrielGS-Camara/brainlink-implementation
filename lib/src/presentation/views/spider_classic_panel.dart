import 'package:flutter/material.dart';
import '../viewmodels/spider_classic_viewmodel.dart';

/// Painel de conexão CLÁSSICA (SPP/RFCOMM) com a aranha, sem passar pelo
/// pareamento do Android — ver SpiderClassicViewModel. Tem também os
/// botões de marcação manual de movimento, usados para cruzar com o log
/// bruto da tiara (console) e descobrir qual valor controla a velocidade.
class SpiderClassicPanel extends StatelessWidget {
  final SpiderClassicViewModel viewModel;

  const SpiderClassicPanel({super.key, required this.viewModel});

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
                                    color: _heartbeatAlive
                                        ? Colors.green
                                        : Colors.orange,
                                  ),
                                  const SizedBox(width: 6),
                                  const Text(
                                    "Conectado (SPP)",
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ),
                              Text(
                                "${viewModel.connectedName ?? 'Dispositivo'} (${viewModel.connectedMac})",
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red.shade100,
                                foregroundColor: Colors.red,
                              ),
                              onPressed: viewModel.disconnect,
                              icon: const Icon(Icons.stop),
                              label: const Text("Desconectar"),
                            ),
                            const SizedBox(height: 6),
                            OutlinedButton.icon(
                              onPressed: viewModel.checkStatus,
                              icon: const Icon(Icons.fact_check, size: 18),
                              label: const Text("Verificar Status"),
                            ),
                          ],
                        ),
                      ],
                    )
                  : Column(
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
                                : "Buscar Dispositivos Clássicos",
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
          if (!viewModel.isConnected && viewModel.bondedDevices.isNotEmpty) ...[
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
              return Card(
                color: Colors.indigo.shade50,
                child: ListTile(
                  leading: const Icon(Icons.link, color: Colors.indigo),
                  title: Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text("MAC: $mac"),
                  trailing: ElevatedButton(
                    onPressed: () => viewModel.connect(mac),
                    child: const Text("Conectar (SPP)"),
                  ),
                ),
              );
            }),
          ],
          if (!viewModel.isConnected && viewModel.foundDevices.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...viewModel.foundDevices.entries.map((entry) {
              final mac = entry.key;
              final name = entry.value['name'] as String? ?? "N/A";
              final rssi = entry.value['rssi'];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.bluetooth, color: Colors.blue),
                  title: Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text("MAC: $mac | RSSI: $rssi dBm"),
                  trailing: ElevatedButton(
                    onPressed: () => viewModel.connect(mac),
                    child: const Text("Conectar (SPP)"),
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
                          onPressed: () => viewModel.markMoving(1),
                          icon: const Icon(Icons.directions_walk),
                          label: const Text("Andando — Vel. 1"),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange.shade200,
                          ),
                          onPressed: () => viewModel.markMoving(2),
                          icon: const Icon(Icons.directions_run),
                          label: const Text("Andando — Vel. 2"),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade200,
                          ),
                          onPressed: () => viewModel.markMoving(3),
                          icon: const Icon(Icons.bolt),
                          label: const Text("Andando — Vel. 3"),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey.shade300,
                          ),
                          onPressed: viewModel.markStopped,
                          icon: const Icon(Icons.stop_circle),
                          label: const Text("Parou"),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
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
          Expanded(
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
