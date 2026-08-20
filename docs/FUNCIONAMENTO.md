# Funcionamento do App — BrainLink ↔ Tiara ↔ Aranha

> Documento gerado a partir da leitura completa do código-fonte Flutter/Kotlin do
> projeto **e** da descompilação (`javap`) das classes reais dentro de
> `android/app/libs/MacrotellectLink_V1.4.3.jar` — o SDK oficial da Macrotellect
> para a tiara (headset EEG "BrainLink"). Toda afirmação sobre o SDK abaixo foi
> conferida contra o `.jar`; onde o código do app faz uma afirmação que **não**
> bate com o que o `.jar` realmente contém, isso é sinalizado explicitamente
> (seção 5.6).

## 1. Objetivo do projeto

O app conecta em dois dispositivos Bluetooth diferentes ao mesmo tempo:

1. **A tiara** — um headset EEG (eletroencefalograma) da Macrotellect (modelo
   "BrainLink Pro"), que lê ondas cerebrais e as transmite por Bluetooth.
2. **A aranha** — um robô/brinquedo Macrotellect que se movimenta e que,
   presumivelmente, é controlado pelos dados que a tiara emite (esse é o
   produto comercial "BrainLink" + acessório robótico: a ideia de fábrica é
   "mexa o robô com a força da sua concentração").

**O objetivo final do usuário é "ampliar o sinal"** — ou seja, pegar o que a
tiara manda e reforçar/amplificar esse sinal antes (ou no lugar) de repassá-lo
para a aranha, para facilitar o disparo do movimento (presumivelmente porque o
gatilho de movimento da aranha exige um nível de atenção/força de sinal que é
difícil de atingir naturalmente).

**Isso ainda NÃO está implementado.** Hoje o app só faz _relay_ (retransmissão)
bruto, byte a byte, sem tocar em nenhum valor — porque **ainda não se sabe qual
byte, dentro do fluxo de dados da tiara, é o que a aranha realmente lê para
decidir se deve andar ou não.** Grande parte do código existente é, na
verdade, instrumentação de **engenharia reversa**: captura de bytes crus e um
mecanismo manual de correlação (bytes recebidos × movimento observado a olho
nu) para descobrir esse byte antes de qualquer amplificação ser possível.

---

## 2. Arquitetura geral

Projeto Flutter (MVVM) com uma ponte nativa Android em Kotlin que fala
diretamente com as APIs de Bluetooth do Android (BLE e Bluetooth Clássico) e
com o SDK proprietário da Macrotellect.

```
lib/
  main.dart                                  → bootstrap do MaterialApp
  src/
    domain/
      protocol/tiara_protocol.dart           → decoder + montador + editor de pacotes (ver seção 8)
    presentation/
      viewmodels/
        tiara_raw_viewmodel.dart             → canal BLE DIRETO (bypass do SDK) — usado
        spider_classic_viewmodel.dart        → canal SPP/RFCOMM clássico com a ARANHA — usado
      views/
        brainlink_screen.dart                → Scaffold raiz
        dashboard_panel.dart                 → TabBar: aba "Tiara" / aba "Aranha"
        tiara_raw_panel.dart                 → UI da aba Tiara
        spider_classic_panel.dart            → UI da aba Aranha (+ botões de marcação manual)

android/app/src/main/kotlin/.../MainActivity.kt
                                              → toda a lógica nativa: RFCOMM clássico
                                              com a aranha, e o wrapper de baixo nível
                                              do SDK MacrotellectLink (BluetoothChatService)

android/app/libs/MacrotellectLink_V1.4.3.jar → SDK oficial da tiara (fechado, .jar)
```

A tela em uso real (`BrainLinkScreen` → `DashboardPanel`) tem **duas abas**:

- **"Tiara"** → `TiaraRawPanel` / `TiaraRawViewModel`
- **"Aranha"** → `SpiderClassicPanel` / `SpiderClassicViewModel`

> **Nota de limpeza (seção 10.4)**: até uma versão anterior deste projeto
> existiam também `BrainLinkViewModel`/`BrainLinkRepository` (canal oficial
> via `LinkManager` do SDK) e um "emulador de tiara" via GATT Server no
> Kotlin — nenhum dos dois chegou a ser usado por nenhuma tela real. Ambos
> foram **removidos** (não só abandonados) nesta sessão, junto com o código
> nativo (Kotlin) e a permissão Android correspondentes que só existiam pra
> sustentá-los. Ver seção 10.4 para detalhes.

---

## 3. Os "mundos" de conexão implementados

> **Atualizado na seção 10.4**: originalmente o `MainActivity.kt` tinha
> **quatro** mecanismos — um canal oficial via `LinkManager` do SDK e um
> emulador de tiara via GATT Server foram removidos por nunca terem sido
> usados por nenhuma tela real (ver seção 10.4). Sobraram os **dois** que a
> UI de fato usa, descritos abaixo.

### 3.1 Canal BLE direto na tiara, sem o SDK (`TiaraRawViewModel`)

Usa o pacote Flutter `flutter_blue_plus` para conectar **direto** na tiara
como _central_ BLE, ignorando o SDK da Macrotellect por completo. Escuta a
característica de notificação:

- Serviço: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- Característica de notificação: `6e400003-b5a3-f393-e0a9-e50e24dcca9e`

e grava **os bytes exatamente como chegam pelo ar**, sem nenhuma
interpretação — nem tenta decodificar atenção/meditação. Motivo: para achar o
byte-gatilho da aranha é preciso ver o fluxo bruto, e o SDK oficial já
descarta/filtra informação ao decodificar para `BrainWave`.

Tem um `Switch` (`relayToSpider`) que, se ligado, retransmite cada pacote
bruto recebido diretamente para a aranha (seção 3.2) via
`SpiderClassicViewModel.relay()` — que escolhe sozinho qual canal está
conectado (RAW/canal 1 ou SDK/canal 2). Por padrão o relay é **verbatim**
(bytes intactos); a seção 9 adicionou um modo de **edição ao vivo**
(`editEnabled`) que, quando ligado, sobrescreve campos específicos
(atenção/meditação/amplitude da onda) antes de repassar — ver
`tiara_protocol.dart:patchTiaraStream`.

### 3.2 Canal clássico SPP/RFCOMM com a aranha (`SpiderClassicViewModel`)

A aranha **não fala BLE** (comprovado por tentativa e pela ausência de
avanço via GATT) — ela é um acessório Bluetooth **clássico** (SPP/RFCOMM),
do mesmo jeito que a tiara "clássica" mais antiga da Macrotellect. O
`MainActivity.kt` implementa 4 estratégias de conexão, tentadas nesta ordem:

1. **UUID customizado** `00000000-deca-fade-deca-deafdecacaff` — descoberto
   analisando um dump SDP (`btsnoop_hci.log`) real da aranha: ela registra
   dois serviços RFCOMM, ambos chamados `"Spider_robot"`, e o canal 1 usa
   esse UUID proprietário (bytes literais do `ServiceClassIDList`:
   `de ca fa de  de ca de af  de ca ca ff` → "decafade / decadeaf /
   decacaff", claramente um easter egg/UUID inventado pelo firmware da
   aranha). **Aposta principal**: esse é o canal de controle real.
2. **SPP padrão** (`00001101-0000-1000-8000-00805F9B34FB`) — canal 2 da
   aranha, genérico, testado sem efeito observado até agora.
3. **Canais RFCOMM diretos por número** (1 a 5), via reflection
   (`createRfcommSocket(int)`), pulando o SDP inteiramente — fallback para
   stacks SPP baratos com SDP quebrado.
4. **Canal "oficial" via `BluetoothChatService`** — instancia a própria
   classe do SDK Macrotellect (`com.boby.bluetoothconnect.services.
BluetoothChatService`) e chama `connect()`/`write()` nela diretamente,
   sem passar pelo `LinkManager` (removido, seção 10.4). Essa classe tem o
   UUID de conexão **fixo internamente** no UUID padrão de SPP (confirmado
   por decompilação — ver seção 5.5), então só alcança o mesmo canal
   genérico da tentativa 2.

Nenhuma dessas estratégias chama `createBond()`/pareamento do Android — é
proposital: o SDK oficial da Macrotellect também nunca pareia pela tela de
Configurações (comprovado por decompilação de
`BlueManager$ConnectDeviceRunnable`), e a aranha trava em "Pairing..." se
pareada manualmente.

**Atualizado na seção 9**: até uma sessão anterior, `SpiderClassicPanel` só
tinha botão pra tentativa 4 (canal SDK/genérico) — a tentativa 1 (canal 1
customizado, nossa aposta principal) nunca tinha sido testada com payload
nenhum na prática. Isso foi corrigido: cada dispositivo agora tem **dois**
botões de conexão, "RAW / canal 1" (tentativas 1-3 acima) e "SDK / canal 2"
(tentativa 4), e o relay/injetor usa automaticamente qualquer um dos dois
que estiver conectado, priorizando o canal 1.

---

## 4. Fluxo de dados ponta a ponta (o "relay")

```
 TIARA (headset EEG)
   │  BLE notify, característica 6e400003 (serviço 6e400001)
   │  bytes CRUS, sem decodificação
   ▼
 TiaraRawViewModel._onRawBytes()
   │  grava em frameHistory / lastFrameHex
   │  SE relayToSpider == true:
   ▼
 SpiderClassicViewModel.relay(bytes) → sendSdkHex(bytes)
   │  MethodChannel 'spider_classic_channel' → sendSdkHex
   ▼
 MainActivity.sendClassicViaSdk(bytes)
   │  BluetoothChatService.write(bytes)  (canal SPP/RFCOMM já conectado)
   ▼
 ARANHA (robô)
```

