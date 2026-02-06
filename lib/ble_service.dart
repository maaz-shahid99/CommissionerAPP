import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';

class CommissionedDevice {
  final String eui64;
  final DateTime timestamp;
  final bool success;

  CommissionedDevice({
    required this.eui64,
    required this.timestamp,
    required this.success,
  });

  Map<String, dynamic> toJson() => {
    'eui64': eui64,
    'timestamp': timestamp.toIso8601String(),
    'success': success,
  };

  factory CommissionedDevice.fromJson(Map<String, dynamic> json) {
    return CommissionedDevice(
      eui64: json['eui64'],
      timestamp: DateTime.parse(json['timestamp']),
      success: json['success'],
    );
  }
}

class BLEService extends ChangeNotifier {
  // Constants
  static const String serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const String charUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
  static const String defaultSecretKey = 'PROD_SECRET_KEY_CHANGE_ME';
  static const String secureStorageKey = 'hmac_secret_key';

  // Retry configuration
  static const int maxRetries = 3;
  static const Duration retryDelay = Duration(seconds: 2);
  static const Duration scanTimeout = Duration(seconds: 30);
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration writeTimeout = Duration(seconds: 10);

  // State
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _targetCharacteristic;
  bool _isScanning = false;
  bool _isConnected = false;
  int _rssi = 0;
  String _deviceName = 'Unknown';
  final List<String> _logs = [];
  final List<CommissionedDevice> _commissionHistory = [];
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  StreamSubscription? _scanSubscription;
  StreamSubscription? _connectionSubscription;
  Timer? _connectionTimer;
  bool _autoReconnect = true;

  // Getters
  bool get isScanning => _isScanning;
  bool get isConnected => _isConnected;
  int get rssi => _rssi;
  String get deviceName => _deviceName;
  List<String> get logs => List.unmodifiable(_logs);
  List<CommissionedDevice> get commissionHistory => List.unmodifiable(_commissionHistory);
  bool get autoReconnect => _autoReconnect;

  BLEService() {
    _initializeSecretKey();
    _startConnectionMonitoring();
  }

  Future<void> _initializeSecretKey() async {
    try {
      final existingKey = await _secureStorage.read(key: secureStorageKey);
      if (existingKey == null) {
        await _secureStorage.write(key: secureStorageKey, value: defaultSecretKey);
        _addLog('Initialized secure secret key');
      } else {
        _addLog('Loaded existing secret key from secure storage');
      }
    } catch (e) {
      _addLog('Error initializing secret key: $e', isError: true);
    }
  }

  Future<String> _getSecretKey() async {
    try {
      final key = await _secureStorage.read(key: secureStorageKey);
      return key ?? defaultSecretKey;
    } catch (e) {
      _addLog('Error reading secret key, using default: $e', isError: true);
      return defaultSecretKey;
    }
  }

  Future<void> updateSecretKey(String newKey) async {
    try {
      await _secureStorage.write(key: secureStorageKey, value: newKey);
      _addLog('Secret key updated successfully');
    } catch (e) {
      _addLog('Error updating secret key: $e', isError: true);
    }
  }

  void setAutoReconnect(bool value) {
    _autoReconnect = value;
    _addLog('Auto-reconnect ${value ? 'enabled' : 'disabled'}');
    notifyListeners();
  }

  void _addLog(String message, {bool isError = false}) {
    final timestamp = DateFormat('HH:mm:ss.SSS').format(DateTime.now());
    final prefix = isError ? '❌' : '✓';
    _logs.add('[$timestamp] $prefix $message');
    if (_logs.length > 500) {
      _logs.removeAt(0);
    }
    notifyListeners();
  }

  void _addCommissionedDevice(String eui64, bool success) {
    _commissionHistory.add(CommissionedDevice(
      eui64: eui64,
      timestamp: DateTime.now(),
      success: success,
    ));
    notifyListeners();
  }

