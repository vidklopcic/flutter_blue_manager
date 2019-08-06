import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue/flutter_blue.dart';

import 'fbm_device.dart';
import 'fbm_device_state.dart';
import 'flutter_blue_manager.dart';

typedef void FBMWriteEvent(bool successful);

class FBMWriteData {
  final List<int> data;
  FBMWriteEvent callback;
  final BluetoothCharacteristic characteristic;
  final bool withoutResponse;

  FBMWriteData(List<int> data, this.characteristic,
      {this.callback, this.withoutResponse = false})
      : this.data = List.from(data);
}

abstract class FBMConnection {
  static const _WRITE_TIMEOUT = 5;    // seconds
  final FBMDevice device;
  BluetoothDeviceState _state = BluetoothDeviceState.disconnected;
  BluetoothDeviceState get state => _state;

  List<BluetoothService> services = [];

  List<FBMWriteData> _outBuffer = [];
  Map<GlobalKey, FBMWriteData> _realTimeWrite = {};
  List<GlobalKey> _realTimeWriteKeys = [];
  bool _sendInProgress = false;
  bool get isSending => _sendInProgress;

  FBMConnection(this.device) {
    device.device.state.listen(_onDeviceConnStateChange,
        onDone: () => device.fbm.debug(
            'device ${device.uuid} state stream done', FBMDebugLevel.error));
    device.connection = this;
  }

  Future _discoveringServices;

  bool _turningOnNotifications = false;

  void _onDeviceConnStateChange(BluetoothDeviceState newState) {
    if (newState == state) return;
    device.fbm.debug(
        "device ${device.uuid} conn state = $newState", FBMDebugLevel.info);
    if (newState == BluetoothDeviceState.connected) {
      if (_discoveringServices != null) {
        device.fbm.debug("already discovering - discover after first finishes!",
            FBMDebugLevel.info);
        _discoveringServices.then((_) => _discoverServices());
      } else {
        _discoverServices();
      }
    } else {
      device.writeReady = false;
    }

    _state = newState;
    onDeviceStateChange();
  }

  void onDeviceStateChange();

  void _discoverServices() async {
    if (_discoveringServices != null) {
      device.fbm.debug("discovering services reentry", FBMDebugLevel.error);
      return;
    }
    device.fbm.debug("discovering services", FBMDebugLevel.info);
    Completer completer = Completer();
    _discoveringServices = completer.future;
    FBMLock lock = await device.fbm.getBleLock();
    device.fbm
        .debug("discovering services - lock acquired", FBMDebugLevel.info);

    List<BluetoothService> svcs;
    try {
      svcs =
          await device.device.discoverServices().timeout(Duration(seconds: 5));
    } catch (_) {
      device.fbm.debug("discovering services timeout", FBMDebugLevel.error);
      device.device.disconnect();
    }
    lock.unlock();
    _discoveringServices = null;
    if (svcs != null) {
      services = svcs;
      onServicesDiscovered();
    }
    completer.complete();
  }

  Future<bool> turnOnNotifications(
      BluetoothCharacteristic characteristic) async {
    FBMLock lock = await device.fbm.getBleLock();
    bool result = false;
    try {
      result = await characteristic
          .setNotifyValue(true)
          .timeout(Duration(seconds: 5));
      device.fbm
          .debug("notifications $characteristic are on", FBMDebugLevel.info);
    } catch (e) {
      device.fbm.debug(
          "notifications $characteristic turn on timeout", FBMDebugLevel.error);
    }
    lock.unlock();
    return result;
  }

  BluetoothCharacteristic getCharacteristic(
      BluetoothService service, String uuid) {
    for (BluetoothCharacteristic characteristic in service.characteristics) {
      if (characteristic.uuid.toString() == uuid) return characteristic;
    }
    return null;
  }

  BluetoothService getService(String uuid) {
    for (BluetoothService service in services) {
      if (service.uuid.toString() == uuid) return service;
    }
    return null;
  }

  // transmission
  GlobalKey _defaultRtKey = GlobalKey();
  /// transmit ASAP, if previous unsent, replace with new value
  void realTimeWrite(FBMWriteData data, {GlobalKey key}) {
    key = key ?? _defaultRtKey;
    _realTimeWrite[key] = data;
    if (!_realTimeWriteKeys.contains(key)) {
      _realTimeWriteKeys.add(key);
    }
    if (!_sendInProgress) _send();
  }

  /// queue data for write
  void writeData(FBMWriteData data) {
    _outBuffer.add(data);
    if (!_sendInProgress) _send();
  }

  Future<bool> writeFuture(FBMWriteData data) async {
    Completer<bool> completer = Completer();
    data.callback = (success) => completer.complete(success);
    writeData(data);
    return await completer.future;
  }

  /// Recursively send all data from _outBuffer and
  /// sets _sendInProgress=true until _outBuffer.length == 0
  void _send() async {
    FBMWriteData data = _fetchNextFBMWriteDeta();
    if (data == null) {
      _sendInProgress = false;
      return;
    }
    assert(data.characteristic != null);
    _sendInProgress = true;
    try {
      await data.characteristic
          .write(data.data, withoutResponse: data.withoutResponse).timeout(Duration(seconds: _WRITE_TIMEOUT));
      if (data.callback != null) data.callback(true);
      _send();
    } catch (e) {
      device.fbm.debug("error writing characteristic ${data.characteristic}",
          FBMDebugLevel.error);
      if (data.callback != null) data.callback(false);
      _cancelWriteQueue();
      _sendInProgress = false;
    }
  }

  FBMWriteData _fetchNextFBMWriteDeta() {
    if (_outBuffer.length != 0) {
      return _outBuffer.removeAt(0);
    }
    if (_realTimeWriteKeys.length > 0) {
      return _realTimeWrite.remove(_realTimeWriteKeys.removeAt(0));
    }
    return null;
  }

  void _cancelWriteQueue() {
    for (FBMWriteData data in _outBuffer) {
      if (data.callback != null) data.callback(false);
    }
    for (GlobalKey key in _realTimeWriteKeys) {
      FBMWriteData data = _realTimeWrite[key];
      if (data.callback != null) data.callback(false);
    }
    _outBuffer.clear();
    _realTimeWrite = {};
  }

  // abstract methods
  void onServicesDiscovered();
}