**Ponto central:** o relay é **verbatim** — nenhum byte é alterado,
somado, escalado ou filtrado. O app é hoje um "cabo Bluetooth" entre a
tiara e a aranha. "Ampliar o sinal" implicaria interceptar esse fluxo em
algum ponto (provavelmente dentro de `_onRawBytes` antes do `relay`, ou
dentro de `sendClassicBytes`/`sendClassicViaSdk` no Kotlin) e modificar
deliberadamente o(s) byte(s) relevante(s) — mas isso **exige saber qual
posição no pacote, e qual faixa de valores, a aranha realmente usa como
gatilho**, o que é precisamente a incógnita registrada no pedido do
usuário.

---

## 5. O SDK oficial (MacrotellectLink) — o que ele realmente contém

Tudo nesta seção foi extraído com `javap -p -constants` diretamente do
`.class` dentro do `.jar` (pacote `com.boby.bluetoothconnect`), não é
suposição.

### 5.1 `LinkManager` (fachada pública do SDK)

```java
public class com.boby.bluetoothconnect.LinkManager {
  public static final int DATATYPE_DEFAULT = 0;
  public static final int DATATYPE_GYRO    = 1;
  public static final int DATATYPE_GRIND   = 4;
  public static final int DATATYPE_AP      = 8;

  public static LinkManager getInstance();
  public static LinkManager init(Context);
  public void setMultiEEGPowerDataListener(EEGPowerDataListener);
  public void setScanCallBack(ScanCallBack);
  public void startScan();
  public void stopScan();
  public void connectDevice(BlueConnectDevice);
  public void disconnectDevice(BlueConnectDevice);
  public void writeToDevice(String mac, String texto);   // grava texto.getBytes(UTF_8) via BluetoothChatService
  public void setDataType(int);                          // bitmask das constantes DATATYPE_*
  public void setOnConnectListener(OnConnectListener);
  public void close();
  ...
}
```

`DATATYPE_*` são **flags de bitmask** somáveis. O app chama
`setDataType(5)` em `onConnectSuccess` — `5 = DATATYPE_GYRO(1) |
DATATYPE_GRIND(4)` — pedindo ao headset que também envie giroscópio
(`Gravity`) e "grind" (ranger de dentes/força de mordida) além dos dados
padrão de EEG. Isso está documentado corretamente no comentário do Kotlin
("Giroscópio + Grind").

### 5.2 `BrainWave` (bean com os dados já decodificados)

```java
public class BrainWave implements Parcelable {
  public int signal;        // qualidade do sinal (0 = ótimo; valores altos = sinal ruim/eletrodo solto)
  public int att;           // atenção (0-100)
  public int med;           // meditação (0-100)
  public int delta, theta, lowAlpha, highAlpha,
             lowBeta, highBeta, lowGamma, middleGamma; // potências de banda EEG
  public int ap;
  public int batteryCapacity;
  public Double hardwareversion;
  public int grind;         // força de "ranger de dentes" (precisa DATATYPE_GRIND)
  public int heartRate;
  public float temperature;
  public ArrayList<Integer> hrv;
}
```

Todos os campos mapeados em `BrainData.fromMap` (lado Dart) e em
`onBrainWavedata` (lado Kotlin) batem exatamente com esses campos — a
transcrição está correta.

### 5.3 `Parser3` — o protocolo real de bytes da tiara

Esta é a peça mais importante para quem quer identificar o byte-gatilho:
`Parser3` é a máquina de estados que decodifica o fluxo bruto vindo da
tiara em campos de `BrainWave`. As constantes (valores reais, extraídos por
`javap -constants`):

```java
PARSER_SYNC_BYTE            = 170  (0xAA)   // byte de sincronismo, aparece 2x no início de cada pacote
PARSER_EXCODE_BYTE          =  85  (0x55)   // prefixo de "código estendido"
PARSER_HRV_BYTE             = 187  (0xBB)
MULTI_BYTE_CODE_THRESHOLD   = 127  (0x7F)   // códigos >= 0x80 têm payload multi-byte com length explícito

PARSER_CODE_POOR_SIGNAL       =   2  (0x02)
PARSER_CODE_HEARTRATE         =   3  (0x03)
PARSER_CODE_CONFIGURATION     =   4  (0x04)
PARSER_CODE_CONFIGMEDITATION  =   5  (0x05)
PARSER_CODE_PRE               =   6  (0x06)
PARSER_CODE_ELC               =   7  (0x07)
PARSER_CODE_GLIND             =   8  (0x08)   // "grind"
PARSER_CODE_RAW               = 128  (0x80)   // onda bruta (dupla de bytes)
PARSER_CODE_EEG_POWER         = 131  (0x83)   // bloco de potências de banda (delta..gamma)
PARSER_CODE_DEBUG_ONE         = 132  (0x84)
PARSER_CODE_DEBUG_TWO         = 133  (0x85)
```

Isso é, byte a byte, o **mesmo formato de framing usado pelo protocolo
"ThinkGear"/TGAM da NeuroSky** (SYNC SYNC · PLENGTH · PAYLOAD... ·
CHECKSUM), que é a base histórica de praticamente todos os headsets EEG de
baixo custo — inclusive o da Macrotellect. Ou seja: **os bytes que chegam
da tiara não são um blob arbitrário; eles seguem uma gramática de pacote
conhecida e documentável.**

Consequência prática direta para a investigação do usuário:

- Um pacote de atenção isolado tende a ter a forma
  `AA AA 04 04 <valor 0-100> <checksum>` (código `0x04` = atenção, sozinho,
  1 byte de payload).
- Um pacote de meditação isolado: `AA AA 04 05 <valor 0-100> <checksum>`.
- Blocos maiores (`0x83`, EEG power) vêm com `PLENGTH` maior e múltiplos
  campos de 3 bytes cada (delta, theta, lowAlpha, highAlpha, lowBeta,
  highBeta, lowGamma, middleGamma, nessa ordem).
- Pacotes `0x02` (poor signal) valem 0 quando o sinal está ótimo — quando
  esse valor não é 0, o headset pode estar suprimindo/zerando os outros
  campos, o que é uma hipótese plausível para "por que a aranha não reage":
  não é falta de amplitude do gesto mental, é o app (ou a própria tiara)
  descartando o pacote por sinal ruim antes mesmo dele chegar ao byte que
  a aranha lê.

> **Atualizado na seção 8**: na época em que este parágrafo foi escrito,
> ainda não sabíamos se os bytes crus capturados via BLE (`6e400003`)
> seguiam o mesmo framing do `Parser3` (usado no caminho clássico/SPP).
> Isso já foi confirmado empiricamente — **não é o `Parser3`, é uma classe
> BLE dedicada** (`ParserBle`), com framing parecido mas não idêntico
> (inclui um trailer `23 23` que o `Parser3` não tem). Ver seção 8 para o
> levantamento completo, offsets exatos e o decodificador ao vivo já
> implementado (`tiara_protocol.dart`).

### 5.4 `EyesUtil` e `DistractedUtill` (utilitários proprietários usados no app)

- `EyesUtil.eyesDate(int raw)` — recebe a onda bruta (`onRawData`) e
  retorna um valor de força de piscada, ou `-1` quando não há piscada
  detectada. É exatamente como `myEegListener.onRawData` usa no
  `MainActivity.kt` (`lastBlinkStrength`).
- `DistractedUtill.add(int attention)` — mantém estado interno (`maximum1`,
  `minimum1`, `lastData`, `isLastUp`) e retorna `boolean` indicando
  distração, alimentado a cada novo valor de `att`. Usado em
  `isDistracted` no payload enviado ao Flutter. A lógica interna é
  proprietária/fechada (não há fórmula documentada publicamente), mas o
  uso no app está correto: um valor por chamada, alimentado
  sequencialmente.

### 5.5 `BluetoothChatService` (canal clássico usado tanto para a tiara quanto, neste projeto, para a aranha)

```java
public class BluetoothChatService {
  private static final String NAME_SECURE   = "BluetoothChatSecure";
  private static final String NAME_INSECURE = "BluetoothChatInsecure";
  private static final UUID MY_UUID_SECURE;
  private static final UUID MY_UUID_INSECURE;
  private static final UUID MY_UUID_NORMAL;

  public synchronized void connect(BluetoothDevice, boolean secure);
  public void write(byte[]);
  public boolean isConnected();
}
```

Os valores literais de `MY_UUID_*` não aparecem como constante de compilação
(são construídos via `UUID.fromString(...)` em bloco estático), mas a
interface `com.boby.bluetoothconnect.classic.Constants` do mesmo `.jar`
expõe:

```java
public interface Constants {
  String STR_UUID = "00001101-0000-1000-8000-00805F9B34FB";  // UUID padrão de SPP
}
```

o que é consistente com o comentário do `MainActivity.kt`: o canal SDK
"oficial" só alcança o UUID padrão de SPP (canal 2 da aranha), nunca o UUID
proprietário `decafade/decadeaf/decacaff` do canal 1.

### 5.6 `UUIDUtils` — ⚠️ discrepância encontrada em relação ao comentário do código

O `MainActivity.kt` (linhas 64–66) afirma:

> `// UUIDs extraídos de UUIDUtils.class dentro do MacrotellectLink_V1_4_3.jar (WRITE_SERVICE_UUID / WRITE_CHAR_UUID)`

**Isso não confere.** A classe real `com.boby.bluetoothconnect.ble.utils.
UUIDUtils` foi descompilada e contém, entre outros,:

