package com.example.brainlink // Mantenha o seu pacote

import android.bluetooth.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.boby.bluetoothconnect.classic.listener.OnReceiveBytesListener
import com.boby.bluetoothconnect.services.BluetoothChatService
import java.io.IOException
import java.util.UUID

class MainActivity: FlutterActivity() {
    // --- Canais da conexão CLÁSSICA (SPP/RFCOMM) com a aranha ---
    private val SPIDER_CLASSIC_METHOD_CHANNEL = "spider_classic_channel"
    private val SPIDER_CLASSIC_EVENT_CHANNEL = "spider_classic_events"

    private var spiderClassicEventSink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    // ==========================================================
    // CONEXÃO CLÁSSICA (SPP/RFCOMM) COM A ARANHA
    // ==========================================================
    // Achado ao descompilar o BlueManager$ConnectDeviceRunnable do
    // MacrotellectLink_V1_4_3.jar: o SDK oficial conecta na TIARA clássica
    // via socket RFCOMM INSEGURO (createInsecureRfcommSocketToServiceRecord)
    // usando o UUID padrão de SPP, e NUNCA chama createBond()/device.pair().
    // Ou seja: nenhum pareamento passa pela tela de Configurações do Android.
    // Como a aranha também é um acessório clássico da Macrotellect (aparece
    // com ícone de headset/SPP na busca do sistema e trava em "Pairing..."
    // quando pareada pelas Configurações), a aposta é que ela funciona do
    // mesmo jeito: ignorar o fluxo de pareamento e abrir o socket direto.
    private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    // Achado analisando o btsnoop_hci.log de uma tentativa de conexão real:
    // a aranha registra DOIS serviços RFCOMM via SDP, os dois nomeados
    // "Spider_robot":
    //   - canal 2 = UUID padrão de SPP (0x1101) — genérico, é o que a gente
    //     vinha usando até agora, sem nenhum efeito.
    //   - canal 1 = UUID CUSTOMIZADO/proprietário — provavelmente o canal
    //     de controle de verdade. Byte a byte do ServiceClassIDList:
    //     00 00 00 00 de ca fa de de ca de af de ca ca ff
    //     ("decafade" / "decadeaf" / "decacaff").
    // Por isso agora tentamos esse UUID customizado PRIMEIRO.
    private val SPIDER_CUSTOM_UUID = UUID.fromString("00000000-deca-fade-deca-deafdecacaff")

    private var classicDiscoveryReceiver: BroadcastReceiver? = null
    private var classicSocket: BluetoothSocket? = null
    private var classicReadThread: Thread? = null
    @Volatile private var classicConnectThread: Thread? = null

    // Fila de escrita dedicada para o socket clássico. sendClassicBytes() é
    // chamado pelo handler do MethodChannel, que roda na UI thread — um
    // socket.outputStream.write() síncrono ali travava o app inteiro a cada
    // pacote retransmitido da tiara (relay dispara em intervalo muito curto).
    // Agora o handler só enfileira e retorna na hora; quem escreve de fato é
    // essa thread dedicada. Capacidade pequena e descarte do mais antigo
    // quando cheia: para controle de movimento em tempo real, o pacote mais
    // recente importa mais que um atrasado.
    private val classicWriteQueue = java.util.concurrent.LinkedBlockingQueue<ByteArray>(50)
    private var classicWriteThread: Thread? = null
    @Volatile private var classicWriteThreadRunning = false

    private fun emitClassicEvent(message: String, extra: Map<String, Any?> = emptyMap()) {
        val payload = mutableMapOf<String, Any?>("message" to message)
        payload.putAll(extra)
        mainHandler.post { spiderClassicEventSink?.success(payload) }
    }

    private fun startClassicDiscovery() {
        val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            emitClassicEvent("Bluetooth está desligado — ligue e tente de novo.")
            return
        }

        stopClassicDiscovery()

        classicDiscoveryReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                        val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE)
                        if (device != null) {
                            try {
                                emitClassicEvent(
                                    "🔎 Clássico: '${device.name ?: "N/A"}' | MAC: ${device.address} | RSSI: $rssi",
                                    mapOf("name" to device.name, "mac" to device.address, "rssi" to rssi.toInt())
                                )
                            } catch (e: SecurityException) {
                                emitClassicEvent("Permissão negada ao ler nome do dispositivo: ${e.message}")
                            }
                        }
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                        emitClassicEvent("=== Busca clássica finalizada ===")
                    }
                }
            }
        }
        registerReceiver(classicDiscoveryReceiver, IntentFilter(BluetoothDevice.ACTION_FOUND))
        registerReceiver(classicDiscoveryReceiver, IntentFilter(BluetoothAdapter.ACTION_DISCOVERY_FINISHED))

        try {
            adapter.startDiscovery()
            emitClassicEvent("=== Busca clássica (SPP) iniciada ===")
        } catch (e: SecurityException) {
            emitClassicEvent("Permissão BLUETOOTH_SCAN negada: ${e.message}")
        }
    }

    private fun stopClassicDiscovery() {
        try {
            val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
            bluetoothManager.adapter?.cancelDiscovery()
        } catch (e: SecurityException) {
            // ignora — sem permissão para cancelar, mas também não tinha pra iniciar
        }
        classicDiscoveryReceiver?.let {
            try { unregisterReceiver(it) } catch (e: IllegalArgumentException) { /* já desregistrado */ }
        }
        classicDiscoveryReceiver = null
    }

    private fun connectClassic(macAddress: String) {
        val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            emitClassicEvent("Bluetooth está desligado.")
            return
        }

        disconnectClassic()

        classicConnectThread = Thread {
            try {
                adapter.cancelDiscovery()
                val device = adapter.getRemoteDevice(macAddress)

                var socket: BluetoothSocket? = null
                var connected = false
                var usedLabel = ""

                // Tentativa 1: UUID CUSTOMIZADO descoberto no SDP real da aranha
                // (canal 1 — provável canal de controle de verdade).
                emitClassicEvent("Abrindo RFCOMM via UUID customizado (canal 1 provável) com $macAddress...")
                try {
                    socket = device.createInsecureRfcommSocketToServiceRecord(SPIDER_CUSTOM_UUID)
                    classicSocket = socket
                    socket.connect()
                    connected = true
                    usedLabel = "UUID customizado (decafade/decadeaf/decacaff)"
                } catch (e: IOException) {
                    emitClassicEvent("⚠️ UUID customizado falhou (${e.message}). Tentando SPP padrão (canal 2)...")
                    try { socket?.close() } catch (e2: IOException) {}
                    classicSocket = null
                }

                // Tentativa 2: SPP padrão (canal 2 — genérico, já testamos sem sucesso,
                // mas mantido como fallback caso o UUID customizado não resolva).
                if (!connected) {
                    try {
                        socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                        classicSocket = socket
                        socket.connect()
                        connected = true
                        usedLabel = "SPP padrão (0x1101)"
                    } catch (e: IOException) {
                        emitClassicEvent(
                            "⚠️ SDP/UUID padrão falhou (${e.message}) — tentando canais RFCOMM diretos (bypass de SDP)..."
                        )
                        try { socket?.close() } catch (e2: IOException) {}
                        classicSocket = null
                    }
                }

                // Tentativa 3 (fallback final): abre o canal RFCOMM diretamente por número,
                // sem consultar SDP — comum em módulos SPP baratos com SDP quebrado.
                if (!connected) {
                    for (channel in 1..5) {
                        try {
                            emitClassicEvent("Tentando canal RFCOMM direto #$channel (sem SDP)...")
                            val m = device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                            val directSocket = m.invoke(device, channel) as BluetoothSocket
                            classicSocket = directSocket
                            directSocket.connect()
                            socket = directSocket
                            connected = true
                            usedLabel = "Canal direto #$channel (bypass SDP)"
                            emitClassicEvent("✅ Canal #$channel respondeu!")
                            break
                        } catch (e: Exception) {
                            emitClassicEvent("Canal #$channel falhou: ${e.cause?.message ?: e.message}")
                            try { classicSocket?.close() } catch (e2: IOException) {}
                            classicSocket = null
                        }
                    }
                }

                if (connected && socket != null) {
                    emitClassicEvent(
                        "✅ CONECTADO via '$usedLabel' -> ${device.name ?: "N/A"} ($macAddress)",
                        mapOf("mac" to macAddress, "name" to device.name, "via" to usedLabel)
                    )
                    startClassicReadLoop(socket)
                    startClassicWriteLoop(socket)
                } else {
                    emitClassicEvent("❌ Falha ao conectar em todas as tentativas (UUID custom + SPP + canais 1-5).")
                }
            } catch (e: SecurityException) {
                emitClassicEvent("Permissão BLUETOOTH_CONNECT negada: ${e.message}")
            }
        }
        classicConnectThread?.start()
    }

    /// Lista dispositivos já pareados (bond state = BONDED) — não depende de
    /// descoberta nova, que às vezes não acha a aranha mesmo ligada (alguns
    /// stacks filtram dispositivos já pareados dos resultados de inquiry).
    private fun listBondedDevices() {
        val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            emitClassicEvent("Bluetooth está desligado.")
            return
        }
        try {
            val bonded = adapter.bondedDevices
            if (bonded.isEmpty()) {
                emitClassicEvent("Nenhum dispositivo pareado encontrado.")
                return
            }
            for (device in bonded) {
                val bondStateStr = when (device.bondState) {
                    BluetoothDevice.BOND_BONDED -> "BONDED"
                    BluetoothDevice.BOND_BONDING -> "BONDING"
                    else -> "NONE"
                }
                emitClassicEvent(
                    "🔗 Pareado: '${device.name ?: "N/A"}' | MAC: ${device.address} | Estado: $bondStateStr",
                    mapOf("name" to device.name, "mac" to device.address, "bonded" to true)
                )
            }
        } catch (e: SecurityException) {
            emitClassicEvent("Permissão BLUETOOTH_CONNECT negada ao listar pareados: ${e.message}")
        }
    }

    /// Confirma o estado real da conexão socket-a-socket (não só o que o app
    /// Dart acha que está conectado) — checa se o socket ainda está aberto
    /// de verdade e reporta.
    private fun checkClassicConnectionStatus() {
        val socket = classicSocket
        if (socket == null) {
            emitClassicEvent("🔴 Status: NÃO conectado (nenhum socket ativo).")
            return
        }
        val stillConnected = try { socket.isConnected } catch (e: Exception) { false }
        if (stillConnected) {
            emitClassicEvent(
                "🟢 Status: CONECTADO de verdade (socket ativo) -> ${socket.remoteDevice?.address ?: "?"}"
            )
        } else {
            emitClassicEvent("🔴 Status: socket existe mas NÃO está mais conectado.")
        }
    }

    private fun startClassicReadLoop(socket: BluetoothSocket) {
        classicReadThread = Thread {
            val buffer = ByteArray(1024)
            val input = try { socket.inputStream } catch (e: IOException) {
                emitClassicEvent("Erro ao abrir inputStream: ${e.message}")
                return@Thread
            }
            while (classicSocket == socket) {
                try {
                    val bytesRead = input.read(buffer)
                    if (bytesRead > 0) {
                        val hex = buffer.copyOfRange(0, bytesRead).joinToString(" ") { String.format("%02X", it) }
                        emitClassicEvent("⬅️ Recebido ($bytesRead bytes): $hex", mapOf("bytesHex" to hex))
                    }
                } catch (e: IOException) {
                    handleClassicSocketLost(socket, "leitura encerrada: ${e.message}")
                    break
                }
            }
        }
        classicReadThread?.start()
    }

    /// Converte o argumento "bytes" vindo do MethodChannel pra ByteArray,
    /// aceitando tanto List<Int> (literais Dart tipo [0x01, 0x02]) quanto
    /// ByteArray (quando o Dart manda um Uint8List — ex: bytes crus vindos
    /// direto de uma notificação BLE via flutter_blue_plus — nesse caso o
    /// codec padrão do Flutter serializa como byte[] nativo, não como List,
    /// e um cast direto pra List<Int> quebra com ClassCastException).
    private fun argToByteArray(arg: Any?): ByteArray {
        return when (arg) {
            is ByteArray -> arg
            is List<*> -> ByteArray(arg.size) { i -> (arg[i] as Number).toByte() }
            else -> ByteArray(0)
        }
    }

    /// Evita reportar a mesma perda de conexão duas vezes (leitura e escrita
    /// podem detectar o mesmo socket morto quase ao mesmo tempo).
    private fun handleClassicSocketLost(socket: BluetoothSocket, reason: String) {
        if (classicSocket != socket) return // já tratado por outra thread/reconexão
        classicSocket = null
        classicWriteThreadRunning = false
        classicWriteQueue.clear()
        try { socket.close() } catch (e: IOException) {}
        // "Desconectado" é uma das strings que o lado Dart usa pra virar
        // isConnected = false — sem isso a tela ficava mostrando "Conectado"
        // enquanto o envio já tinha morrido silenciosamente por dentro.
        emitClassicEvent("Desconectado do SPP clássico ($reason).")
    }

    private var _lastClassicWriteErrorLogAt = 0L

    private fun startClassicWriteLoop(socket: BluetoothSocket) {
        classicWriteQueue.clear()
        classicWriteThreadRunning = true
        classicWriteThread = Thread {
            while (classicWriteThreadRunning && classicSocket == socket) {
                val bytes = try {
                    classicWriteQueue.poll(500, java.util.concurrent.TimeUnit.MILLISECONDS)
                } catch (e: InterruptedException) {
                    break
                } ?: continue

                try {
                    socket.outputStream.write(bytes)
                    val hex = bytes.joinToString(" ") { String.format("%02X", it) }
                    emitClassicEvent(
                        "➡️ Enviado (${bytes.size} bytes): $hex",
                        mapOf("bytesHex" to hex, "sent" to true)
                    )
                } catch (e: IOException) {
                    // socket.isConnected reflete o estado real do socket (mesma
                    // checagem usada em checkClassicConnectionStatus()). Só
                    // tratamos como fatal se o socket realmente morreu — uma
                    // falha pontual (buffer momentaneamente cheio etc.) não pode
                    // matar o relay inteiro pro resto da sessão, senão a aranha
                    // para de se mover silenciosamente enquanto a tela ainda
                    // mostra "Conectado" (foi exatamente esse o bug: antes,
                    // cada write era uma chamada independente que se
                    // recuperava sozinha na próxima tentativa; agora que é um
                    // loop persistente, um único erro não pode ser fatal).
                    val stillConnected = try { socket.isConnected } catch (e2: Exception) { false }
                    if (!stillConnected) {
                        handleClassicSocketLost(socket, "falha ao enviar: ${e.message}")
                        break
                    }
                    val now = System.currentTimeMillis()
                    if (now - _lastClassicWriteErrorLogAt > 2000) {
                        _lastClassicWriteErrorLogAt = now
                        emitClassicEvent("⚠️ Falha pontual ao enviar via SPP, seguindo: ${e.message}")
                    }
                }
            }
        }
        classicWriteThread?.start()
    }

    private fun stopClassicWriteLoop() {
        classicWriteThreadRunning = false
        classicWriteQueue.clear()
        classicWriteThread?.interrupt()
        classicWriteThread = null
    }

    /// Só ENFILEIRA os bytes — quem escreve de fato é a classicWriteThread.
    /// Isso é chamado pelo handler do MethodChannel (UI thread); um
    /// socket.outputStream.write() síncrono direto aqui travava o app a
    /// cada pacote retransmitido da tiara (ver classicWriteQueue acima).
    /// Fila cheia = descarta o mais antigo: pro controle de movimento em
    /// tempo real, o pacote mais recente é o que importa.
    private fun sendClassicBytes(bytes: ByteArray) {
        if (classicSocket == null) {
            emitClassicEvent("Sem conexão SPP ativa — conecte primeiro.")
            return
        }
        if (!classicWriteQueue.offer(bytes)) {
            classicWriteQueue.poll()
            classicWriteQueue.offer(bytes)
        }
    }

    private fun disconnectClassic() {
        val socket = classicSocket
        classicSocket = null
        stopClassicWriteLoop()
        try { socket?.close() } catch (e: IOException) {}
        if (socket != null) {
            emitClassicEvent("Desconectado do SPP clássico.")
        }
    }
    // ==========================================================
    // FIM DA CONEXÃO CLÁSSICA (SPP/RFCOMM)
    // ==========================================================

    // ==========================================================
    // CANAL "OFICIAL" — ENVIO VIA com.boby.bluetoothconnect.services.
    // BluetoothChatService, A MESMA CLASSE QUE O SDK USA INTERNAMENTE.
    // ==========================================================
    // LinkManager.writeToDevice(mac, texto) — o método público que o SDK
    // expõe pra mandar dado pra um dispositivo clássico conectado — por
    // baixo dos panos só faz: classicService.write(texto.getBytes(UTF_8)),
    // onde classicService é uma instância de BluetoothChatService. Só que
    // esse método está preso ao LinkManager (singleton usado pra tiara real,
    // com sua própria lista de dispositivos/scan), então não dá pra reusar
    // ele direto pra aranha sem misturar os dois fluxos.
    //
    // Em vez disso, instanciamos NOSSA PRÓPRIA BluetoothChatService — a
    // mesma classe do SDK — e chamamos os métodos públicos dela
    // (connect/write) diretamente. IMPORTANTE: olhando o bytecode dela,
    // o UUID de conexão está FIXO no UUID padrão de SPP (0x1101) — essa
    // classe não tem como saber sobre o UUID customizado do canal 1 que
    // achamos no SDP real da aranha. Ou seja, esse canal só alcança o
    // mesmo canal genérico (2) que já veio sem efeito — é útil pra
    // descartar diferenças sutis de framing/buffer da implementação
    // oficial, mas não é capaz de alcançar o canal proprietário.
    private var sdkChatService: BluetoothChatService? = null

    // ACHADO: o campo isConnected() dessa classe do SDK só vira true depois
    // que o ConnectedThread RECEBE pelo menos 1 byte do outro lado (olhando
    // o bytecode: access$702(this, true) só é chamado depois de um
    // mmInStream.read() bem-sucedido, dentro do loop de leitura — não
    // quando o socket conecta). Como o canal 2 (único que essa classe
    // alcança, UUID fixo) nunca manda nada de volta, isConnected() ficava
    // preso em false pra sempre mesmo com o socket fisicamente conectado.
    // Por isso rastreamos a conexão nós mesmos, pelo evento de mudança de
    // estado (STATE_CONNECTED = 3, confirmado batendo com "socket
    // connected" no log real de uma tentativa).
    @Volatile private var sdkConnectedFlag = false
    private var sdkConnectedDevice: BluetoothDevice? = null

    private val sdkHandler = Handler(Looper.getMainLooper()) { msg ->
        when (msg.what) {
            1 -> {
                emitClassicEvent("[SDK] Mudança de estado interna: arg1=${msg.arg1}")
                if (msg.arg1 == 3) {
                    sdkConnectedFlag = true
                    val device = sdkConnectedDevice
                    emitClassicEvent(
                        "[SDK] ✅ CONECTADO via BluetoothChatService oficial -> ${device?.name ?: "N/A"} (${device?.address})",
                        mapOf("mac" to device?.address, "name" to device?.name, "via" to "SDK")
                    )
                } else if (sdkConnectedFlag && msg.arg1 != 3) {
                    // Saiu do estado conectado (voltou pra LISTEN/NONE/CONNECTING).
                    sdkConnectedFlag = false
                    emitClassicEvent("[SDK] Desconectado do canal SDK oficial.")
                }
            }
            3 -> {
                val bytes = msg.obj as? ByteArray
                val hex = bytes?.joinToString(" ") { String.format("%02X", it) } ?: ""
                emitClassicEvent("[SDK] ➡️ Enviado via BluetoothChatService oficial (${bytes?.size ?: 0} bytes): $hex")
            }
            else -> {}
        }
        true
    }

    private fun connectClassicViaSdk(macAddress: String) {
        val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            emitClassicEvent("[SDK] Bluetooth está desligado.")
            return
        }
        try {
            disconnectClassicSdk()
            val device = adapter.getRemoteDevice(macAddress)
            sdkConnectedDevice = device
            val service = BluetoothChatService(this, sdkHandler)
            service.bytesListener = OnReceiveBytesListener { bytes, len, mac ->
                val hex = bytes.copyOfRange(0, len).joinToString(" ") { String.format("%02X", it) }
                emitClassicEvent("[SDK] ⬅️ Recebido de $mac ($len bytes): $hex")
            }
            sdkChatService = service
            emitClassicEvent(
                "[SDK] Conectando via BluetoothChatService oficial (insecure, UUID SPP padrão) a $macAddress..."
            )
            service.connect(device, false) // false = insecure, igual o SDK usa pra tiara
            // Sucesso/falha agora são reportados pelo próprio sdkHandler
            // (evento de mudança de estado), não por polling de isConnected().
        } catch (e: SecurityException) {
            emitClassicEvent("[SDK] Permissão negada: ${e.message}")
        }
    }

    private fun sendClassicViaSdk(bytes: ByteArray) {
        val service = sdkChatService
        if (service == null || !sdkConnectedFlag) {
            emitClassicEvent("[SDK] Sem conexão via SDK ativa — conecte via SDK primeiro.")
            return
        }
        service.write(bytes)
    }

    private fun disconnectClassicSdk() {
        val had = sdkChatService != null
        sdkChatService?.stop()
        sdkChatService = null
        sdkConnectedFlag = false
        sdkConnectedDevice = null
        if (had) emitClassicEvent("[SDK] Desconectado do canal SDK oficial.")
    }
    // ==========================================================
    // FIM DO CANAL "OFICIAL" (SDK)
    // ==========================================================

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- Canais da conexão clássica (SPP/RFCOMM) com a aranha ---
        val spiderClassicMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPIDER_CLASSIC_METHOD_CHANNEL)
        spiderClassicMethodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startDiscovery" -> {
                    startClassicDiscovery()
                    result.success(true)
                }
                "stopDiscovery" -> {
                    stopClassicDiscovery()
                    result.success(true)
                }
                "connect" -> {
                    val macAddress = call.argument<String>("macAddress")
                    if (macAddress == null) {
                        result.error("MISSING_MAC", "macAddress é obrigatório", null)
                    } else {
                        connectClassic(macAddress)
                        result.success(true)
                    }
                }
                "sendString" -> {
                    val text = call.argument<String>("text") ?: ""
                    sendClassicBytes(text.toByteArray(Charsets.UTF_8))
                    result.success(true)
                }
                "sendHex" -> {
                    sendClassicBytes(argToByteArray(call.argument<Any>("bytes")))
                    result.success(true)
                }
                "disconnect" -> {
                    disconnectClassic()
                    result.success(true)
                }
                "listBonded" -> {
                    listBondedDevices()
                    result.success(true)
                }
                "checkStatus" -> {
                    checkClassicConnectionStatus()
                    result.success(true)
                }
                "connectSdk" -> {
                    val macAddress = call.argument<String>("macAddress")
                    if (macAddress == null) {
                        result.error("MISSING_MAC", "macAddress é obrigatório", null)
                    } else {
                        connectClassicViaSdk(macAddress)
                        result.success(true)
                    }
                }
                "sendSdkHex" -> {
                    sendClassicViaSdk(argToByteArray(call.argument<Any>("bytes")))
                    result.success(true)
                }
                "disconnectSdk" -> {
                    disconnectClassicSdk()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SPIDER_CLASSIC_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { spiderClassicEventSink = events }
                override fun onCancel(arguments: Any?) { spiderClassicEventSink = null }
            }
        )
    }

    override fun onDestroy() {
        stopClassicDiscovery()
        disconnectClassic()
        disconnectClassicSdk()
        super.onDestroy()
    }
}