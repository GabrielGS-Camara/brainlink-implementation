package com.example.brainlink // Mantenha o seu pacote

import android.bluetooth.*
import android.bluetooth.le.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.boby.bluetoothconnect.LinkManager
import com.boby.bluetoothconnect.bean.BrainWave
import com.boby.bluetoothconnect.bean.Gravity
import com.boby.bluetoothconnect.classic.bean.BlueConnectDevice
import com.boby.bluetoothconnect.classic.listener.EEGPowerDataListener
import com.boby.bluetoothconnect.classic.listener.OnConnectListener
import com.boby.bluetoothconnect.callback.ScanCallBack
import com.boby.bluetoothconnect.classic.listener.OnReceiveBytesListener
import com.boby.bluetoothconnect.services.BluetoothChatService
import com.boby.bluetoothconnect.utill.DistractedUtill // Classe de distração
import java.io.IOException
import java.util.ArrayList
import java.util.UUID

class MainActivity: FlutterActivity() {
    private val METHOD_CHANNEL = "brainlink_channel"
    private val SCAN_EVENT_CHANNEL = "brainlink_scan_channel"
    private val DATA_EVENT_CHANNEL = "brainlink_data_channel"

    // --- Canais do emulador da tiara ---
    private val TIARA_EMULATOR_METHOD_CHANNEL = "tiara_emulator_channel"
    private val TIARA_EMULATOR_EVENT_CHANNEL = "tiara_emulator_events"

    // --- Canais da conexão CLÁSSICA (SPP/RFCOMM) com a aranha ---
    private val SPIDER_CLASSIC_METHOD_CHANNEL = "spider_classic_channel"
    private val SPIDER_CLASSIC_EVENT_CHANNEL = "spider_classic_events"

    private var scanEventSink: EventChannel.EventSink? = null
    private var dataEventSink: EventChannel.EventSink? = null
    private var tiaraEmulatorEventSink: EventChannel.EventSink? = null
    private var spiderClassicEventSink: EventChannel.EventSink? = null
    private var methodChannel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val foundDevicesMap = mutableMapOf<String, BlueConnectDevice>()

    // Utilitário de Distração
    private val distractedUtill = DistractedUtill()

    private var currentGravityX = 0
    private var currentGravityY = 0
    private var currentGravityZ = 0
    private var lastBlinkStrength = 0

    // ==========================================================
    // EMULADOR DA TIARA (GATT SERVER + ADVERTISING)
    // ==========================================================
    // UUIDs extraídos de UUIDUtils.class dentro do
    // MacrotellectLink_V1_4_3.jar (WRITE_SERVICE_UUID / WRITE_CHAR_UUID).
    // Padrão comum de canal serial BLE (estilo Nordic UART):
    //   6e400001 = serviço
    //   6e400002 = característica de escrita (RX do ponto de vista do server)
    //   6e400003 = característica de notificação (TX do ponto de vista do server)
    private val TIARA_SERVICE_UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    private val TIARA_WRITE_CHAR_UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    private val TIARA_NOTIFY_CHAR_UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
    private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private var bluetoothGattServer: BluetoothGattServer? = null
    private var bleAdvertiser: BluetoothLeAdvertiser? = null
    private var notifyCharacteristic: BluetoothGattCharacteristic? = null
    private val subscribedDevices = mutableSetOf<BluetoothDevice>()
    private var originalAdapterName: String? = null

    private var mockDataHandler: Handler? = null
    private var mockDataRunnable: Runnable? = null
    private var mockStartTime = 0L

    private fun emitEmulatorEvent(message: String, extra: Map<String, Any?> = emptyMap()) {
        val payload = mutableMapOf<String, Any?>("message" to message)
        payload.putAll(extra)
        mainHandler.post { tiaraEmulatorEventSink?.success(payload) }
    }

    private fun startTiaraEmulation() {
        val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            emitEmulatorEvent("Bluetooth está desligado — ligue e tente de novo.")
            return
        }

        bleAdvertiser = adapter.bluetoothLeAdvertiser
        if (bleAdvertiser == null) {
            emitEmulatorEvent("Este aparelho não suporta advertising BLE (papel de periférico).")
            return
        }

