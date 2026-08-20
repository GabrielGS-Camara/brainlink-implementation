/// Utilitários de protocolo da tiara — layout de bytes reconstruído a partir
/// da DESCOMPILAÇÃO de `com.boby.bluetoothconnect.parSer.ParserBle`
/// (`MacrotellectLink_V1.4.3.jar`, tag interna "parser_4.0"), a classe que o
/// próprio SDK usa para decodificar o stream BLE bruto da tiara — a mesma
/// característica (`6e400003`) que `TiaraRawViewModel` captura. Os offsets
/// abaixo batem byte a byte com capturas reais do app (checksum incluso).
/// Ver docs/FUNCIONAMENTO.md para o levantamento completo.
///
/// Framing confirmado:
///   `AA AA` `PLEN` `payload...` `checksum` `23 23`
///
/// Três assinaturas de payload conhecidas (primeiros bytes do payload, logo
/// após o "AA AA"):
///   `04 80 02 HI LO`         → amostra de onda bruta (RAW), 16 bits
///                              assinado, big-endian. Isso é ~100% do que
///                              aparece numa captura curta — a tiara manda
///                              onda bruta continuamente, em alta taxa.
///   `20 02` + 36 bytes       → bloco "BrainWave" completo (mais raro/lento:
///                              só aparece de tempos em tempos, intercalado
///                              com as amostras RAW). Contém sinal, 8 bandas
///                              de EEG, atenção, meditação, "ap" e bateria.
///   `08 60 06` + 6 bytes     → giroscópio (Gravity X/Y/Z, 16 bits cada).
///
/// Offsets DENTRO do bloco de 36 bytes que segue "20 02" (índice 0 = byte
/// logo após o "02"), extraídos diretamente do bytecode de
/// `ParserBle.parseBytes` (não é suposição — são os índices literais lidos
/// pelo SDK antes de montar o `BrainWave`):
///   [0]       signal        (qualidade do sinal; 0 = ótimo)
///   [3..5]    delta         (24 bits, big-endian, sem sinal)
///   [6..8]    theta
///   [9..11]   lowAlpha
///   [12..14]  highAlpha
///   [15..17]  lowBeta
///   [18..20]  highBeta
///   [21..23]  lowGamma
///   [24..26]  middleGamma
///   [28]      attention (0-100)      ← candidato principal a gatilho
///   [30]      meditation (0-100)     ← candidato secundário
///   [33]      ap
///   [35]      batteryCapacity
/// (índices 1,2,27,29,31,32,34 não são lidos pelo parser oficial — prováveis
/// marcadores de código do protocolo clássico ThinkGear-like, tratados aqui
/// como padding cosmético.)
library;

int _checksum(List<int> payload) {
  final sum = payload.fold<int>(0, (a, b) => a + b) & 0xFF;
  return (~sum) & 0xFF;
}

/// Um frame decodificado do stream bruto da tiara.
class DecodedTiaraFrame {
  final String kind; // 'raw' | 'brainwave' | 'gravity' | 'unknown'
  final Map<String, num> fields;
  final String hex;
  DecodedTiaraFrame(this.kind, this.fields, this.hex);
}

int _u16signed(int hi, int lo) {
  final v = ((hi & 0xFF) << 8) | (lo & 0xFF);
  return v > 32768 ? v - 65536 : v;
}

int _u24(int b0, int b1, int b2) =>
    ((b0 & 0xFF) << 16 | (b1 & 0xFF) << 8 | (b2 & 0xFF)) & 0xFFFFFF;

String _hex(List<int> bytes) => bytes
    .map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

/// Decodificador incremental do stream bruto — espelha a lógica de
/// `ParserBle.parseBytes` (que opera sobre a representação hex-string do
/// stream e quebra frames no delimitador literal "23 23 AA AA"), só que
/// trabalhando direto em bytes em vez de strings. Mantém um buffer interno
/// porque um pacote BLE pode trazer vários frames de uma vez (como no print
/// do usuário, 505 bytes = ~50 frames) ou um frame partido entre duas
/// notificações.
class TiaraFrameDecoder {
  final List<int> _buffer = [];

