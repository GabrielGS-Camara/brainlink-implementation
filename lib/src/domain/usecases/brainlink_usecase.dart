import '../models/brain_data.dart';
import '../../data/repositories/brainlink_repository.dart';

class ConnectTiaraUseCase {
  final BrainLinkRepository repository;
  ConnectTiaraUseCase(this.repository);

  Future<bool> call() async {
    return await repository.iniciarConexao();
  }
}

class GetBrainDataStreamUseCase {
  final BrainLinkRepository repository;
  GetBrainDataStreamUseCase(this.repository);

  Stream<BrainData> call() {
    return repository.escutarDadosCerebrais();
  }
}