        try {
            // GATT Server — o "servidor" que a aranha (se ela conectar como
            // central) enxergaria como se fosse a tiara real.
            bluetoothGattServer = bluetoothManager.openGattServer(this, gattServerCallback)
            val service = BluetoothGattService(TIARA_SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

            val writeChar = BluetoothGattCharacteristic(
                TIARA_WRITE_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )

            val notifyChar = BluetoothGattCharacteristic(
                TIARA_NOTIFY_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            val cccDescriptor = BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
            )
            notifyChar.addDescriptor(cccDescriptor)
            notifyCharacteristic = notifyChar

            service.addCharacteristic(writeChar)
            service.addCharacteristic(notifyChar)
            bluetoothGattServer?.addService(service)

            // Anuncia com o MESMO NOME da tiara real ("BrainLink_Pro").
            // Isso muda o nome Bluetooth do sistema temporariamente — guardamos
            // o original para restaurar em stopTiaraEmulation().
            originalAdapterName = adapter.name
            adapter.name = "BrainLink_Pro"

            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .build()

            // O pacote de advertising BLE tem limite de 31 bytes. Nome +
            // UUID de serviço de 128 bits juntos passam disso (erro
            // ADVERTISE_FAILED_DATA_TOO_LARGE, código 1) — por isso
            // dividimos em dois pacotes: o UUID vai no advertising
            // principal, o nome vai no scan response (o scanner lê os
            // dois automaticamente, incluindo nRF Connect).
            val advertiseData = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(ParcelUuid(TIARA_SERVICE_UUID))
                .build()

            val scanResponseData = AdvertiseData.Builder()
                .setIncludeDeviceName(true)
                .build()

            bleAdvertiser?.startAdvertising(settings, advertiseData, scanResponseData, advertiseCallback)
            emitEmulatorEvent(
                "📡 Advertising solicitado como 'BrainLink_Pro' | Serviço: $TIARA_SERVICE_UUID"
            )

            subscribedDevices.clear()
            startMockDataLoop()
        } catch (e: SecurityException) {
            emitEmulatorEvent("Permissão negada pelo Android ao tentar anunciar/abrir GATT server: ${e.message}")
        } catch (e: Exception) {
            emitEmulatorEvent("Erro ao iniciar emulação: ${e.message}")
        }
    }

