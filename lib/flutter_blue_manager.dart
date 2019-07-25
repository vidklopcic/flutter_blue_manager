import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_blue/flutter_blue.dart';

import 'fbm_connection.dart';
import 'fbm_device.dart';
import 'fbm_device_state.dart';

enum FBMDebugLevel { error, info, event, action }
typedef bool FBMScanFilter(ScanResult result);
typedef FBMDevice FBMNewDevice(String uuid);
class FlutterBlueManager {
  static const _BLE_ACTIONS_BUSY_TIMEOUT_MS = 30000;
  static const _MAX_RESULT_AGE_MS = 10000;
  static const _CONNECT_TIMEOUT_S = 5;
  static const _SCAN_RESULT_TIMEOUT_MS = 5000;
  static const _TAG = "FBM";

  List<FBMDebugLevel> _debugFilter = FBMDebugLevel.values;

  FlutterBlue _ble;

  FlutterBlue get ble => _ble;
  BluetoothState _bleState;

  FlutterBlueManager._() {
    _ble = FlutterBlue.instance;
    _ble.state.listen(_bleStateChange);
    _fbmStateMonitorTimer = Timer.periodic(Duration(seconds: 5), _fbmStateMonitor);
    _visibleDevicesChanges = StreamController.broadcast();
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
  Map<String, FBMConnection> _connections = {};
  // state monitoring
  Timer _fbmStateMonitorTimer;
  int _lastAdvertisementResult = DateTime.now().millisecondsSinceEpoch;
  // lock
  int _bleActionsBusy;
  List<Completer> _bleLockQueue = [];

  // PUBLIC API
  bool get bleBusy => _bleActionsBusy != null;
  StreamController<ScanResult> _visibleDevicesChanges;
  Stream<ScanResult> get visibleDevicesStream => _visibleDevicesChanges.stream;

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

  void clearCachedScanResults() {
    _scanResults.clear();
  }

  void setDebugFilter(List<FBMDebugLevel> levels) {
    assert(levels != null);
    _debugFilter = levels;
  }

  List<ScanResult> getScanResults({FBMScanFilter filter}) {
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
    debug('bleStateChange: $event', FBMDebugLevel.event);
    if (_bleState == BluetoothState.on) {
      _restartScan();
    } else {

    }
  }

  void _onScanResult(ScanResult scanResult) {
    _handleAutoConnect(scanResult);
    _lastAdvertisementResult = _nowMs;
    String key = scanResult.device.id.toString();
    if (!_scanResults.containsKey(key)) {
      _visibleDevicesChanges.add(scanResult);
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
  Future _handleAutoConnect(ScanResult scanResult) async {
    String uuid = scanResult.device.id.toString();
    if (!_autoConnect.containsKey(uuid) || _autoConnectHandled.contains(uuid)) return;
    _autoConnectHandled.add(uuid);
    debug('handling auto connect', FBMDebugLevel.info);
    FBMLock lock = await getBleLock();
    FBMDevice device = _autoConnect[uuid];
    if (device == null) {
      _autoConnectHandled.remove(uuid);
      lock.unlock();
      return;
    }
    device.device = scanResult.device;
    FBMConnection connection;
    if (_connections.containsKey(uuid))
      connection = _connections[uuid];
    else
      connection = device.createConnection();
    _connections[uuid] = connection;
    try {
      await device.device.connect(autoConnect: false).timeout(Duration(seconds: _CONNECT_TIMEOUT_S));
    } catch (e) {
      debug("connect ${device.uuid} timeout", FBMDebugLevel.error);
      try {
        await device.device.disconnect().timeout(Duration(seconds: 5));
      } catch (e) {
        debug("connect_disconnect ${device.uuid} error", FBMDebugLevel.error);
      }
    }
    lock.unlock();
    _autoConnectHandled.remove(uuid);
  }

  void _removeOldScanResults() {
    if (_nowMs - _lastClean >
        _MAX_RESULT_AGE_MS) {
      _lastClean = _nowMs;
      List<String> delete = new List();
      for (String key in _scanResults.keys) {
        if (_scanResults[key].getAgeMilliseconds() < _MAX_RESULT_AGE_MS)
          continue;
        delete.add(key);
        debug("scan result removed $key", FBMDebugLevel.info);
      }
      for (String key in delete) {
        _visibleDevicesChanges.add(_scanResults.remove(key).scanResult);
      }
    }
  }

  Future<bool> _restartScan() async {
    if (await _ble.isScanning.first) {
      await _ble.stopScan();
    }
    return _startScan();
  }

  bool _startScan() {
    if (_bleState != BluetoothState.on) {
      return false;
    }
    try {
      _ble.scan().listen((sr) {
        try {
          _onScanResult(sr);
        } catch (e) {
          debug("ble scan handling error", FBMDebugLevel.error);
        }
      }, onDone: () {
        debug("ble scan ended", FBMDebugLevel.error);
        _restartScan();
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
    assert (!_devices.containsKey(device.uuid));
    debug("device ${device.uuid} registered", FBMDebugLevel.info);
    _devices[device.uuid] = device;
  }

  void unregisterDevice(String uuid) {
    _devices.remove(uuid);
  }

  FBMDevice getDevice(String uuid, {FBMNewDevice newDevice, BluetoothDevice device}) {
    if (_devices.containsKey(uuid)) return _devices[uuid];
    if (newDevice == null) return null;
    FBMDevice fbmDevice = newDevice(uuid);
    fbmDevice.device = device;
    return fbmDevice;
  }

  void autoConnect(FBMDevice device) {
    _autoConnect[device.uuid] = device;
  }

  void _fbmStateMonitor(_) async {
    if (_bleState != BluetoothState.on) return;
    if (_nowMs - _lastAdvertisementResult > _SCAN_RESULT_TIMEOUT_MS) {
      debug("scan timeout - restarting scan", FBMDebugLevel.info);
      _restartScan();
    }

    if (bleBusy && _nowMs - _bleActionsBusy > _BLE_ACTIONS_BUSY_TIMEOUT_MS) {
      debug("FIXME! ble actions busy timeout", FBMDebugLevel.error);
      _unlockBleActions();
    }
  }

  void cancelAutoConnect(FBMDevice device) {
    if (_autoConnect.containsKey(device.uuid)) _autoConnect.remove(device.uuid);
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
  int _lastAdvertisement;
}

FlutterBlueManager flutterBlueManager = FlutterBlueManager._();