```java
WRITE_SERVICE_UUID   = "00001805-0000-1000-8000-00805f9b34fb"
WRITE_CHAR_UUID_2A08 = "00002a08-0000-1000-8000-00805f9b34fb"
WRITE_CHAR_UUID_2A09 = "00002a09-0000-1000-8000-00805f9b34fb"
DEVICE_SERVICE_UUID  = "0000ffe0-0000-1000-8000-00805f9b34fb"
DEVICE_CHAR_UUID     = "0000ffe1-0000-1000-8000-00805f9b34fb"
```

— nenhum desses é `6e400001-b5a3-f393-e0a9-e50e24dcca9e` (o valor
realmente usado no app). Uma busca por essa string/UUID em **todas** as
classes do `.jar` não encontrou nenhuma ocorrência. Ou seja: o UUID
`6e400001/6e400002/6e400003` usado pelo app **não vem do SDK** — é o
**"Nordic UART Service" (NUS)**, um padrão de fato usado por incontáveis
periféricos BLE genéricos (não é exclusivo nem definido pela Macrotellect).
O comentário no código provavelmente descreve, de forma imprecisa, a
origem real: **captura direta via scanner BLE real da tiara** (ex.: nRF
Connect, ou o próprio log de conexão do `TiaraRawViewModel`), não
descompilação do SDK.

Isso não invalida o UUID em si (ele está confirmado por captura real de
conexão, conforme o comentário do `TiaraRawViewModel`), só corrige a
proveniência alegada. É relevante para quem for confiar no código como
"documentação": **os únicos UUIDs realmente confirmados dentro do `.jar`
são os do bloco 5.6 acima e o `STR_UUID` de SPP (0x1101)** — o UUID Nordic
UART é conhecimento externo/empírico, não extraído do SDK.

---

## 6. O que ainda não se sabe (o problema central do usuário)

1. **Qual formato de pacote a aranha realmente espera.** Sabe-se que ela
   fala SPP/RFCOMM clássico (não BLE), com dois canais candidatos
   (`decafade...` e SPP padrão 0x1101). Não se sabe se ela consome o mesmo
   framing `AA AA ...` do protocolo `Parser3`/ThinkGear, ou algum outro
   protocolo próprio de fábrica.
2. **Qual byte (ou campo) dentro do pacote é o gatilho de movimento.**
   Hoje o app faz relay 1:1 dos bytes crus da tiara (BLE) para a aranha
   (SPP) — não há nenhuma lógica que interprete "isso é atenção" ou "isso é
   o byte de comando". Presumir que é o campo de atenção (`0x04`) é
   razoável dado o propósito comercial do brinquedo, mas **não está
   confirmado neste código**.
3. **Se "ampliar o sinal" deve significar amplificar o valor decodificado
   (ex.: multiplicar a atenção reportada) ou reforçar/repetir o sinal de
   rádio bruto.** Como a aranha lê um valor específico dentro de um pacote
   estruturado (não um nível analógico de RF), a interpretação mais
   provável e tecnicamente acionável é a primeira: forjar/escalar o byte
   de valor antes do relay (ex.: se o byte de atenção real for `35`,
   reescrevê-lo para `90` antes de mandar pra aranha) — mas só depois de
   descobrir exatamente qual posição de byte é essa.

### Mecanismo de investigação já implementado no app

Para resolver o item 1–2 acima, o app já tem instrumentação pronta:

- `TiaraRawViewModel.frameHistory` — histórico (até 4000 entradas) de
  todo frame bruto recebido da tiara, com timestamp.
- `TiaraRawViewModel.describeCurrentFrame()` — retorna o último frame
  bruto + idade em ms.
- `SpiderClassicViewModel.markMoving(int velocidade, {tiaraFrame})` e
  `markStopped({tiaraFrame})` — botões na aba "Aranha"
  (`🕷️▶️ Andando — Vel. 1/2/3` e `🕷️⏹️ Parou`) para o operador marcar
  **manualmente, olhando a aranha ao vivo**, o instante exato em que ela
  começou/parou de andar, anexando automaticamente o último byte bruto da
  tiara naquele instante.

**Fluxo de uso pretendido** (já suportado pela UI, só falta executar e
depois analisar o log): conectar tiara (aba Tiara) + aranha (aba Aranha),
ligar o `Switch` de retransmissão, deixar o relay correndo, e cada vez que
a aranha se mexer/parar, apertar o botão correspondente. O log resultante
(`commandLogs`, visível na tela + `debugPrint` no console/logcat) fica com
linhas tipo:

```
[14:32:07.512] 🕷️▶️ ANDANDO — Velocidade 2 | Byte tiara: AA AA 04 04 5A 4D (há 42ms)
[14:32:11.003] 🕷️⏹️ PAROU | Byte tiara: AA AA 04 04 12 95 (há 18ms)
```

Cruzando várias marcações assim, dá pra isolar por eliminação qual byte
(posição fixa no pacote) varia de forma consistente com o movimento
observado — esse é o "byte que deve ser alterado" que falta identificar
antes de qualquer amplificação.

---

## 7. Recomendações / próximos passos

1. **Rodar a sessão de correlação manual** (seção 6) e coletar pelo menos
   10-20 marcações de "andando"/"parou" em velocidades diferentes.
   Idealmente anotar também momentos de "tentei concentrar e NÃO andou",
   para descartar falsos positivos.
2. **Comparar contra o canal oficial** (`BrainLinkViewModel`, hoje não
   plugado em nenhuma tela — bastaria instanciá-lo em paralelo) para saber
   o valor de atenção _decodificado_ no mesmo instante de cada marcação.
   Isso ajuda a confirmar se o byte candidato realmente corresponde ao
   campo de atenção do protocolo `Parser3`, ou é outra coisa (giroscópio,
   grind, sinal etc. — lembrando que `setDataType(5)` já habilita
   giroscópio + grind, então esses também trafegam e podem ser o gatilho
   real, não necessariamente atenção).
3. **Só depois** de ter um byte candidato validado por várias marcações
   consistentes, implementar a amplificação: interceptar em
   `TiaraRawViewModel._onRawBytes` (ou no relay do Kotlin) e reescrever
   esse byte especificamente antes do `relay()`/`write()`, preservando o
   restante do pacote (inclusive recalculando o checksum, se o framing for
   de fato o `AA AA ... checksum` do `Parser3` — um checksum inválido pode
   fazer a aranha descartar o pacote inteiro).
4. **Não presumir** que "amplificar" = "mandar sempre o valor máximo": se a
   aranha também olha _variação_ (borda de subida) em vez de valor
   absoluto, um valor travado em 100 pode nunca disparar nada. Vale testar
   as duas hipóteses.

---

## 8. Atualização — layout de bytes do canal BLE confirmado (`ParserBle`) + ferramentas de investigação

Depois de capturar uma amostra real de 505 bytes vindos da tiara (aba
"Tiara", `TiaraRawViewModel`), foi possível confirmar — por descompilação
adicional e validação byte a byte contra a captura real — que o canal BLE
(`6e400003`) **não** usa o `Parser3` descrito na seção 5.3 (esse é o parser
do canal **clássico**/SPP). Existe uma classe **dedicada** só pra BLE:
`com.boby.bluetoothconnect.parSer.ParserBle` (tag interna `"parser_4.0"`),
cuja lógica foi desmontada (`javap -c`) e bate **exatamente** com os bytes
capturados, incluindo o checksum.

### 8.1 Framing real confirmado

```
AA AA <PLEN> <payload...> <checksum> 23 23
```

O `23 23` no final **não existe** no `Parser3` clássico — é uma
particularidade do framing BLE desse modelo específico de tiara, usada pelo
próprio SDK como delimitador de frame (`ParserBle` literalmente separa o
stream nesse token). Checksum verificado em 3 pacotes da captura real do
usuário — fórmula clássica ThinkGear (`~soma(payload) & 0xFF`):

| payload       | soma & 0xFF | `~soma & 0xFF` | checksum no ar |
| ------------- | ----------- | -------------- | -------------- |
| `80 02 00 08` | `8A`        | `75`           | `75` ✅        |
| `80 02 00 17` | `99`        | `66`           | `66` ✅        |
| `80 02 00 28` | `AA`        | `55`           | `55` ✅        |

### 8.2 Duas assinaturas de pacote confirmadas por bytecode

- **`04 80 02 HI LO`** — amostra de onda bruta (RAW). Valor = `(HI<<8|LO)`,
  16 bits **com sinal** (se > 32768, subtrai 65536). **100% dos ~50 pacotes
  na captura de 505 bytes do usuário eram deste tipo** — é a onda EEG bruta
  em alta taxa de amostragem, não um valor decodificado.
- **`20 02` + 36 bytes** — o bloco "BrainWave" completo. **Não apareceu
  nenhuma vez** na captura de 505 bytes mostrada — é normal: esse bloco é
  bem mais raro que a onda bruta (tipicamente ~1x/segundo contra centenas
  de amostras RAW no mesmo intervalo), então uma janela curta pode não
  pegar nenhum. Offsets confirmados **diretamente no bytecode**
  (`ParserBle.parseBytes`, índice 0 = primeiro byte depois do "20 02"):

  | Offset     | Campo                                    | Tamanho           |
  | ---------- | ---------------------------------------- | ----------------- |
  | `[0]`      | `signal` (qualidade do sinal; 0 = ótimo) | 1 byte            |
  | `[3..5]`   | `delta`                                  | 3 bytes (24 bits) |
  | `[6..8]`   | `theta`                                  | 3 bytes           |
  | `[9..11]`  | `lowAlpha`                               | 3 bytes           |
  | `[12..14]` | `highAlpha`                              | 3 bytes           |
  | `[15..17]` | `lowBeta`                                | 3 bytes           |
  | `[18..20]` | `highBeta`                               | 3 bytes           |
  | `[21..23]` | `lowGamma`                               | 3 bytes           |
  | `[24..26]` | `middleGamma`                            | 3 bytes           |
  | **`[28]`** | **`attention` (0-100)**                  | 1 byte ⭐         |
  | **`[30]`** | **`meditation` (0-100)**                 | 1 byte ⭐         |
  | `[33]`     | `ap`                                     | 1 byte            |
  | `[35]`     | `batteryCapacity`                        | 1 byte            |

  (índices 1,2,27,29,31,32,34 não são lidos pelo parser oficial — prováveis
  marcadores de código residuais do protocolo clássico.)