  List<DecodedTiaraFrame> feed(List<int> bytes) {
    _buffer.addAll(bytes);
    final out = <DecodedTiaraFrame>[];

    while (true) {
      final syncAt = _findSync(_buffer);
      if (syncAt == -1) {
        // Sem "AA AA" no buffer — descarta lixo, preservando só o último
        // byte (pode ser a primeira metade de um "AA AA" futuro).
        if (_buffer.length > 1) {
          _buffer.removeRange(0, _buffer.length - 1);
        }
        break;
      }
      if (syncAt > 0) _buffer.removeRange(0, syncAt);

      const bodyStart = 2; // depois do "AA AA"
      final delimAt = _findDelim(_buffer, bodyStart);
      if (delimAt == -1) break; // frame incompleto, aguarda mais bytes

      final frameBytes = _buffer.sublist(bodyStart, delimAt);
      out.add(_classify(frameBytes));
      _buffer.removeRange(0, delimAt + 2); // consome até o fim do "23 23"
    }

    if (_buffer.length > 4096) {
      _buffer.removeRange(0, _buffer.length - 4096);
    }
    return out;
  }

  int _findSync(List<int> b) {
    for (var i = 0; i < b.length - 1; i++) {
      if (b[i] == 0xAA && b[i + 1] == 0xAA) return i;
    }
    return -1;
  }

  int _findDelim(List<int> b, int from) {
    for (var i = from; i < b.length - 1; i++) {
      if (b[i] == 0x23 && b[i + 1] == 0x23) return i;
    }
    return -1;
  }

  DecodedTiaraFrame _classify(List<int> f) {
    final hex = _hex(f);
    // f = <PLEN> <payload...> <checksum> (sem o "AA AA" nem o "23 23")
    if (f.length >= 5 && f[1] == 0x80 && f[2] == 0x02) {
      return DecodedTiaraFrame('raw', {'value': _u16signed(f[3], f[4])}, hex);
    }
    if (f.length >= 38 && f[0] == 0x20 && f[1] == 0x02) {
      final b = f.sublist(2); // os 36 bytes de dados
      return DecodedTiaraFrame('brainwave', {
        'signal': b[0],
        'delta': _u24(b[3], b[4], b[5]),
        'theta': _u24(b[6], b[7], b[8]),
        'lowAlpha': _u24(b[9], b[10], b[11]),
        'highAlpha': _u24(b[12], b[13], b[14]),
        'lowBeta': _u24(b[15], b[16], b[17]),
        'highBeta': _u24(b[18], b[19], b[20]),
        'lowGamma': _u24(b[21], b[22], b[23]),
        'middleGamma': _u24(b[24], b[25], b[26]),
        'attention': b[28],
        'meditation': b[30],
        'ap': b[33],
        'battery': b[35],
      }, hex);
    }
    if (f.length >= 9 && f[0] == 0x08 && f[1] == 0x60 && f[2] == 0x06) {
      final b = f.sublist(3);
      return DecodedTiaraFrame('gravity', {
        'x': _u16signed(b[0], b[1]),
        'y': _u16signed(b[2], b[3]),
        'z': _u16signed(b[4], b[5]),
      }, hex);
    }
    return DecodedTiaraFrame('unknown', {}, hex);
  }
}

