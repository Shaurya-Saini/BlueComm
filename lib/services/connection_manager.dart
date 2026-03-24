// lib/services/connection_manager.dart
// Core state machine managing the full lifecycle of the RFCOMM connection.
// Uses the native platform channel (RfcommChannel) for connections instead of
// flutter_bluetooth_serial's BluetoothConnection, which fails on many devices.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'rfcomm_channel.dart';

// Explicit connection states as defined in the system design document.
enum BtConnectionState {
  idle,            // App started, Bluetooth available, no action in progress.
  discovering,     // Device scan is actively running.
  connecting,      // RFCOMM socket connection attempt in progress.
  pendingRequest,  // Incoming connection received, awaiting user approval.
  connected,       // RFCOMM socket is live, bidirectional data exchange active.
  reconnecting,    // Connection loss detected, automatic reconnection underway.
  disconnected,    // Connection terminated by user or all retries exhausted.
}

class ConnectionManager {
  // Broadcast stream controller so multiple listeners (UI, services) can subscribe.
  final _stateController = StreamController<BtConnectionState>.broadcast();

  // Public stream exposing connection state changes to the UI layer.
  Stream<BtConnectionState> get stateStream => _stateController.stream;

  // Current connection state, defaults to idle on initialization.
  BtConnectionState _state = BtConnectionState.idle;

  // Getter for the current state (synchronous access).
  BtConnectionState get currentState => _state;

  // Reference to the currently connected peer device. Null when disconnected.
  BluetoothDevice? connectedDevice;

  // Reference to a device whose connection is pending user approval.
  BluetoothDevice? pendingDevice;

  // Native RFCOMM platform channel for connection and I/O.
  final RfcommChannel rfcommChannel = RfcommChannel();

  // Tracks the number of failed reconnection attempts (max: 3).
  int reconnectAttempts = 0;

  // Maximum number of automatic reconnection retries before giving up.
  static const int maxRetries = 3;

  // Callback invoked when an incoming connection request is received (server role).
  // The receiver should show an approval dialog, then call acceptConnection()
  // or declineConnection().
  void Function(String name, String address)? onConnectionRequest;

  // Callback invoked after the user accepts the incoming connection request.
  VoidCallback? onConnectionAccepted;

  // Initializes the connection manager — starts the server socket and
  // sets up listeners for incoming connections.
  void initialize() {
    rfcommChannel.initialize();

    // Start the server socket so this device can accept incoming connections.
    rfcommChannel.startServer();

    // Handle incoming connections from the server socket.
    // Instead of auto-connecting, set to pendingRequest and let the UI ask for approval.
    rfcommChannel.onIncomingConnection = (address, name) {
      debugPrint('BlueComm: Incoming connection request from $name ($address)');
      pendingDevice = BluetoothDevice(
        name: name,
        address: address,
      );
      _setState(BtConnectionState.pendingRequest);
      onConnectionRequest?.call(name, address);
    };
  }

  // Initiates an RFCOMM socket connection to the specified Bluetooth device.
  // Uses the native platform channel with 3-tier fallback:
  //   1. Standard createRfcommSocketToServiceRecord (SPP UUID)
  //   2. Reflection-based createRfcommSocket(1) — bypasses SDP
  //   3. createInsecureRfcommSocketToServiceRecord — no pairing required
  Future<void> connectTo(BluetoothDevice device) async {
    _setState(BtConnectionState.connecting);
    connectedDevice = device;

    try {
      // Cancel discovery at the adapter level before connecting.
      await FlutterBluetoothSerial.instance.cancelDiscovery();
      await Future.delayed(const Duration(milliseconds: 500));

      // Connect via the native platform channel.
      final result = await rfcommChannel.connect(device.address);

      if (result != null && result['connected'] == true) {
        reconnectAttempts = 0;
        _setState(BtConnectionState.connected);
      } else {
        debugPrint('BlueComm: Connection returned null for ${device.address}');
        await _handleConnectionFailure();
      }
    } catch (e) {
      debugPrint('BlueComm: Connection failed to ${device.address}: $e');
      await _handleConnectionFailure();
    }
  }

  // Handles a failed connection attempt by retrying up to maxRetries times.
  Future<void> _handleConnectionFailure() async {
    if (reconnectAttempts < maxRetries) {
      reconnectAttempts++;
      _setState(BtConnectionState.reconnecting);

      // 3-second delay between reconnection attempts.
      await Future.delayed(const Duration(seconds: 3));

      if (connectedDevice != null) {
        await connectTo(connectedDevice!);
      } else {
        _setState(BtConnectionState.disconnected);
      }
    } else {
      _setState(BtConnectionState.disconnected);
      _clearSession();
    }
  }

  // Attempts automatic reconnection after an unexpected connection loss.
  Future<void> attemptReconnect() async {
    final device = connectedDevice;
    if (device != null) {
      await rfcommChannel.disconnect();
      reconnectAttempts = 0;
      _setState(BtConnectionState.reconnecting);
      await Future.delayed(const Duration(seconds: 2));
      await connectTo(device);
    }
  }

  // Called by the UI when the user accepts an incoming connection request.
  void acceptConnection() {
    if (_state == BtConnectionState.pendingRequest && pendingDevice != null) {
      connectedDevice = pendingDevice;
      pendingDevice = null;
      reconnectAttempts = 0;
      _setState(BtConnectionState.connected);
      onConnectionAccepted?.call();
    }
  }

  // Called by the UI when the user declines an incoming connection request.
  void declineConnection() {
    pendingDevice = null;
    rfcommChannel.disconnect();
    _setState(BtConnectionState.idle);
  }

  // Cleanly terminates the active connection and releases all resources.
  void disconnect() {
    rfcommChannel.disconnect();
    _clearSession();
    _setState(BtConnectionState.disconnected);
  }

  // Resets all session-related fields to their default values.
  void _clearSession() {
    connectedDevice = null;
    pendingDevice = null;
    reconnectAttempts = 0;
  }

  // Updates the connection state and emits the new state to all stream listeners.
  void _setState(BtConnectionState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  // Releases all resources.
  void dispose() {
    rfcommChannel.stopServer();
    rfcommChannel.dispose();
    _stateController.close();
  }
}