- Existe também **`08 60 06` + 6 bytes** = giroscópio (Gravity X/Y/Z, 16
  bits com sinal cada), não relevante pra atenção/meditação mas identificado
  pelo mesmo processo.

### 8.3 Ferramentas de investigação implementadas (nesta sessão)

Com o layout confirmado, foram adicionadas duas ferramentas concretas ao
app — ambas puramente em Dart, sem tocar no lado Kotlin:

**a) `lib/src/domain/protocol/tiara_protocol.dart`** — módulo novo com:

- `TiaraFrameDecoder`: decodifica o stream bruto ao vivo (mesma lógica do
  `ParserBle`, reimplementada em bytes em vez de string), sem interferir no
  relay.
- `buildRawFrame(value)` / `buildBrainWaveFrame(attention: ..., meditation:
...)`: constroem pacotes **sintéticos, com framing e checksum válidos**,
  prontos pra injetar direto na aranha.

**b) Decodificação ao vivo na aba "Tiara"** (`TiaraRawViewModel` +
`TiaraRawPanel`) — um card mostra, assim que aparecer um pacote `20 02`,
os valores decodificados de atenção/meditação/sinal/bateria em tempo real
— sem precisar mais cruzar hex manualmente com timestamps.

**c) Injetor de pacotes na aba "Aranha"** (`SpiderClassicViewModel` +
`SpiderClassicPanel`, card "🧪 Injetor de Pacotes") — permite, **sem a
tiara conectada**, mandar pacotes sintéticos direto pra aranha via SDK:

- Sliders de atenção/meditação (0-100) + botão "Enviar 1 pacote" (envio
  pontual) ou switch "Stream contínuo (2/s)" (simula a tiara real
  mandando atualizações sustentadas — importante caso a aranha só reaja a
  um valor mantido, não a um pacote isolado).
- Botão "Rajada RAW (amplitude alta)" — testa a hipótese alternativa de
  que a aranha reage à amplitude/variação da onda bruta em vez de um
  campo decodificado.

### 8.4 Como isso muda o método de investigação recomendado (substitui a seção 6)

Em vez de correlacionar manualmente hex bruto com observação a olho nu, o
fluxo agora é:

1. **Testar a hipótese "atenção decodificada" primeiro, sem tiara**: na aba
   Aranha, com o canal SDK conectado, subir o slider de atenção pra 100 e
   ligar "Stream contínuo". Observar a aranha por ~5-10s. Repetir com
   meditação. Isso testa a hipótese comercialmente mais provável em minutos,
   sem depender de captar um pacote `20 02` real da tiara.
2. **Se nada acontecer**, testar a hipótese "onda bruta": botão de rajada
   RAW com amplitude alta, repetido algumas vezes.
3. **Se nenhuma das duas mexer a aranha**, o canal 1 customizado
   (`decafade/decadeaf/decacaff`, seção 3.2) provavelmente não é realmente o
   canal de controle, ou a aranha espera um protocolo totalmente diferente
   deste (não herdado do formato BLE da tiara) — nesse caso vale revisitar
   o dump SDP e considerar sniffar o tráfego de um app oficial da aranha,
   se existir.
4. **Em paralelo**, deixar a tiara conectada de verdade por alguns minutos
   (não só alguns segundos) pra dar tempo dos pacotes `20 02` reais
   aparecerem no card de leitura decodificada da aba Tiara, e comparar os
   valores reais de atenção contra o comportamento observado da aranha
   nesse período (agora sem precisar decodificar hex manualmente).

## 9. Atualização — análise do log de teste real (canal errado + correções aplicadas)

O usuário rodou uma sessão de teste com o injetor da seção 9 e anexou o log
completo ao final deste arquivo. A aranha **não se moveu em nenhum momento**,
independente de atenção alta, meditação alta, ou rajada RAW. A análise do log
revelou um problema estrutural que provavelmente explica o resultado sozinho,
**antes mesmo de qualquer questão de qual byte é o gatilho**.

### 9.1 Achado principal: todo o teste rodou no canal errado

```
I/BluetoothSocket(15342): connect(), socket connected. mPort=2
...
D/BluetoothSocket(15342): close() ... channel: 2 ...
```

A conexão usada (via botão "Conectar (SDK)", que chama
`SpiderClassicViewModel.connectSdk` → `BluetoothChatService` → UUID SPP
padrão fixo internamente, seção 5.5) caiu no **RFCOMM canal 2** — o canal
**genérico**, já documentado desde a seção 3.2 como "testado sem efeito
observado até agora". O canal 1 (UUID customizado
`00000000-deca-fade-deca-deafdecacaff`, nossa **aposta principal** de canal
de controle real, achado no dump SDP) **nunca foi tentado nesta sessão**,
porque a tela (`SpiderClassicPanel`) só tinha um botão de conexão
(`connectSdk`), e esse método é hardcoded no UUID SPP padrão — não existe
caminho, pela UI antiga, para forçar uma tentativa no UUID customizado.

O caminho que tenta o canal 1 primeiro (`SpiderClassicViewModel.connect()`,
que no Kotlin corresponde a `connectClassic()` com as 3 tentativas
ordenadas) sempre existiu no código, mas **nunca tinha botão exposto na
tela** — só era usado internamente para descoberta de dispositivos
(scan/bonded). Ou seja: **até agora, 100% dos testes de payload (mock ou
relay real) só puderam ter sido testados no canal já suspeito de não ser o
de controle.**

**Correção aplicada nesta sessão:**

- `SpiderClassicPanel` agora mostra **dois botões por dispositivo**:
  "Conectar (RAW / canal 1)" (tenta o UUID customizado primeiro — usa
  `viewModel.connect(mac)`) e "Conectar (SDK / canal 2)" (o de sempre).
  Os dois podem ficar conectados ao mesmo tempo, cada um com seu próprio
  card de status.
- `SpiderClassicViewModel.relay()`/`canRelay` (usados pelo relay real da
  tiara E pelo injetor mock) agora preferem o canal RAW quando ele está
  conectado, em vez de estarem hardcoded no canal SDK.

**Próximo passo óbvio**: repetir a bateria de testes do injetor (atenção,
meditação, presets de banda, RAW) conectando primeiro pelo botão **"RAW /
canal 1"** — se esse handshake tiver sucesso (o log vai mostrar
`usedLabel = "UUID customizado (decafade/decadeaf/decacaff)"`), essa é a
primeira vez que um payload de verdade chega nesse canal.

### 9.2 Sobre "o RAW mandado é só 300 bytes, mas a tiara manda 505 — está incompleto?"

**Não, não está incompleto** — os dois números não são comparáveis do jeito
que parecem:

- Os **505 bytes** da tiara real (seção 8) não são "um pacote"; é só
  quantos bytes vieram numa leitura específica do socket BLE (~50-56
  pacotes RAW de ~9 bytes cada, um número arbitrário — teria sido 300, 800
  ou 1200 dependendo exatamente de quando a captura começou/parou).
- Os **300 bytes** do mock (`sendMockRawBurst`) são **30 pacotes completos e
  válidos** (`count: 30` por padrão, 10 bytes cada = 300) — cada um com
  sync, checksum e trailer corretos. Nenhum pacote fica cortado.

O que **é** uma diferença real, e plausivelmente relevante: a tiara manda
onda bruta **continuamente**, em fluxo (o "505 bytes" era só um instantâneo
de um stream sem fim), enquanto `sendMockRawBurst()` mandava só **uma
rajada isolada de 30 amostras e parava**. Se a aranha precisa de sinal RAW
chegando de forma sustentada (não um blip único) pra reagir, a rajada única
nunca teria chance de disparar nada.

**Correção aplicada**: novo modo "Stream RAW contínuo (5/s)" — liga um
`Timer.periodic` que manda uma rajada de 30 amostras a cada 200ms
indefinidamente, imitando o padrão de fluxo contínuo real, em vez de um
único burst. Também virou ajustável a amplitude da onda sintética (era fixa
em ±4000 — bem mais alta que os valores típicos vistos na captura real, que
ficavam na casa de dezenas/centenas; agora dá pra testar valores mais
realistas ou mais extremos com um slider).

### 9.3 Novos testes adicionados: bandas de EEG (alpha/beta)

A pedido do usuário, o injetor ganhou dois presets que preenchem os campos
de banda do pacote `20 02` (delta/theta/lowAlpha/highAlpha/lowBeta/
highBeta/lowGamma/middleGamma — offsets exatos na seção 9.2), que antes
ficavam sempre zerados:

- **"Foco"**: `lowBeta`/`highBeta` altos, `lowAlpha`/`highAlpha` baixos
  (perfil tipicamente associado a atenção/concentração em literatura de
  EEG).
- **"Relaxado"**: o inverso (`alpha` alto, `beta` baixo — perfil de
  relaxamento).

Isso testa uma hipótese alternativa à do byte de atenção: que algum
firmware (da tiara ou da própria aranha) derive o gatilho diretamente das
potências de banda, não do campo `attention` (offset 28) já calculado.

