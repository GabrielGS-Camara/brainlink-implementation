import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/models/brain_data.dart';

class BrainLinkRepository {
  // Canal para enviar comandos pontuais (ex: Conectar)
  final MethodChannel _methodChannel = const MethodChannel('brainlink_channel');

  // Canal para receber um fluxo contínuo de dados (ex: Ondas cerebrais)
  final EventChannel _eventChannel = const EventChannel(
    'brainlink_data_channel',
  );

  Future<bool> iniciarConexao() async {
    try {
      final result = await _methodChannel.invokeMethod<String>(
        'iniciarConexao',
      );
      debugPrint(result); // Ex: "Comando recebido no Android!"
      return true; // Sucesso teórico
    } on PlatformException catch (e) {
      debugPrint("Erro ao conectar: ${e.message}");
      return false;
    }
  }

  // Retorna um Stream escutando as mudanças do cérebro em tempo real
  Stream<BrainData> escutarDadosCerebrais() {
    return _eventChannel.receiveBroadcastStream().map((event) {
      final map = event as Map<dynamic, dynamic>;
      return BrainData.fromMap(map);
    });
  }
}