  void _startConnectionMonitoring() {
    _connectionTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (_connectedDevice != null && _autoReconnect) {
        try {
          final state = await _connectedDevice!.connectionState.first.timeout(
            const Duration(seconds: 2),
          );
          if (state != BluetoothConnectionState.connected && !_isScanning) {
            _addLog('Connection lost, attempting reconnect...');
            await reconnect();
          }
        } catch (e) {
          _addLog('Connection check failed: $e', isError: true);
        }
      }
    });
  }

  Future<void> startScan() async {
    if (_isScanning) {
      _addLog('Scan already in progress');
      return;
    }

    try {
      _isScanning = true;
      _addLog('Starting BLE scan for Bridge ESP...');
      notifyListeners();

      await FlutterBluePlus.startScan(
        withServices: [Guid(serviceUuid)],
        timeout: scanTimeout,
      );

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult result in results) {
          if (result.device.platformName.isNotEmpty) {
            _addLog('Found device: ${result.device.platformName} (RSSI: ${result.rssi})');
            await _connectToDevice(result.device, result.rssi);
            await stopScan();
            break;
          } else if (result.advertisementData.serviceUuids.contains(Guid(serviceUuid))) {
            _addLog('Found Bridge ESP (RSSI: ${result.rssi})');
            await _connectToDevice(result.device, result.rssi);
            await stopScan();
            break;
          }
        }
      });

      Future.delayed(scanTimeout, () async {
        if (_isScanning && !_isConnected) {
          _addLog('Scan timeout reached', isError: true);
          await stopScan();
        }
      });
    } catch (e) {
      _addLog('Scan error: $e', isError: true);
      _isScanning = false;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      _isScanning = false;
      _addLog('Scan stopped');
      notifyListeners();
    } catch (e) {
      _addLog('Error stopping scan: $e', isError: true);
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device, int rssi) async {
    try {
      _addLog('Connecting to device...');

      await device.connect(timeout: connectTimeout);

      _connectedDevice = device;
      _rssi = rssi;
      _deviceName = device.platformName.isNotEmpty ? device.platformName : 'Bridge ESP';
      _isConnected = true;

      _addLog('Connected to $_deviceName');
      notifyListeners();

      _connectionSubscription = device.connectionState.listen((state) async {
        if (state == BluetoothConnectionState.disconnected) {
          _addLog('Device disconnected');
          _handleDisconnection();
        }
      });

      await _discoverServices();
      await _updateRssi();
    } catch (e) {
      _addLog('Connection error: $e', isError: true);
      _handleDisconnection();
    }
  }

  Future<void> _discoverServices() async {
    try {
      _addLog('Discovering services...');
      final services = await _connectedDevice!.discoverServices();

      for (var service in services) {
        if (service.uuid.toString() == serviceUuid) {
          _addLog('Found target service');
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid.toString() == charUuid) {
              _targetCharacteristic = characteristic;
              _addLog('Found target characteristic');

              // Get MTU size
              final mtu = await _connectedDevice!.mtu.first;
              _addLog('MTU: $mtu bytes');

              return;
            }
          }
        }
      }

      _addLog('Target characteristic not found', isError: true);
    } catch (e) {
      _addLog('Service discovery error: $e', isError: true);
    }
  }

  Future<void> _updateRssi() async {
    if (_connectedDevice == null) return;

    try {
      final newRssi = await _connectedDevice!.readRssi();
      _rssi = newRssi;
      notifyListeners();
    } catch (e) {
      // Silently fail RSSI updates
    }
  }

  String _generateHmac(String message, String key) {
    final keyBytes = utf8.encode(key);
    final messageBytes = utf8.encode(message);
    final hmac = Hmac(sha256, keyBytes);
    final digest = hmac.convert(messageBytes);
    return digest.toString();
  }

  Future<void> commissionDevice(String eui64, String pskd) async {
    if (_targetCharacteristic == null) {
      _addLog('Not connected to device', isError: true);
      return;
    }

    final command = 'add $eui64 $pskd';
    _addLog('Preparing command: $command');

    try {
      final secretKey = await _getSecretKey();
      final signature = _generateHmac(command, secretKey);
      final signedCommand = '$command|$signature';

      _addLog('Generated HMAC signature');
      await _writeCommandWithRetry(signedCommand);

      _addCommissionedDevice(eui64, true);
      _addLog('✅ Device $eui64 commissioned successfully');
    } catch (e) {
      _addLog('Commission error: $e', isError: true);
      _addCommissionedDevice(eui64, false);
    }
  }

  Future<void> _writeCommandWithRetry(String command) async {
    int attempt = 0;

    while (attempt < maxRetries) {
      try {
        _addLog('Writing command (attempt ${attempt + 1}/$maxRetries)...');

        final commandBytes = utf8.encode(command);
        await _targetCharacteristic!.write(
          commandBytes,
          withoutResponse: false,
          timeout: writeTimeout.inSeconds,
        );

        _addLog('Command written successfully');
        return;
      } catch (e) {
        attempt++;
        if (attempt >= maxRetries) {
          throw Exception('Failed after $maxRetries attempts: $e');
        }

        _addLog('Write failed, retrying in ${retryDelay.inSeconds}s...', isError: true);
        await Future.delayed(retryDelay);
      }
    }
  }

  Future<void> sendCustomCommand(String command) async {
    if (_targetCharacteristic == null) {
      _addLog('Not connected to device', isError: true);
      return;
    }

    try {
      final secretKey = await _getSecretKey();
      final signature = _generateHmac(command, secretKey);
      final signedCommand = '$command|$signature';

      await _writeCommandWithRetry(signedCommand);
      _addLog('Custom command sent: $command');
    } catch (e) {
      _addLog('Custom command error: $e', isError: true);
    }
  }

  Future<void> reconnect() async {
    if (_connectedDevice != null) {
      _addLog('Attempting reconnection...');
      try {
        await _connectedDevice!.connect(timeout: connectTimeout);
        _isConnected = true;
        _addLog('Reconnected successfully');
        await _discoverServices();
        notifyListeners();
      } catch (e) {
        _addLog('Reconnection failed: $e', isError: true);
        _handleDisconnection();
      }
    }
  }

  void _handleDisconnection() {
    _isConnected = false;
    _targetCharacteristic = null;
    _rssi = 0;
    notifyListeners();

    if (_autoReconnect && _connectedDevice != null) {
      Future.delayed(retryDelay, () => reconnect());
    }
  }

  Future<void> disconnect() async {
    try {
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;

      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
        _addLog('Disconnected from device');
      }

      _connectedDevice = null;
      _targetCharacteristic = null;
      _isConnected = false;
      _rssi = 0;
      _deviceName = 'Unknown';
      notifyListeners();
    } catch (e) {
      _addLog('Disconnect error: $e', isError: true);
    }
  }

  void clearLogs() {
    _logs.clear();
    _addLog('Logs cleared');
    notifyListeners();
  }

  void clearHistory() {
    _commissionHistory.clear();
    _addLog('Commission history cleared');
    notifyListeners();
  }

  String exportLogs() {
    return _logs.join('\n');
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    disconnect();
    super.dispose();
  }
}