/// Edita EM CIMA de um trecho real de bytes da tiara — não reconstrói pacote
/// nenhum do zero, só sobrescreve o(s) byte(s) de valor conhecido (atenção,
/// meditação, amplitude da onda RAW) nos frames que reconhece e recalcula o
/// checksum deles, preservando TODO o resto exatamente como a tiara mandou
/// (inclusive campos que não entendemos — signal, "ap", bateria, bandas não
/// mexidas, marcadores cosméticos). Frames que não batem no formato exato
/// esperado (comprimento diferente do confirmado) são deixados 100% intactos
/// — nunca arrisca corromper algo que não reconhece com certeza.
///
/// Passa despercebido por qualquer coisa que não seja um frame `AA AA
/// ... 23 23` reconhecido — sobras/lixo do começo/fim do chunk (frame
/// cortado na borda de uma notificação BLE) saem exatamente como entraram.
List<int> patchTiaraStream(
  List<int> input, {
  int? forceAttention,
  int? forceMeditation,
  double? rawGain,
}) {
  if (forceAttention == null && forceMeditation == null && rawGain == null) {
    return input; // nada pra editar, devolve sem tocar em nada
  }
  final out = List<int>.from(input);
  var i = 0;
  while (i < out.length - 1) {
    if (out[i] != 0xAA || out[i + 1] != 0xAA) {
      i++;
      continue;
    }
    final bodyStart = i + 2;
    var j = bodyStart;
    while (j < out.length - 1 && !(out[j] == 0x23 && out[j + 1] == 0x23)) {
      j++;
    }
    if (j >= out.length - 1) break; // frame cortado no fim do chunk, para

    final frame = out.sublist(bodyStart, j);
    final patched = _patchFrame(
      frame,
      forceAttention: forceAttention,
      forceMeditation: forceMeditation,
      rawGain: rawGain,
    );
    if (patched != null) {
      out.replaceRange(bodyStart, j, patched);
    }
    i = j + 2;
  }
  return out;
}

/// Tenta editar UM frame já isolado (sem "AA AA"/"23 23"). Devolve `null`
/// quando não reconhece o formato com confiança suficiente pra editar (aí
/// `patchTiaraStream` mantém o frame original, intacto).
List<int>? _patchFrame(
  List<int> f, {
  int? forceAttention,
  int? forceMeditation,
  double? rawGain,
}) {
  // RAW: PLEN(1) + 80 02(2) + HI LO(2) + checksum(1) = 6 bytes exatos.
  if (rawGain != null && f.length == 6 && f[1] == 0x80 && f[2] == 0x02) {
    final value = _u16signed(f[3], f[4]);
    var scaled = (value * rawGain).round();
    if (scaled > 32767) scaled = 32767;
    if (scaled < -32768) scaled = -32768;
    final v = scaled & 0xFFFF;
    final payload = [f[0], f[1], f[2], (v >> 8) & 0xFF, v & 0xFF];
    return [...payload, _checksum(payload)];
  }

  // BrainWave: PLEN(1) + 02(1) + body(>=36) + checksum(1).
  // Bug confirmado em captura real (sessão 20/08, docs/FUNCIONAMENTO.md
  // §11.7): o pacote real vem com 46 bytes, não os 39 que assumíamos (a
  // tiara manda ~7 bytes extras depois da bateria que nunca decodificamos —
  // desconhecidos, mas reais). O check antigo (`f.length == 39`) nunca
  // batia com um pacote de verdade, então o patch nunca disparava: a
  // atenção/meditação real passava sempre intacta, mesmo com a assistência
  // ligada — o "bug grave" relatado era esse silêncio, não uma corrupção.
  // Agora aceita qualquer comprimento >= 38 (igual ao decoder já aceitava)
  // e preserva TODOS os bytes reais, inclusive os desconhecidos do final —
  // só sobrescreve os 2 bytes confirmados (atenção/meditação) e recalcula o
  // checksum sobre o payload completo, do tamanho real que vier.
  if ((forceAttention != null || forceMeditation != null) &&
      f.length >= 38 &&
      f[0] == 0x20 &&
      f[1] == 0x02) {
    final payload = List<int>.from(f.sublist(0, f.length - 1)); // tudo, menos o checksum (último byte)
    if (forceAttention != null) payload[2 + 28] = forceAttention & 0xFF;
    if (forceMeditation != null) payload[2 + 30] = forceMeditation & 0xFF;
    return [...payload, _checksum(payload)];
  }

  return null;
}
