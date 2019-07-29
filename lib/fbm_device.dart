import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue/flutter_blue.dart';

import 'fbm_connection.dart';
import 'flutter_blue_manager.dart';

abstract class FBMDevice {
  final String uuid;
  final FlutterBlueManager fbm;
  ScanResult scanResult;

  BluetoothDevice device;

  FBMDevice(this.uuid, this.fbm) {
    assert (uuid != null);
    fbm.registerDevice(this);
    _writeReadyStreamController = StreamController.broadcast();
  }

  // writeReady
  StreamController<bool> _writeReadyStreamController;
  Stream<bool> get writeReadyStream => _writeReadyStreamController.stream;
  bool _writeReady = false;

  set writeReady(ready) {
    if (_writeReady != ready) {
      _writeReadyStreamController.add(ready);
      _writeReady = ready;
    }
  }

  bool get writeReady => _writeReady && connection?.state == BluetoothDeviceState.connected ?? false;

  FBMConnection connection;

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
    device.disconnect();
  }
}
