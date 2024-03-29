import 'dart:async';
import 'dart:ui';
import 'package:flutter_blue/flutter_blue.dart';
import 'fbm_connection.dart';
import 'fbm_device.dart';

enum FBMDebugLevel { error, info, event, action }

typedef bool FBMScanFilter(ScanResult result);
typedef FBMDevice FBMNewDevice(String uuid);

class FlutterBlueManager {
  static const _BLE_ACTIONS_BUSY_TIMEOUT_MS = 30000;
  static const _CONNECT_TIMEOUT_S = 10;
  static const _SCAN_RESULT_TIMEOUT_MS = 5000;
  static const CONNECT_RETRY_DELAY_MS = 2000;
  static const _TAG = "FBM";

  /// user settings
  int connectDelayMs = 1;
  int discoverServicesDelayMs = 1000;
  int discoverServicesNRetries = 5;
  int maxResultAgeMs = 3000;
  int? chunkSize;

  late StreamController<BluetoothState> _bleStateBroadcast;

  Stream<BluetoothState> get bleState => _bleStateBroadcast.stream;

  // internal
  List<FBMDebugLevel> _debugFilter = FBMDebugLevel.values;

  FlutterBlue? _ble;

  Map<String, BluetoothDevice> _bondedDevices = {};

  FlutterBlue? get ble => _ble;
  BluetoothState? _bleState;

  FlutterBlueManager._() {
    _bleStateBroadcast = StreamController.broadcast();
    _ble = FlutterBlue.instance;
    _ble!.state.listen(_bleStateChange);
    _ble!.setLogLevel(LogLevel.critical);
    _fbmStateMonitorTimer = Timer.periodic(Duration(seconds: 5), _fbmStateMonitor);
    _visibleDevicesChanges = StreamController.broadcast();
    writeReadyChangeController = StreamController.broadcast();
    _updateBonded();
    _disconnectConnectedOnPlatform();
  }

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  // VARIABLES
  // scan
  int _lastClean = DateTime.now().millisecondsSinceEpoch;
  Map<String, TimedScanResult> _scanResults = {};

  // devices
  Map<String, FBMDevice> _devices = {};

  List<FBMDevice> get devices => _devices.values.toList();

  // connection
  Map<String, FBMDevice> _autoConnect = {};
  Map<String, FBMConnection?> _connections = {};

  // state monitoring
  Timer? _fbmStateMonitorTimer;
  int _lastAdvertisementResult = DateTime.now().millisecondsSinceEpoch;

  // lock
  int? _bleActionsBusy;
  List<Completer> _bleLockQueue = [];

  // PUBLIC API
  bool get bleBusy => _bleActionsBusy != null;
  late StreamController<VisibleDeviceChange> _visibleDevicesChanges;

  Stream<VisibleDeviceChange> get visibleDevicesStream => _visibleDevicesChanges.stream;
  late StreamController<FBMDevice> writeReadyChangeController;

  Stream<FBMDevice> get writeReadyChange => writeReadyChangeController.stream;

  int get nWriteReady {
    int n = 0;
    for (FBMDevice device in devices) {
      if (device.writeReady) n++;
    }
    return n;
  }

  Future<FBMLock> getBleLock() async {
    if (!bleBusy) {
      _lockBleActions();
      return FBMLock(_unlockBleActions);
    }
    Completer lockCompleter = Completer();
    _bleLockQueue.add(lockCompleter);
    await lockCompleter.future;
    return FBMLock(_unlockBleActions);
  }

  Future clearCachedScanResults({String? uuid, Duration? delay}) async {
    if (uuid != null) {
      if (delay != null) {
        await Future.delayed(delay);
        if (!_scanResults.containsKey(uuid)) return;
        if (_scanResults[uuid]!.getAgeMilliseconds() > delay.inMilliseconds) {
          _scanResults.remove(uuid);
        }
      } else {
        _scanResults.remove(uuid);
      }
    } else {
      _scanResults.clear();
    }
  }

  void setDebugFilter(List<FBMDebugLevel> levels) {
    _debugFilter = levels;
  }

  List<ScanResult> getScanResults({FBMScanFilter? filter}) {
    List<ScanResult> devices = [];
    for (TimedScanResult result in _scanResults.values) {
      if (filter != null && !filter(result.scanResult)) continue;
      devices.add(result.scanResult);
    }
    return devices;
  }

