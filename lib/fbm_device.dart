import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue/flutter_blue.dart';

import 'fbm_connection.dart';
import 'flutter_blue_manager.dart';

abstract class FBMDevice {
  final String uuid;
  final FlutterBlueManager fbm;

  // settings
  int connectRetryDelay = FlutterBlueManager.CONNECT_RETRY_DELAY_MS;
  bool _pauseAutoConnect = false;
  bool get pauseAutoConnect => DateTime.now().millisecondsSinceEpoch < doNotConnectBeforeTimestamp || _pauseAutoConnect;
  set pauseAutoConnect(bool pause) => _pauseAutoConnect = pause == true;
  int doNotConnectBeforeTimestamp = 0;

  ScanResult? scanResult;

  BluetoothDevice? device;

  FBMDevice(this.uuid, this.fbm) {
    assert (uuid != null);
    fbm.registerDevice(this);
    _writeReadyStreamController = StreamController.broadcast();
  }

  // writeReady
  late StreamController<bool> _writeReadyStreamController;
  Stream<bool> get writeReadyStream => _writeReadyStreamController.stream;
  bool _writeReady = false;

  set writeReady(ready) {
    if (_writeReady != ready) {
      _writeReadyStreamController.add(ready);
      _writeReady = ready;
      fbm.writeReadyChangeController.add(this);
    }
  }

  bool get writeReady => _writeReady && connection?.state == BluetoothDeviceState.connected ?? false;

  FBMConnection? connection;

  void close() {
    fbm.unregisterDevice(uuid);
  }

  FBMConnection createConnection();

  @mustCallSuper
  void initFromScanResult(ScanResult result) {
    scanResult = result;
  }

  void disconnect() {
    if (device == null) return;
    fbm.cancelAutoConnect(this);
    device!.disconnect();
  }

  void updateConnectRetryDelay() {
    doNotConnectBeforeTimestamp = DateTime.now().millisecondsSinceEpoch + connectRetryDelay;
  }
}
