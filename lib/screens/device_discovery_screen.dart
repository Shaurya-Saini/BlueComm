// lib/screens/device_discovery_screen.dart
// Screen 1: Device Discovery Screen — the initial screen presented on app launch.
// Handles permission requests, Bluetooth adapter checks, device scanning,
// and navigation to the Chat Screen upon successful RFCOMM connection.

import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import '../services/permission_handler_service.dart';
import '../services/bluetooth_manager.dart';
import '../services/connection_manager.dart';
import '../widgets/device_list_tile.dart';
import 'chat_screen.dart';

class DeviceDiscoveryScreen extends StatefulWidget {
  const DeviceDiscoveryScreen({super.key});

  @override
  State<DeviceDiscoveryScreen> createState() => _DeviceDiscoveryScreenState();
}

class _DeviceDiscoveryScreenState extends State<DeviceDiscoveryScreen> {
  // Service instances for permissions, Bluetooth adapter, and connection management.
  final PermissionHandlerService _permissionService = PermissionHandlerService();
  final BluetoothManager _bluetoothManager = BluetoothManager();
  final ConnectionManager _connectionManager = ConnectionManager();

  // Text controller for the display name input field.
  final TextEditingController _nameController = TextEditingController();

  // Lists of paired (bonded) and newly discovered Bluetooth devices.
  List<BluetoothDevice> _pairedDevices = [];
  List<BluetoothDevice> _discoveredDevices = [];

  // Tracks whether a device discovery scan is currently in progress.
  bool _isScanning = false;

  // Tracks whether Bluetooth permissions have been granted.
  bool _permissionsGranted = false;

  // Current connection state for the status chip display.
  BtConnectionState _connectionState = BtConnectionState.idle;