  // EVENT LISTENERS
  void _bleStateChange(BluetoothState event) {
    _bleState = event;
    _bleStateBroadcast.add(event);
    debug('bleStateChange: $event', FBMDebugLevel.event);
    if (_bleState == BluetoothState.on) {
      _restartScan();
    } else {}
  }

  void fakeScanResultUntilPotentiallyNewComes(ScanResult? scanResult) {
    if (scanResult?.device == null) return;
    String key = scanResult!.device!.id.toString();
    _scanResults[key] = TimedScanResult(scanResult);
  }

  void _onScanResult(ScanResult scanResult) {
    if (scanResult.device == null) return;
    _handleAutoConnect(scanResult.device!, scanResult: scanResult);
    _lastAdvertisementResult = _nowMs;
    String key = scanResult.device!.id.toString();
    if (!_scanResults.containsKey(key)) {
      _visibleDevicesChanges.add(VisibleDeviceChange(scanResult));
      debug("scan result added: $key", FBMDebugLevel.info);
    }
    _scanResults[key] = TimedScanResult(scanResult);
    _removeOldScanResults();
  }

  // UTILS
  void _lockBleActions() {
    if (bleBusy) throw Exception("ble already locked!");
    _bleActionsBusy = _nowMs;
  }

  void _unlockBleActions() {
    _bleActionsBusy = null;
    if (_bleLockQueue.length > 0) {
      _lockBleActions();
      _bleLockQueue.removeAt(0).complete();
    }
  }

  List<String> _autoConnectHandled = [];
  Map<String, int> _scanResultCount = {};

  Future _handleAutoConnect(BluetoothDevice bdevice, {ScanResult? scanResult}) async {
    final id = scanResult?.device?.id.id;
    if (id != null) {
      final count = _scanResultCount.putIfAbsent(id, () => 0);
      _scanResultCount[id] = count + 1;
      if (count < 5) {
        // make sure name change is propagated
        return;
      }
    }
    _scanResultCount.remove(id);
    String uuid = bdevice.id.toString();
    if (!_autoConnect.containsKey(uuid) || _autoConnectHandled.contains(uuid)) return;
    FBMDevice? device = _autoConnect[uuid];
    if (device == null || device.pauseAutoConnect) return;
    _autoConnectHandled.add(uuid);
    debug('handling auto connect', FBMDebugLevel.info);
    if (connectDelayMs > 0) {
      debug('waiting $connectDelayMs ms before connecting', FBMDebugLevel.info);
      await Future.delayed(Duration(milliseconds: connectDelayMs));
    }
    debug('connecting ${bdevice.name}', FBMDebugLevel.info);

    FBMLock lock = await getBleLock();
    if (scanResult != null) {
      device.initFromScanResult(scanResult);
    }
    device.device ??= bdevice;
    FBMConnection? connection;
    if (_connections.containsKey(uuid))
      connection = _connections[uuid];
    else
      connection = device.createConnection();
    _connections[uuid] = connection;
    try {
      print('STARTED CONNECTING ${DateTime.now()}');
      await device.device!.connect(autoConnect: true).timeout(Duration(seconds: _CONNECT_TIMEOUT_S));
    } catch (e) {
      debug("connect ${device.uuid} timeout", FBMDebugLevel.error);
      try {
        await device.device!.disconnect().timeout(Duration(seconds: 5));
      } catch (e) {
        debug("connect_disconnect ${device.uuid} error", FBMDebugLevel.error);
      }
    }
    print('STOPPED CONNECTING ${DateTime.now()}');
    lock.unlock();
    _autoConnectHandled.remove(uuid);
  }

  void _removeOldScanResults() {
    if (_nowMs - _lastClean > maxResultAgeMs) {
      _lastClean = _nowMs;
      List<String> delete = [];
      for (String key in _scanResults.keys) {
        if (_scanResults[key]!.getAgeMilliseconds() < maxResultAgeMs) continue;
        delete.add(key);
        debug("scan result removed $key", FBMDebugLevel.info);
      }
      for (String key in delete) {
        _visibleDevicesChanges.add(VisibleDeviceChange(_scanResults.remove(key)!.scanResult, removed: true));
      }
    }
  }

  Future<bool> _restartScan() async {
    if (await _ble!.isScanning.first) {
      await _ble!.stopScan();
    }
    return _startScan();
  }

  bool _startScan() {
    if (_bleState != BluetoothState.on) {
      return false;
    }
    try {
      _ble!.scan().listen((sr) {
        try {
          _onScanResult(sr);
        } catch (e) {
          debug("ble scan handling error", FBMDebugLevel.error);
        }
      }, onDone: () {
        debug("ble scan ended", FBMDebugLevel.error);
      }, onError: (error) {
        debug("ble scan error: $error", FBMDebugLevel.error);
      });
      return true;
    } catch (e) {
      debug("ble - already scanning!", FBMDebugLevel.error);
      return false;
    }
  }