    private fun stopTiaraEmulation() {
        try {
            mockDataRunnable?.let { mockDataHandler?.removeCallbacks(it) }
            mockDataRunnable = null

            bleAdvertiser?.stopAdvertising(advertiseCallback)
            bluetoothGattServer?.close()
            bluetoothGattServer = null
            subscribedDevices.clear()

            // Restaura o nome Bluetooth original do aparelho.
            originalAdapterName?.let { original ->
                val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
                bluetoothManager.adapter?.name = original
            }
            originalAdapterName = null

            emitEmulatorEvent("=== Advertising e GATT server parados ===")
        } catch (e: Exception) {
            emitEmulatorEvent("Erro ao parar emulação: ${e.message}")
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            emitEmulatorEvent("✅ Advertising confirmado pelo sistema Android.")
        }
        override fun onStartFailure(errorCode: Int) {
            // 1=DATA_TOO_LARGE 2=TOO_MANY_ADVERTISERS 3=ALREADY_STARTED
            // 4=INTERNAL_ERROR 5=FEATURE_UNSUPPORTED
            emitEmulatorEvent("❌ Falha ao iniciar advertising. Código: $errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
            if (device == null) return
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                emitEmulatorEvent(
                    "🔌 DISPOSITIVO CONECTOU -> MAC: ${device.address} | Nome: ${device.name ?: "N/A"}",
                    mapOf("mac" to device.address, "name" to device.name)
                )
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribedDevices.remove(device)
                emitEmulatorEvent(
                    "❌ DISPOSITIVO DESCONECTOU -> MAC: ${device.address}",
                    mapOf("mac" to device.address)
                )
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice?, requestId: Int, characteristic: BluetoothGattCharacteristic?,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?
        ) {
            if (device != null && characteristic != null) {
                val hex = value?.joinToString(" ") { String.format("%02X", it) } ?: ""
                emitEmulatorEvent(
                    "✍️ ESCRITA de ${device.address} na char ${characteristic.uuid} -> [$hex]",
                    mapOf("mac" to device.address, "charUuid" to characteristic.uuid.toString(), "bytesHex" to hex)
                )
            }
            if (responseNeeded) {
                bluetoothGattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice?, requestId: Int, descriptor: BluetoothGattDescriptor?,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?
        ) {
            if (device != null && descriptor?.uuid == CCCD_UUID) {
                if (value != null && value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                    subscribedDevices.add(device)
                    emitEmulatorEvent("🔔 ${device.address} se inscreveu para notificações (como o app oficial faria).")
                } else {
                    subscribedDevices.remove(device)
                    emitEmulatorEvent("🔕 ${device.address} cancelou a inscrição.")
                }
            }
            if (responseNeeded) {
                bluetoothGattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice?, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic?
        ) {
            if (device != null) {
                emitEmulatorEvent("👁️ LEITURA de ${device.address} na char ${characteristic?.uuid}")
            }
            bluetoothGattServer?.sendResponse(
                device, requestId, BluetoothGatt.GATT_SUCCESS, offset,
                characteristic?.value ?: ByteArray(0)
            )
        }
    }

    /// Manda "atenção" mockada em rampa triangular (0 -> 100 -> 0) a cada
    /// ciclo de ~20s, repetindo indefinidamente até stopTiaraEmulation().
    /// Repetir é intencional — o pedido foi "mesmo que o mesmo repetidamente",
    /// e assim cobrimos o caso da aranha conectar bem depois do início.
    private fun startMockDataLoop() {
        mockStartTime = System.currentTimeMillis()
        mockDataHandler = Handler(Looper.getMainLooper())
        mockDataRunnable = object : Runnable {
            override fun run() {
                val elapsedMs = System.currentTimeMillis() - mockStartTime
                val cyclePos = elapsedMs % 20000L // ciclo de 20s
                val progress = cyclePos.toFloat() / 20000f

                // Sobe 0->100 na primeira metade, desce 100->0 na segunda.
                val attention = if (progress < 0.5f) {
                    (progress * 2 * 100).toInt()
                } else {
                    ((1 - progress) * 2 * 100).toInt()
                }

                val payload = byteArrayOf(attention.toByte())
                notifyCharacteristic?.value = payload

                if (subscribedDevices.isNotEmpty()) {
                    for (dev in subscribedDevices) {
                        bluetoothGattServer?.notifyCharacteristicChanged(dev, notifyCharacteristic, false)
                    }
                    emitEmulatorEvent("🎭 Atenção mockada: $attention -> enviada para ${subscribedDevices.size} dispositivo(s)")
                } else {
                    emitEmulatorEvent("🎭 Atenção mockada: $attention (ninguém inscrito ainda)")
                }

                mockDataHandler?.postDelayed(this, 500)
            }
        }
        mockDataHandler?.post(mockDataRunnable!!)
    }
    // ==========================================================
    // FIM DO EMULADOR DA TIARA
    // ==========================================================

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
                    if (classicSocket == socket) {
                        emitClassicEvent("Conexão SPP encerrada: ${e.message}")
                    }
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

    private fun sendClassicBytes(bytes: ByteArray) {
        val socket = classicSocket
        if (socket == null) {
            emitClassicEvent("Sem conexão SPP ativa — conecte primeiro.")
            return
        }
        try {
            socket.outputStream.write(bytes)
            val hex = bytes.joinToString(" ") { String.format("%02X", it) }
            emitClassicEvent("➡️ Enviado (${bytes.size} bytes): $hex")
        } catch (e: IOException) {
            emitClassicEvent("Erro ao enviar via SPP: ${e.message}")
        }
    }

    private fun disconnectClassic() {
        val socket = classicSocket
        classicSocket = null
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

    private val myEegListener = object : EEGPowerDataListener {
        override fun onGravity(mac: String?, gravity: Gravity?) {
            if (gravity != null) {
                currentGravityX = gravity.X
                currentGravityY = gravity.Y
                currentGravityZ = gravity.Z
            }
        }

        override fun onRawData(mac: String?, raw: Int) {
            val blinkValue = com.boby.bluetoothconnect.ble.utils.EyesUtil.eyesDate(raw)
            if (blinkValue != -1) {
                lastBlinkStrength = blinkValue
            }
        }

        override fun onBrainWavedata(mac: String?, wave: BrainWave?) {
            if (wave == null || dataEventSink == null) return

            // Avalia distração via classe proprietária
            val isDistracted = distractedUtill.add(wave.att)

            val data = mapOf(
                "attention" to wave.att, "meditation" to wave.med, "signal" to wave.signal,
                "delta" to wave.delta, "theta" to wave.theta,
                "lowAlpha" to wave.lowAlpha, "highAlpha" to wave.highAlpha,
                "lowBeta" to wave.lowBeta, "highBeta" to wave.highBeta,
                "lowGamma" to wave.lowGamma, "middleGamma" to wave.middleGamma,
                "battery" to wave.batteryCapacity,
                "gravityX" to currentGravityX,
                "gravityY" to currentGravityY,
                "gravityZ" to currentGravityZ,
                "blink" to lastBlinkStrength,
                "heartRate" to wave.heartRate,
                "grind" to wave.grind,
                "isDistracted" to isDistracted
            )
            mainHandler.post { dataEventSink?.success(data) }

            if (lastBlinkStrength > 0) {
                lastBlinkStrength = 0
            }
        }

        override fun onRR(mac: String?, rr: ArrayList<Int>?, param: Int) {}
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LinkManager.init(this)
        LinkManager.getInstance().setMultiEEGPowerDataListener(myEegListener)

        // Trava de segurança no SDK
        try {
            val parser3Field = LinkManager::class.java.getDeclaredField("parser3")
            parser3Field.isAccessible = true
            val parser3Obj = parser3Field.get(LinkManager.getInstance())

            val setListenerMethod = parser3Obj.javaClass.getDeclaredMethod("setEEGPowerDataListener", EEGPowerDataListener::class.java)
            setListenerMethod.isAccessible = true
            setListenerMethod.invoke(parser3Obj, myEegListener)
        } catch (e: Exception) {
            e.printStackTrace()
        }

        LinkManager.getInstance().setOnConnectListener(object : OnConnectListener {
            override fun onConnectStart(device: BlueConnectDevice?) {}
            override fun onConnectting(device: BlueConnectDevice?) {}
            override fun onConnectSuccess(device: BlueConnectDevice?) {
                LinkManager.getInstance().setDataType(5) // Giroscópio + Grind
            }
            override fun onConnectionLost(device: BlueConnectDevice?) {
                mainHandler.post { methodChannel?.invokeMethod("onConnectionLost", null) }
            }
            override fun onConnectFailed(device: BlueConnectDevice?) {}
            override fun onError(e: Exception?) {}
        })

        LinkManager.getInstance().setScanCallBack(object : ScanCallBack {
            override fun onScaningDeviceFound(device: BlueConnectDevice?) {
                if (device != null && device.address != null) {
                    foundDevicesMap[device.address] = device
                    mainHandler.post {
                        scanEventSink?.success(mapOf("name" to (device.name ?: "Desconhecido"), "mac" to device.address))
                    }
                }
            }
            override fun onScanFinish() {}
        })
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startScan" -> {
                    foundDevicesMap.clear()
                    LinkManager.getInstance().startScan()
                    result.success(true)
                }
                "connect" -> {
                    val macAddress = call.argument<String>("macAddress")
                    val deviceToConnect = foundDevicesMap[macAddress]
                    if (deviceToConnect != null) {
                        LinkManager.getInstance().stopScan()
                        LinkManager.getInstance().connectDevice(deviceToConnect)
                        result.success(true)
                    } else {
                        result.error("DEVICE_NOT_FOUND", "Dispositivo não encontrado", null)
                    }
                }
                "disconnect" -> {
                    LinkManager.getInstance().close()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SCAN_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { scanEventSink = events }
                override fun onCancel(arguments: Any?) { scanEventSink = null }
            }
        )

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DATA_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { dataEventSink = events }
                override fun onCancel(arguments: Any?) { dataEventSink = null }
            }
        )

        // --- Canais do emulador da tiara ---
        val tiaraEmulatorMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TIARA_EMULATOR_METHOD_CHANNEL)
        tiaraEmulatorMethodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startEmulation" -> {
                    startTiaraEmulation()
                    result.success(true)
                }
                "stopEmulation" -> {
                    stopTiaraEmulation()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, TIARA_EMULATOR_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { tiaraEmulatorEventSink = events }
                override fun onCancel(arguments: Any?) { tiaraEmulatorEventSink = null }
            }
        )

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
        stopTiaraEmulation()
        stopClassicDiscovery()
        disconnectClassic()
        disconnectClassicSdk()
        super.onDestroy()
    }
}