### 9.4 Log completo do teste

O log bruto anexado pelo usuário (Logcat de uma sessão real) está preservado
na seção **12, "Anexo — log de teste"**, no final deste arquivo, pra não
quebrar o fluxo de leitura da documentação.

## 10. Atualização — edição ao vivo do relay real, replay de bytes reais e limpeza de código

A aranha continuou sem se mover em nenhum teste (sintético ou preset de
banda). O usuário levantou três pontos, cada um endereçado nesta sessão.

### 10.1 "A amplitude não muda nada que eu entenda"

Esclarecimento: o slider de "amplitude da onda RAW" no injetor **não é
potência de rádio Bluetooth** — ele nunca poderia ser, o app não controla
isso (é o rádio do celular/chip Bluetooth que decide a potência de
transmissão, fora do alcance de qualquer app). É o **valor numérico**
dentro do campo de onda bruta do pacote (offset 3-4 do frame `04 80 02`,
seção 8.2) — o número que a tiara usaria pra dizer "captei uma oscilação
elétrica desse tamanho no eletrodo agora". Mudar não afeta alcance,
velocidade de conexão nem nada de rádio — só o conteúdo do pacote. Texto
explicativo foi adicionado diretamente na UI (`spider_classic_panel.dart`
e `tiara_raw_panel.dart`) pra deixar isso claro na hora.

### 10.2 "Os outros bytes dos 505 não eram dados, mas não faria mal reenviá-los como estavam"

Correto, e implementado: `TiaraRawViewModel` agora mantém um
`rawByteHistory` — um buffer dos **últimos bytes genuinamente recebidos da
tiara** (até 8000 bytes, bem acima dos 505 vistos até agora). Um novo botão
na aba Aranha, **"Reenviar histórico real capturado (N bytes)"**
(`SpiderClassicViewModel.replayBytes`), manda esse trecho tal e qual pra
aranha — sem reconstrução, sem edição, exatamente os bytes que a tiara
realmente colocou no ar. Serve como teste de validação adicional: mesmo
sabendo que esse trecho específico é só onda bruta (sem pacote de
atenção), é tráfego 100% genuíno (framing e checksum reais), então não
custa nada testar se ALGO nesse padrão real — em vez de sintético — já
basta pra aranha reagir.

**Para usar**: conecte a tiara na aba Tiara (deixe alguns segundos
passarem pra acumular histórico), conecte a aranha na aba Aranha, e aperte
o botão — o contador de bytes no próprio botão mostra quanto já foi
capturado.

### 10.3 A feature principal: ler a tiara real, editar valores, reenviar

Esse era o pedido original ("ampliar o sinal") e agora está implementado
de fato, na aba **Tiara**, novo card **"✏️ Edição ao vivo (relay real, com
valores trocados)"**:

- **Como funciona**: com a tiara conectada de verdade e o relay ligado,
  cada pacote que sai pra aranha passa por
  `tiara_protocol.dart:patchTiaraStream()` antes de ser enviado. Essa
  função **não reconstrói nada do zero** — ela varre o stream real
  procurando frames `AA AA ... 23 23` reconhecidos, e só sobrescreve os
  bytes específicos que sabemos o que significam (offset de atenção,
  offset de meditação, valor da onda RAW), recalculando o checksum desse
  frame. Todo o resto do pacote — sinal, bandas não mexidas, bateria,
  campos que não entendemos — sai **exatamente** como a tiara mandou.
  Frames que não batem no comprimento exato esperado são deixados
  intocados, por segurança (nunca arrisca corromper algo desconhecido).
- **Controles**: switch "Forçar atenção" (0-100) e "Forçar meditação"
  (0-100), cada um com slider; switch "Amplificar onda RAW" com um
  multiplicador (×1 a ×10) aplicado ao valor real capturado em vez de um
  valor sintético fixo.
- Isso é literalmente diferente do injetor mock da aba Aranha (seção 8-9):
  lá os pacotes são 100% sintéticos e não dependem da tiara estar
  conectada; aqui o pacote é **real**, só um campo é trocado.

**Como testar**: aba Tiara → conectar tiara real → ligar "Retransmitir
bytes crus" → ligar "Edição ao vivo" → ligar "Forçar atenção" e subir pra
100 (ou testar valores variados) → observar a aranha. Se nem isso
disparar movimento, é um forte indício de que o campo de atenção
simplesmente não é o gatilho (ou o canal RAW/canal 1 ainda não conectou
de verdade — conferir seção 9.1 antes).

### 10.4 Limpeza de código (Dart + Kotlin + Manifest)