  void debug(String msg, FBMDebugLevel level) {
    if (!_debugFilter.contains(level)) return;
    print("$_TAG | $level | $msg");
  }

  void registerDevice(FBMDevice device) {
    assert(!_devices.containsKey(device.uuid));
    debug("device ${device.uuid} registered", FBMDebugLevel.info);
    _devices[device.uuid] = device;
  }

  void unregisterDevice(String uuid) {
    _devices.remove(uuid);
  }

  FBMDevice? getDevice(String uuid, {FBMNewDevice? newDevice, BluetoothDevice? device}) {
    if (_devices.containsKey(uuid)) return _devices[uuid];
    if (newDevice == null) return null;
    FBMDevice fbmDevice = newDevice(uuid);
    fbmDevice.device = device;
    return fbmDevice;
  }

  void autoConnect(FBMDevice device) {
    _autoConnect[device.uuid] = device;
    if (_bondedDevices.containsKey(device.uuid)) {
      _handleAutoConnect(_bondedDevices[device.uuid]!);
    }
  }

  Future _updateBonded() async {
    try {
      List<BluetoothDevice> bonded = await ble!.getBondedDevices();
      for (BluetoothDevice bd in bonded) {
        _bondedDevices[bd.id.toString()] = bd;
      }
      List<String> keys = _bondedDevices.keys.toList();
      List<String> current = bonded.map((b) => b.id.toString()) as List<String>;
      for (String key in keys) {
        if (!current.contains(key)) {
          _bondedDevices.remove(key);
          continue;
        }
        if (_autoConnect.containsKey(key)) {
          _handleAutoConnect(_bondedDevices[keys as String]!);
        }
      }
    } catch (_) {}
  }

  void _fbmStateMonitor(_) async {
    _removeOldScanResults();
    await _updateBonded();
    if (_bleState != BluetoothState.on) return;
    if (_nowMs - _lastAdvertisementResult > _SCAN_RESULT_TIMEOUT_MS) {
      debug("scan timeout - restarting scan", FBMDebugLevel.info);
      _restartScan();
    }

    if (bleBusy && _nowMs - _bleActionsBusy! > _BLE_ACTIONS_BUSY_TIMEOUT_MS) {
      debug("FIXME! ble actions busy timeout", FBMDebugLevel.error);
      _unlockBleActions();
    }

    _syncWithPlatform();
  }

  void cancelAutoConnect(FBMDevice device) {
    if (_autoConnect.containsKey(device.uuid)) _autoConnect.remove(device.uuid);
  }

  Future _syncWithPlatform() async {
    List<BluetoothDevice> devices = await _ble!.connectedDevices;
    for (BluetoothDevice device in devices) {
      String uuid = device.id.toString();
      if (!_connections.containsKey(uuid)) {
        device.disconnect();
        debug("device on platform unregistered!", FBMDebugLevel.error);
        continue;
      }
      if (_connections[uuid]!.state != BluetoothDeviceState.connected) {
        debug("device on platform connected, but disconnected here!", FBMDebugLevel.error);
        device.disconnect();
      }
    }
  }

  Future _disconnectConnectedOnPlatform() async {
    List<BluetoothDevice> devices = await _ble!.connectedDevices;
    for (BluetoothDevice device in devices) {
      device.disconnect();
    }
  }
}

class FBMLock {
  final VoidCallback _action;
  bool _unlocked = false;
  Completer _completer = Completer();

  Future get future => _completer.future;

  FBMLock(VoidCallback action) : _action = action;

  void unlock() {
    if (_unlocked) return;
    _action();
    _completer.complete();
    _unlocked = true;
  }
}

class TimedScanResult {
  TimedScanResult(this.scanResult) {
    _lastAdvertisement = DateTime.now().millisecondsSinceEpoch;
  }

  int getAgeMilliseconds() {
    return DateTime.now().millisecondsSinceEpoch - _lastAdvertisement;
  }

  ScanResult scanResult;
  late int _lastAdvertisement;
}

class VisibleDeviceChange {
  final bool removed;
  final ScanResult scanResult;

  VisibleDeviceChange(this.scanResult, {this.removed = false});
}

FlutterBlueManager flutterBlueManager = FlutterBlueManager._();