  @override
  void initState() {
    super.initState();
    // Set a default display name.
    _nameController.text = 'User';

    // Initialize the connection manager — starts native server socket
    // and sets up platform channel listeners.
    _connectionManager.initialize();

    // Handle incoming connection requests from the server socket.
    // Show an approval dialog instead of auto-navigating to chat.
    _connectionManager.onConnectionRequest = (name, address) {
      if (mounted) {
        _showConnectionRequestDialog(name, address);
      }
    };

    // Navigate to chat after the user accepts the incoming connection.
    _connectionManager.onConnectionAccepted = () {
      if (mounted) {
        _navigateToChat();
      }
    };

    // Listen to connection state changes for the status chip and navigation.
    _connectionManager.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _connectionState = state;
        });

        // Navigate to Chat Screen when connection is established (client-side).
        if (state == BtConnectionState.connected) {
          _navigateToChat();
        }
      }
    });

    // Request permissions on screen initialization.
    _initPermissions();
  }

  // Requests Bluetooth and location permissions on app start.
  Future<void> _initPermissions() async {
    final granted = await _permissionService.checkAndRequest();
    if (mounted) {
      setState(() {
        _permissionsGranted = granted;
      });

      if (granted) {
        // Load paired devices immediately after permissions are granted.
        _loadPairedDevices();
      }
    }
  }

  // Retrieves the list of previously bonded (paired) Bluetooth devices.
  Future<void> _loadPairedDevices() async {
    try {
      final devices = await _bluetoothManager.getPairedDevices();
      if (mounted) {
        setState(() {
          _pairedDevices = devices;
        });
      }
    } catch (e) {
      _showSnackBar('Failed to load paired devices: $e');
    }
  }

  // Starts a Bluetooth Classic device discovery scan.
  // First ensures Bluetooth is enabled, then streams discovered devices in real time.
  Future<void> _startScan() async {
    // Re-check permissions before scanning.
    if (!_permissionsGranted) {
      final granted = await _permissionService.checkAndRequest();
      if (!granted) {
        _showSnackBar('Bluetooth permissions are required to scan for devices.');
        return;
      }
      setState(() => _permissionsGranted = true);
    }

    // Ensure Bluetooth adapter is enabled.
    final isEnabled = await _bluetoothManager.isEnabled();
    if (isEnabled != true) {
      final enabled = await _bluetoothManager.requestEnable();
      if (enabled != true) {
        _showSnackBar('Please enable Bluetooth to scan for devices.');
        return;
      }
    }

    // Clear previous discovered devices and start scanning.
    setState(() {
      _discoveredDevices = [];
      _isScanning = true;
    });

    // Reload paired devices as well.
    _loadPairedDevices();

    // Start discovery, streaming each found device to the list.
    _bluetoothManager.startDiscovery(
      onDevice: (result) {
        if (mounted) {
          setState(() {
            // Avoid duplicate entries in the discovered list.
            final existingIndex = _discoveredDevices.indexWhere(
              (d) => d.address == result.device.address,
            );
            if (existingIndex == -1) {
              // Also skip if already in paired devices list.
              final isPaired = _pairedDevices.any(
                (d) => d.address == result.device.address,
              );
              if (!isPaired) {
                _discoveredDevices.add(result.device);
              }
            }
          });
        }
      },
      onFinished: () {
        if (mounted) {
          setState(() {
            _isScanning = false;
          });
        }
      },
    );
  }

  // Initiates an RFCOMM connection to the selected device.
  Future<void> _connectToDevice(BluetoothDevice device) async {
    // Cancel any ongoing scan to conserve resources.
    // CRITICAL: Must await and add delay — Android BT adapter needs time
    // to fully stop discovery before RFCOMM connections can succeed.
    await _bluetoothManager.cancelDiscovery();
    setState(() => _isScanning = false);

    // Wait for the adapter to settle after stopping discovery.
    await Future.delayed(const Duration(seconds: 1));

    _showSnackBar('Connecting to ${device.name ?? device.address}...');
    await _connectionManager.connectTo(device);

    // If connection failed (state != connected), show a message.
    if (_connectionManager.currentState != BtConnectionState.connected) {
      _showSnackBar('Failed to connect to ${device.name ?? device.address}.');
    }
  }

  // Navigates to the Chat Screen, passing the connection manager and device info.
  void _navigateToChat() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          connectionManager: _connectionManager,
          displayName: _nameController.text.isNotEmpty
              ? _nameController.text
              : 'User',
        ),
      ),
    ).then((_) {
      // When returning from Chat Screen, reload paired devices.
      if (mounted) {
        _loadPairedDevices();
        setState(() {
          _connectionState = _connectionManager.currentState;
        });
      }
    });
  }

  // Displays a brief message at the bottom of the screen.
  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // Returns the color for the connection status chip based on the current state.
  Color _getStatusColor() {
    switch (_connectionState) {
      case BtConnectionState.idle:
      case BtConnectionState.disconnected:
        return Colors.grey;
      case BtConnectionState.discovering:
        return Colors.blue;
      case BtConnectionState.connecting:
      case BtConnectionState.reconnecting:
        return Colors.amber;
      case BtConnectionState.pendingRequest:
        return Colors.orange;
      case BtConnectionState.connected:
        return Colors.green;
    }
  }

  // Returns a human-readable label for the connection status chip.
  String _getStatusLabel() {
    switch (_connectionState) {
      case BtConnectionState.idle:
        return 'Idle';
      case BtConnectionState.discovering:
        return 'Scanning';
      case BtConnectionState.connecting:
        return 'Connecting';
      case BtConnectionState.pendingRequest:
        return 'Request';
      case BtConnectionState.connected:
        return 'Connected';
      case BtConnectionState.reconnecting:
        return 'Reconnecting';
      case BtConnectionState.disconnected:
        return 'Disconnected';
    }
  }

  // Shows a dialog asking the user to accept or decline an incoming
  // Bluetooth connection request.
  void _showConnectionRequestDialog(String name, String address) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          icon: const Icon(Icons.bluetooth, size: 36, color: Colors.blueAccent),
          title: const Text('Incoming Connection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$name',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                address,
                style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              ),
              const SizedBox(height: 12),
              const Text(
                'wants to connect with you.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.spaceEvenly,
          actions: [
            TextButton.icon(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _connectionManager.declineConnection();
                _showSnackBar('Connection declined.');
              },
              icon: const Icon(Icons.close, color: Colors.redAccent),
              label: const Text(
                'Decline',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _connectionManager.acceptConnection();
              },
              icon: const Icon(Icons.check),
              label: const Text('Accept'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green,
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bluetoothManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BlueComm'),
        centerTitle: true,
        actions: [
          // Connection status chip displayed in the app bar.
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: CircleAvatar(
                backgroundColor: _getStatusColor(),
                radius: 6,
              ),
              label: Text(
                _getStatusLabel(),
                style: const TextStyle(fontSize: 12),
              ),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Display name input field.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Display Name',
                hintText: 'Enter your name',
                prefixIcon: const Icon(Icons.person_outline),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
              ),
            ),
          ),

          // Scan / Refresh button.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isScanning ? null : _startScan,
                icon: _isScanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(_isScanning ? 'Scanning...' : 'Scan for Devices'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ),

          // Device lists — scrollable.
          Expanded(
            child: ListView(
              children: [
                // Paired Devices section header.
                if (_pairedDevices.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'PAIRED DEVICES',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  // Render each paired device.
                  ..._pairedDevices.map((device) => DeviceListTile(
                        device: device,
                        isPaired: true,
                        onTap: () => _connectToDevice(device),
                      )),
                ],

                // Discovered Devices section header.
                if (_discoveredDevices.isNotEmpty || _isScanning) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'DISCOVERED DEVICES',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  // Render each discovered device.
                  ..._discoveredDevices.map((device) => DeviceListTile(
                        device: device,
                        isPaired: false,
                        onTap: () => _connectToDevice(device),
                      )),
                  // Show progress indicator while scanning.
                  if (_isScanning)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    ),
                ],

                // Empty state when no devices are found.
                if (_pairedDevices.isEmpty &&
                    _discoveredDevices.isEmpty &&
                    !_isScanning)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.bluetooth_disabled,
                              size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text(
                            'No devices found.\nTap "Scan for Devices" to start.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