A pedido explícito do usuário ("se alguma função não for mais usada ou
sua ideia for descartada, tire-a do código"), foi feita uma varredura e
remoção do que estava genuinamente morto — confirmado por `grep` (Dart) e
por uma build real (`flutter build apk --debug`, sucesso) antes e depois
da remoção no Kotlin:

**Removido (Dart)** — nunca instanciados por nenhuma tela real:
- `lib/src/presentation/viewmodels/brainlink_viewmodel.dart`
- `lib/src/data/repositories/brainlink_repository.dart`
- `lib/src/domain/usecases/brainlink_usecase.dart`
- `lib/src/domain/models/ble_device.dart`
- `lib/src/domain/models/brain_data.dart`

**Removido (Kotlin, `MainActivity.kt`)** — confirmado sem nenhum chamador
do lado Dart (nenhum `MethodChannel`/`EventChannel` desses nomes é usado
em `lib/`):
- Todo o bloco do **emulador de tiara via GATT Server**
  (`startTiaraEmulation`/`stopTiaraEmulation`/GATT callbacks/advertising) —
  a hipótese que ele testava ("aranha conecta como central BLE") já tinha
  sido descartada pela própria seção 3.2.
- Todo o **canal oficial do SDK** (`brainlink_channel`,
  `brainlink_scan_channel`, `brainlink_data_channel`, `LinkManager.init`,
  `myEegListener`, a trava de segurança via reflection no `parser3`,
  `setOnConnectListener`, `setScanCallBack`) — o `BrainLinkViewModel` que o
  consumia já tinha sido removido do lado Dart.
- `override fun onCreate` inteiro (só existia pra fazer o setup acima —
  sem ele, o `onCreate` padrão do `FlutterActivity` já basta).

**Removido (Manifest)**: permissão `BLUETOOTH_ADVERTISE`, que só existia
pro emulador (peripheral/advertising BLE) — a aranha e a tiara são sempre
acessadas como *central*, nunca como *peripheral*, então o app não precisa
mais anunciar nada.

O que **ficou** (confirmadamente em uso): canal BLE raw da tiara
(`TiaraRawViewModel`), os dois canais RFCOMM da aranha (raw/canal 1 e
SDK/canal 2, `SpiderClassicViewModel`), e a seção 5 deste documento
continua descrevendo `LinkManager`/`BrainWave`/`Parser3` como referência
histórica de como o SDK funciona por dentro — só o *código que os usava*
foi removido, o conhecimento sobre o SDK permanece válido e é a base de
tudo que foi feito na seção 8.

## 11. Confirmado: o gatilho É atenção/meditação — calibrando o limiar exato

Usando o modo de edição ao vivo/injetor da seção 10, o usuário confirmou
**pela primeira vez movimento real da aranha**, em três combinações
aproximadas de atenção/meditação (achadas por tentativa e erro):

| Velocidade observada | Atenção | Meditação | Diferença (at−med) | Soma (at+med) |
|---|---|---|---|---|
| 1 (lenta) | ≈ 35 | ≈ 60 | ≈ −25 | ≈ 95 |
| 2 (média) | 64 | 37 | +27 | 101 |
| 3 (rápida) | > 80 | < 30 | > +50 | ≈ 100-110 |

Fora dessas faixas, ela não andava. E um achado novo e crítico: **segurar
o mesmo dado por tempo demais faz ela PARAR** — mesmo dentro de uma faixa
que funciona.

### 11.1 O padrão nos números

A coincidência que salta aos olhos: **a soma (atenção+meditação) fica
sempre perto de 100** nos três pontos (95, 101, ~100-110), enquanto a
**diferença** (atenção−meditação) varia de forma consistente com a
velocidade (−25 → +27 → >+50, crescente). Isso sugere um mecanismo em duas
partes, comum em firmware simples de brinquedo:

1. **Um "gate" de coerência**: só aceita o dado como válido se
   atenção+meditação ficar perto de 100 — um jeito barato de checar "isso
   parece uma leitura plausível" sem precisar entender o dado de verdade
   (na tiara real, atenção e meditação são calculadas de formas
   parcialmente opostas, então tendem a se aproximar dessa relação em
   condições normais — o firmware da aranha pode ter sido calibrado
   assumindo isso).
2. **A diferença escolhe a velocidade**, dentro do que passa no gate.

Chamamos isso de **H3** — a hipótese líder, mas não confirmada ainda.
Hipóteses concorrentes:

- **H1 — limiares independentes**: bate com a descrição literal do
  usuário ("atenção>80 E meditação<30") — cada variável teria sua própria
  faixa por velocidade, sem relação de soma/diferença nenhuma.
- **H2 — só a diferença importa**: igual à H3, mas sem o gate de soma —
  qualquer combinação com a diferença certa funcionaria, mesmo se a soma
  estiver longe de 100.

### 11.2 Bateria de testes para distinguir as hipóteses

Implementada como botões de um clique na aba Aranha (card "🔬 Varredura
automática de limiares", `SpiderClassicViewModel`), cada um roda uma
sequência de pontos sozinho — o operador só observa a aranha e usa os
botões de "Marcar Movimento" já existentes:

1. **Varredura diagonal** (`runDiagonalSweep`) — varre a diferença de −100
   a +100 em passos de 10, mantendo a soma travada em 100
   (atenção=50+diff/2, meditação=50−diff/2). Se H3 estiver certa, essa
   varredura sozinha já revela os limiares exatos das 3 velocidades **e**
   onde ela para de responder nas pontas. É o teste mais barato — rodar
   primeiro.
2. **Checagem de invariância de soma** (`runSumInvarianceCheck`) — trava a
   diferença em 27 (o valor do V2, que já se sabe que funciona) e testa 3
   somas diferentes (70, 100, 130). Se ela andar na velocidade 2 nas três,
   a soma não importa (H2 confirmada, H3 refutada). Se só andar perto de
   soma=100, o gate é real (H3 confirmada).
3. **Varredura de atenção isolada** (`runAttentionSweep`) — trava
   meditação em 37 (valor do V2) e varre atenção de 0 a 100. Testa H1
   diretamente: se existir um limiar de atenção "sozinho" (independente
   da meditação), aparece aqui.
4. **Varredura de meditação isolada** (`runMeditationSweep`) — o espelho
   do teste 3: trava atenção em 64, varre meditação de 0 a 100.
5. **Teste de estagnação** (`runStaleDataTest`) — manda um valor **100%
   estático** (SEM jitter, de propósito) num combo que já funciona (padrão
   V2) e fica remandando os mesmos bytes até você mandar parar.
   Cronometra quanto tempo ela aguenta antes de desistir — esse número
   calibra o quão frequente o jitter/refresh precisa ser pra sustentar uma
   caminhada de verdade.

Todos os testes têm **jitter automático** (± alguns pontos, configurável
na mesma tela) aplicado a cada envio — sem isso, qualquer ponto "segurado"
por mais de alguns segundos cairia exatamente no problema descrito no
início desta seção (dado estático → ela para), inutilizando o próprio
teste.

### 11.3 Como interpretar o resultado e amplificar de verdade

Depois de rodar a bateria acima e anotar os limiares reais (não mais
estimativas), a implementação da amplificação muda dependendo de qual
hipótese venceu:

- **Se H1 (limiares independentes)** venceu: a amplificação mais simples é
  um **ganho independente** em cada campo — ex.: `atenção' = clamp(atenção
  × 1.4, 0, 100)` e `meditação' = clamp(meditação × 0.7, 0, 100)` (empurra
  os dois na direção que ajuda a cruzar os limiares de cada variável,
  sem depender da soma).
- **Se H2 ou H3 (a diferença manda)** venceu: a amplificação certa é
  amplificar a **diferença**, não os valores brutos — pegar
  `diff_real = atenção_real − meditação_real`, aplicar um ganho
  (`diff' = diff_real × k`, com `k` calibrado pelos limiares reais
  achados), e reconstruir `atenção' = 50 + diff'/2`,
  `meditação' = 50 − diff'/2` (mantendo soma≈100 se H3, ou livre se H2).
  Essa reconstrução **preserva o ruído natural** da leitura real (porque
  parte do valor real, não de uma constante), o que resolve de graça o
  problema de estagnação descrito no início desta seção — nunca fica
  estático porque a tiara real nunca é estática.

Em qualquer um dos dois casos, o ponto crítico pra não fazer a aranha
"andar constantemente" (pedido explícito do usuário) é **não achatar o
sinal num valor fixo** — aplicar um ganho/curva sobre a leitura real
mantém a exigência de esforço real (só fica proporcionalmente mais fácil
de cruzar o limiar), em vez de eliminar a exigência por completo.

## 12. Resumo de UUIDs e identificadores confirmados

| Identificador                                                           | Valor                                  | Fonte                             | Confirmado no `.jar`?                       |
| ----------------------------------------------------------------------- | -------------------------------------- | --------------------------------- | ------------------------------------------- |
| Serviço BLE da tiara                                                    | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | captura real (scanner/log)        | ❌ não está no SDK — é o padrão Nordic UART |
| Característica de escrita da tiara                                      | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | captura real                      | ❌ idem                                     |
| Característica de notificação da tiara                                  | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | captura real                      | ❌ idem                                     |
| UUID SPP padrão (canal 2 da aranha / canal SDK)                         | `00001101-0000-1000-8000-00805F9B34FB` | `classic.Constants.STR_UUID`      | ✅ sim                                      |
| UUID proprietário (canal 1 da aranha, candidato ao canal de controle)   | `00000000-deca-fade-deca-deafdecacaff` | dump SDP real (`btsnoop_hci.log`) | ❌ específico da aranha, não da tiara       |
| `WRITE_SERVICE_UUID` (SDK, não usado hoje pelo app)                     | `00001805-0000-1000-8000-00805f9b34fb` | `UUIDUtils`                       | ✅ sim                                      |
| `DEVICE_SERVICE_UUID`/`DEVICE_CHAR_UUID` (SDK, não usado hoje pelo app) | `0000ffe0.../0000ffe1...`              | `UUIDUtils`                       | ✅ sim                                      |

## 13. Anexo — log de teste real (sessão anexada pelo usuário)

Logcat bruto de uma sessão real de teste com o injetor de pacotes (seção 8),
usado como base pra análise da seção 9. Preservado na íntegra abaixo.

```
Launching lib\main.dart on 23117RA68G in debug mode...
I/flutter (13672): [WxaLiteApp] Hello WxaLiteApp defaultRouteName /-1000
I/flutter (13672): engineId 1000
I/flutter (13672): 2026-08-20 10:09:39 I/LiteApp.WxaRouter.WxaRouterChannel create channel. com.tencent.wxa/wxa_router
I/flutter (13672): [INFO:/data/landun/workspace/wxa_lite_app/wxa_lite_app/third_party/luggage/fml/message_loop.cc(31)] create MessageLoop for current thread
I/flutter (13672): [I][MicroMsg.Flutter.EmojiUtils]: checkEnableSupportEmoji:true
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.EmojiHelper]: EmojiHelper instance create
I/flutter (13672): [I][MicroMsg.Flutter.EmojiPlatformResPathProvider]: configInit
I/flutter (13672): [2026-08-20 10:09:39.968580 | Catcher | WARNING] Screenshots path is empty. Screenshots won't work.
I/flutter (13672): [2026-08-20 10:09:39.972242 | Catcher | FINE] Catcher configured successfully.
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.EmojiHelper]: initEmojiRes, OnWorkerIsolate start
I/flutter (13672): [I][MicroMsg.Flutter.EmojiPlatformResPathProvider]: configInit
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.SystemEmojiProcessor]: try to init system emoji res , path:/data/user/0/com.tencent.mm/app_font/color_emoji_new
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.SystemEmojiProcessor]: check , read emoji headerinfo bytes count:16
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.SystemEmojiProcessor]: supportVersion:1,emojiVersion:1647833108401000, headerSize:119152
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.SystemEmojiProcessor]: emojiheader parse done, emoji item count:4084 , softbankItem count:470, nameIdxItem count:467
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.QQSmileyManager]: initXMLSmiley texts.length:105 \_textsCh.length:105
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.QQSmileyManager]: initXMLSmiley success
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.QQSmileyManager]: updateSmiley: new smiley load size: 45
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.EmojiHelper]: initEmojiRes, OnWorkerIsolate end
I/flutter (13672): [I][MicroMsg.Flutter.Emoji.EmojiHelper]: updateMainIsolateEmoji finish
√ Built build\app\outputs\flutter-apk\app-debug.apk
I/FlutterActivityAndFragmentDelegate(15342): If you are attempting to set --start-paused via Intent extras to launch a Flutter component outside of using the Flutter CLI, note that support for setting engine flags on Android via Intent will soon be dropped; see https://github.com/flutter/flutter/issues/180686 for more information on this breaking change. To migrate, set --start-paused or any other flags specified via Intent extras on the command line instead or see https://github.com/flutter/flutter/blob/main/docs/engine/Flutter-Android-Engine-Flags.md for alternative methods.
D/FlutterJNI(15342): Beginning load of flutter...
D/FlutterJNI(15342): flutter (null) was loaded normally!
I/flutter (15342): [IMPORTANT:flutter/shell/platform/android/android_context_vk_impeller.cc(62)] Using the Impeller rendering backend (Vulkan).
D/FlutterRenderer(15342): Width is zero. 0,0
D/FlutterRenderer(15342): Width is zero. 0,0
D/FlutterJNI(15342): Sending viewport metrics to the engine.
D/FlutterJNI(15342): Sending viewport metrics to the engine.
Connecting to VM Service at ws://127.0.0.1:53678/8j7JpH65ZRU=/ws
Connected to the VM Service.
I/Choreographer(15342): Skipped 60 frames! The application may be doing too much work on its main thread.
I/GrallocExtra(15342): gralloc_extra_query:is_SW3D 0
I/GrallocExtra(15342): gralloc_extra_query:is_SW3D 0
W/libc (15342): Access denied finding property "ro.vendor.display.iris_x7.support"
W/1.raster(15342): type=1400 audit(0.0:113444): avc: denied { read } for name="u:object_r:vendor_displayfeature_prop:s0" dev="tmpfs" ino=565 scontext=u:r:untrusted_app:s0:c43,c259,c512,c768 tcontext=u:object_r:vendor_displayfeature_prop:s0 tclass=file permissive=0 app=com.example.brainlink
D/BLASTBufferQueue(15342): [1a1eb83 SurfaceView[com.example.brainlink/com.example.brainlink.MainActivity]#1](f:0,a:1) acquireNextBufferLocked size=1080x2400 mFrameNumber=1 applyTransaction=true mTimestamp=116416779472861(auto) mPendingTransactions.size=0 graphicBufferId=65893388255242 transform=0
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
D/FlutterJNI(15342): Sending viewport metrics to the engine.
D/VRI[MainActivity](15342): vri.Setup new sync=wmsSync-VRI[MainActivity]#1
I/SKIA (15342): CreateGraphicsPipeline pipeline cache hit. elpased time: 0.20 ms.
I/SKIA (15342): CreateGraphicsPipeline pipeline cache hit. elpased time: 0.12 ms.
D/BLASTBufferQueue(15342): [VRI[MainActivity]#0](f:0,a:1) acquireNextBufferLocked size=1080x2400 mFrameNumber=1 applyTransaction=true mTimestamp=116416851685554(auto) mPendingTransactions.size=0 graphicBufferId=65893388255250 transform=0
D/VRI[MainActivity](15342): vri.reportDrawFinished 0 0 Rect(0, 0 - 1080, 2400)
I/NativeTurboSchedManager(15342): Load libmiui_runtime
D/ProfileInstaller(15342): Installing profile for com.example.brainlink
I/HandWritingStubImpl(15342): refreshLastKeyboardType: 1
I/HandWritingStubImpl(15342): getCurrentKeyboardType: 1
D/InsetsController(15342): hide(ime(), fromIme=false)
I/ImeTracker(15342): com.example.brainlink:c8f394b6: onCancelled at PHASE_CLIENT_ALREADY_HIDDEN
I/HandWritingStubImpl(15342): getCurrentKeyboardType: 1
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
W/InsetsSource(15342): Has no intersection or mTmpFrame.height(), return Insets.NONE mTmpFrame.height() =0 hasIntersection =false
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116457610, downTime=116457610, phoneEventTime=1787231536114 } moveCount:0
W/MirrorManager(15342): this model don't Support
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/PowerHalMgrImpl(15342): perfLockAcq is supported.
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116457660, downTime=116457610, phoneEventTime=1787231536163 } moveCount:0
E/ample.brainlink(15342): FrameInsert open fail: No such file or directory
I/PowerHalMgrImpl(15342): hdl:95625, pid:15342
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116463536, downTime=116463536, phoneEventTime=1787231542039 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116463601, downTime=116463536, phoneEventTime=1787231542105 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:12:22.173] 🔗 Pareado: 'DAPON H02D' | MAC: 38:AA:D8:08:2E:A3 | Estado: BONDED
I/flutter (15342): SPIDER_SPP: [10:12:22.262] 🔗 Pareado: 'gabriel-550XDA' | MAC: 70:32:17:94:90:93 | Estado: BONDED
I/flutter (15342): SPIDER_SPP: [10:12:22.265] 🔗 Pareado: 'eu te amo mi amore' | MAC: 5C:5E:0A:26:96:E9 | Estado: BONDED
I/flutter (15342): SPIDER_SPP: [10:12:22.267] 🔗 Pareado: 'Spider_robot' | MAC: 0D:00:18:A9:8B:55 | Estado: BONDED
I/flutter (15342): SPIDER_SPP: [10:12:22.268] 🔗 Pareado: '联想thinkplus-GM2 pro' | MAC: 67:DA:D2:86:5B:52 | Estado: BONDED
I/flutter (15342): SPIDER_SPP: [10:12:22.392] 🔗 Pareado: 'Echo Pop-42L' | MAC: 7C:ED:C6:59:67:A5 | Estado: BONDED
I/flutter (15342): SPIDER_SPP: [10:12:22.394] 🔗 Pareado: 'BrainLink_Pro' | MAC: 90:E2:FC:2D:AD:8E | Estado: BONDED
I/PowerHalMgrImpl(15342): hdl:95630, pid:15342
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116464793, downTime=116464793, phoneEventTime=1787231543297 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/PowerHalMgrImpl(15342): hdl:95635, pid:15342
E/LB (15342): fail to open file: No such file or directory
W/1.raster(15342): type=1400 audit(0.0:113457): avc: denied { getattr } for path="/sys/module/metis/parameters/minor_window_app" dev="sysfs" ino=79800 scontext=u:r:untrusted_app:s0:c43,c259,c512,c768 tcontext=u:object_r:sysfs_migt:s0 tclass=file permissive=0 app=com.example.brainlink
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116465430, downTime=116464793, phoneEventTime=1787231543934 } moveCount:109
I/PowerHalWrapper(15342): PowerHalWrapper.getInstance
E/ample.brainlink(15342): legacy_receive_flag: 1
D/ample.brainlink(15342): /proc/perfmgr_sbe/sbe_ioctl not exists: No such file or directory
I/PowerHalMgrImpl(15342): hdl:95638, pid:15342
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116465864, downTime=116465864, phoneEventTime=1787231544368 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116465908, downTime=116465864, phoneEventTime=1787231544411 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:12:24.432] Tentando conectar via BluetoothChatService oficial do SDK...
I/flutter (15342): SPIDER_SPP: [10:12:24.440] [SDK] Conectando via BluetoothChatService oficial (insecure, UUID SPP padrão) a 0D:00:18:A9:8B:55...
I/BluetoothSocket(15342): connect(), SocketState: INIT, mPfd: {ParcelFileDescriptor: java.io.FileDescriptor@c1ff4de}
D/BluetoothSocket(15342): mRstricteState = false
I/flutter (15342): SPIDER_SPP: [10:12:24.515] [SDK] Mudança de estado interna: arg1=2
I/PowerHalMgrImpl(15342): hdl:95643, pid:15342
I/BluetoothSocket(15342): connect(), socket connected. mPort=2
I/flutter (15342): SPIDER_SPP: [10:12:30.019] [SDK] Mudança de estado interna: arg1=3
I/flutter (15342): SPIDER_SPP: [10:12:30.024] [SDK] ✅ CONECTADO via BluetoothChatService oficial -> Spider_robot (0D:00:18:A9:8B:55)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116474822, downTime=116474822, phoneEventTime=1787231553326 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/PowerHalMgrImpl(15342): hdl:95648, pid:15342
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116475441, downTime=116474822, phoneEventTime=1787231553945 } moveCount:103
I/PowerHalMgrImpl(15342): hdl:95651, pid:15342
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116476689, downTime=116476689, phoneEventTime=1787231555193 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/PowerHalMgrImpl(15342): hdl:95656, pid:15342
I/MiInputConsumer(15342): optimized resample latency: 11584572 ns
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116477650, downTime=116476689, phoneEventTime=1787231556154 } moveCount:45
I/ScrollIdentify(15342): on fling
I/PowerHalMgrImpl(15342): hdl:95663, pid:15342
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116478055, downTime=116478055, phoneEventTime=1787231556559 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116478120, downTime=116478055, phoneEventTime=1787231556624 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:12:36.632] 🧪 Streaming mock de atenção/meditação LIGADO (2/s)
I/flutter (15342): SPIDER_SPP: [10:12:37.147] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 47 05 00 00 00 00 00 64 8E 23 23
I/PowerHalMgrImpl(15342): hdl:95668, pid:15342
I/flutter (15342): SPIDER_SPP: [10:12:37.639] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [10:12:38.138] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [10:12:38.638] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 47 05 00 00 00 00 00 64 8E 23 23
I/flutter (15342): SPIDER_SPP: [10:12:39.139] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [10:12:39.637] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [10:12:40.141] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 47 05 00 00 00 00 00 64 8E 23 23
I/flutter (15342): SPIDER_SPP: [10:12:40.639] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [10:12:41.138] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [10:12:41.638] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 47 05 00 00 00 00 00 64 8E 23 23
I/flutter (15342): SPIDER_SPP: [10:12:42.137] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [10:12:42.638] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 47 05 00 00 00 00 00 64 8E 23 23
I/flutter (15342): SPIDER_SPP: [10:12:43.136] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=0)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116484865, downTime=116484865, phoneEventTime=1787231563368 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/PowerHalMgrImpl(15342): hdl:95673, pid:15342
I/flutter (15342): SPIDER_SPP: [10:12:43.684] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=10)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 47 05 0A 00 00 00 00 64 84 23 23
I/flutter (15342): SPIDER_SPP: [10:12:44.175] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=27)
I/PowerHalMgrImpl(15342): hdl:95676, pid:15342
I/flutter (15342): SPIDER_SPP: [10:12:44.637] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=36)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 47 05 23 00 00 00 00 64 6B 23 23
I/flutter (15342): SPIDER_SPP: [10:12:45.135] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=40)
I/flutter (15342): SPIDER_SPP: [10:12:45.660] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=44)
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116487155, downTime=116484865, phoneEventTime=1787231565659 } moveCount:201
I/flutter (15342): SPIDER_SPP: [10:12:46.140] 🧪 Mock enviado: BrainWave sintético (atenção=71, meditação=44)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 47 05 2C 00 00 00 00 64 62 23 23
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116487778, downTime=116487778, phoneEventTime=1787231566282 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/PowerHalMgrImpl(15342): hdl:95685, pid:15342
I/flutter (15342): SPIDER_SPP: [10:12:46.673] 🧪 Mock enviado: BrainWave sintético (atenção=80, meditação=44)
I/flutter (15342): SPIDER_SPP: [10:12:47.135] 🧪 Mock enviado: BrainWave sintético (atenção=86, meditação=44)
I/PowerHalMgrImpl(15342): hdl:95687, pid:15342
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116488985, downTime=116487778, phoneEventTime=1787231567489 } moveCount:120
I/flutter (15342): SPIDER_SPP: [10:12:47.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 2C 00 00 00 00 64 50 23 23
I/flutter (15342): SPIDER_SPP: [10:12:48.138] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/flutter (15342): SPIDER_SPP: [10:12:48.639] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 2C 00 00 00 00 64 50 23 23
I/flutter (15342): SPIDER_SPP: [10:12:49.137] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116490937, downTime=116490937, phoneEventTime=1787231569441 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116491001, downTime=116490937, phoneEventTime=1787231569505 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:12:49.519] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/flutter (15342): SPIDER_SPP: [10:12:49.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/flutter (15342): SPIDER_SPP: [10:12:50.135] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 2C 00 00 00 00 64 50 23 23
I/PowerHalMgrImpl(15342): hdl:95695, pid:15342
I/flutter (15342): SPIDER_SPP: [10:12:50.635] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/flutter (15342): SPIDER_SPP: [10:12:51.135] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/flutter (15342): SPIDER_SPP: [10:12:51.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 2C 00 00 00 00 64 50 23 23
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116493541, downTime=116493541, phoneEventTime=1787231572044 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/flutter (15342): SPIDER_SPP: [10:12:52.134] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=44)
I/PowerHalMgrImpl(15342): hdl:95700, pid:15342
I/flutter (15342): SPIDER_SPP: [10:12:52.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=70)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 46 00 00 00 00 64 36 23 23
I/PowerHalMgrImpl(15342): hdl:95702, pid:15342
I/flutter (15342): SPIDER_SPP: [10:12:53.135] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116494776, downTime=116493541, phoneEventTime=1787231573280 } moveCount:101
I/flutter (15342): SPIDER_SPP: [10:12:53.638] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116495292, downTime=116495292, phoneEventTime=1787231573796 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116495360, downTime=116495292, phoneEventTime=1787231573864 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:12:53.879] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:12:54.135] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:12:54.638] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/PowerHalMgrImpl(15342): hdl:95709, pid:15342
I/flutter (15342): SPIDER_SPP: [10:12:55.137] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116497010, downTime=116497010, phoneEventTime=1787231575514 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116497068, downTime=116497010, phoneEventTime=1787231575571 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:12:55.582] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/flutter (15342): SPIDER_SPP: [10:12:55.664] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:12:56.135] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/PowerHalMgrImpl(15342): hdl:95714, pid:15342
I/flutter (15342): SPIDER_SPP: [10:12:56.639] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/flutter (15342): SPIDER_SPP: [10:12:57.138] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:12:57.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:12:58.140] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/flutter (15342): SPIDER_SPP: [10:12:58.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:12:59.139] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:12:59.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/flutter (15342): SPIDER_SPP: [10:13:00.137] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:00.638] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116502419, downTime=116502419, phoneEventTime=1787231580923 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/flutter (15342): SPIDER_SPP: [10:13:01.136] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:01.635] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/PowerHalMgrImpl(15342): hdl:95718, pid:15342
I/flutter (15342): SPIDER_SPP: [10:13:02.136] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116503808, downTime=116502419, phoneEventTime=1787231582312 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:02.326] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116503964, downTime=116503964, phoneEventTime=1787231582468 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116504029, downTime=116503964, phoneEventTime=1787231582533 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:02.541] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116504127, downTime=116504127, phoneEventTime=1787231582630 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/flutter (15342): SPIDER_SPP: [10:13:02.640] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116504238, downTime=116504127, phoneEventTime=1787231582742 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:02.755] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116504295, downTime=116504295, phoneEventTime=1787231582799 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116504352, downTime=116504295, phoneEventTime=1787231582856 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:02.872] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116504423, downTime=116504423, phoneEventTime=1787231582927 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/flutter (15342): SPIDER_SPP: [10:13:03.137] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116504690, downTime=116504423, phoneEventTime=1787231583194 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:03.207] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116504838, downTime=116504838, phoneEventTime=1787231583342 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116504911, downTime=116504838, phoneEventTime=1787231583414 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:03.428] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/flutter (15342): SPIDER_SPP: [10:13:03.635] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116505170, downTime=116505170, phoneEventTime=1787231583674 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116505247, downTime=116505170, phoneEventTime=1787231583751 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:03.764] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (300 bytes): AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23
I/flutter (15342): SPIDER_SPP: [10:13:04.135] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:04.639] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/PowerHalMgrImpl(15342): hdl:95738, pid:15342
I/flutter (15342): SPIDER_SPP: [10:13:05.139] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/flutter (15342): SPIDER_SPP: [10:13:05.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:06.139] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/flutter (15342): SPIDER_SPP: [10:13:06.639] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:07.141] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/flutter (15342): SPIDER_SPP: [10:13:07.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:08.137] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:08.637] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/flutter (15342): SPIDER_SPP: [10:13:09.138] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116510911, downTime=116510911, phoneEventTime=1787231589415 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/PowerHalMgrImpl(15342): hdl:95743, pid:15342
I/flutter (15342): SPIDER_SPP: [10:13:09.635] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:10.135] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/PowerHalMgrImpl(15342): hdl:95745, pid:15342
I/flutter (15342): SPIDER_SPP: [10:13:10.636] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:11.135] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116513034, downTime=116510911, phoneEventTime=1787231591538 } moveCount:437
I/ScrollIdentify(15342): on fling
I/flutter (15342): SPIDER_SPP: [10:13:11.634] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/flutter (15342): SPIDER_SPP: [10:13:12.138] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [10:13:12.636] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/flutter (15342): SPIDER_SPP: [10:13:13.138] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116515114, downTime=116515114, phoneEventTime=1787231593618 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/flutter (15342): SPIDER_SPP: [10:13:13.634] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/PowerHalMgrImpl(15342): hdl:95758, pid:15342
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116515443, downTime=116515114, phoneEventTime=1787231593947 } moveCount:65
I/ScrollIdentify(15342): on fling
I/flutter (15342): SPIDER_SPP: [10:13:14.135] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (43 bytes): AA AA 20 02 00 83 18 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 59 05 4B 00 00 00 00 64 31 23 23
I/PowerHalMgrImpl(15342): hdl:95764, pid:15342
I/flutter (15342): SPIDER_SPP: [10:13:14.636] 🧪 Mock enviado: BrainWave sintético (atenção=89, meditação=75)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116516544, downTime=116516544, phoneEventTime=1787231595047 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116516583, downTime=116516544, phoneEventTime=1787231595087 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:15.092] 🧪 Streaming mock DESLIGADO
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116517148, downTime=116517148, phoneEventTime=1787231595652 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/PowerHalMgrImpl(15342): hdl:95773, pid:15342
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116517809, downTime=116517148, phoneEventTime=1787231596313 } moveCount:58
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116518141, downTime=116518141, phoneEventTime=1787231596645 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116518223, downTime=116518141, phoneEventTime=1787231596727 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:16.734] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (300 bytes): AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116518980, downTime=116518980, phoneEventTime=1787231597484 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/PowerHalMgrImpl(15342): hdl:95783, pid:15342
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116519575, downTime=116518980, phoneEventTime=1787231598079 } moveCount:130
I/PowerHalMgrImpl(15342): hdl:95786, pid:15342
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116521164, downTime=116521164, phoneEventTime=1787231599668 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116521333, downTime=116521164, phoneEventTime=1787231599836 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:19.850] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (300 bytes): AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116521804, downTime=116521804, phoneEventTime=1787231600307 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116521869, downTime=116521804, phoneEventTime=1787231600373 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:20.384] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116522201, downTime=116522201, phoneEventTime=1787231600705 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116522225, downTime=116522201, phoneEventTime=1787231600729 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:20.742] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_DOWN, id[0]=0, pointerCount=1, eventTime=116522352, downTime=116522352, phoneEventTime=1787231600856 } moveCount:0
D/VRI[MainActivity](15342): getMiuiFreeformStackInfo mTmpFrames.miuiFreeFormStackInfo: null
I/HandWritingStubImpl(15342): setCurrentKeyboardType: 1
I/MIUIInput(15342): [MotionEvent] ViewRootImpl windowName 'com.example.brainlink/com.example.brainlink.MainActivity', { action=ACTION_UP, id[0]=0, pointerCount=1, eventTime=116522376, downTime=116522352, phoneEventTime=1787231600880 } moveCount:0
I/flutter (15342): SPIDER_SPP: [10:13:20.893] 🧪 Mock enviado: rajada RAW (30 amostras, amplitude ±4000)
I/flutter (15342): SPIDER_SPP: [SDK] ➡️ Enviado via BluetoothChatService oficial (300 bytes): AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23 AA AA 04 80 02 0F A0 CA 23 23 AA AA 04 80 02 F0 60 29 23 23
I/PowerHalMgrImpl(15342): hdl:95801, pid:15342
D/BluetoothSocket(15342): close() this: XX:XX:XX:XX:8B:55, channel: 2, mSocketIS: android.net.LocalSocketImpl$SocketInputStream@7eb16bf, mSocketOS: android.net.LocalSocketImpl$SocketOutputStream@6c1118c, mSocket: android.net.LocalSocket@1d550d5 impl:android.net.LocalSocketImpl@3280ea fd:java.io.FileDescriptor@c1ff4de, mSocketState: CLOSED
D/BluetoothSocket(15342): removeChangeCallback
I/flutter (15342): SPIDER_SPP: [10:13:27.870] [SDK] Mudança de estado interna: arg1=5
I/flutter (15342): SPIDER_SPP: [10:13:27.874] [SDK] Desconectado do canal SDK oficial.
D/BluetoothSocket(15342): accept(), timeout (ms):-1
D/BluetoothSocket(15342): accept(), timeout (ms):-1
I/flutter (15342): SPIDER_SPP: [10:13:28.085] [SDK] Mudança de estado interna: arg1=1

```
