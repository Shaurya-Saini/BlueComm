// lib/services/messaging_module.dart
// Owns both the outbound and inbound data pipelines over the RFCOMM socket.
// Now uses the native RfcommChannel for I/O instead of flutter_bluetooth_serial's
// BluetoothConnection, which doesn't support the reflection-based fallback.

import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/chat_message.dart';
import 'rfcomm_channel.dart';

class MessagingModule {
  // Special signal sent over the socket to notify the peer of an intentional disconnect.
  static const String disconnectSignal = '__BLUECOMM_DISCONNECT__';

  // Special signal sent by the receiver to approve the connection request.
  static const String acceptSignal = '__BLUECOMM_ACCEPT__';

  // Reference to the native RFCOMM platform channel for send/receive.
  final RfcommChannel rfcommChannel;

  // Broadcast stream controller for delivering ChatMessage objects to the UI.
  final _messageController = StreamController<ChatMessage>.broadcast();

  // Public stream that the UI subscribes to for incoming and outgoing messages.
  Stream<ChatMessage> get messageStream => _messageController.stream;

  // In-memory ordered collection of all messages in the current session.
  final List<ChatMessage> messageList = [];

  // Subscription to the rfcomm channel's data stream.
  StreamSubscription? _dataSubscription;

  // Buffer for accumulating incoming bytes until a complete message (newline) is found.
  String _buffer = '';

  // Callback invoked when the socket stream closes unexpectedly (peer crashed/lost).
  final VoidCallback? onDisconnected;

  // Callback invoked when the peer sends an intentional disconnect signal.
  VoidCallback? onRemoteDisconnect;

  // Initializes the module by subscribing to the native data stream.
  MessagingModule(this.rfcommChannel, {this.onDisconnected}) {
    _dataSubscription = rfcommChannel.dataStream.listen(
      _onData,
      onError: (error) {
        debugPrint('BlueComm: Messaging data error: $error');
        onDisconnected?.call();
      },
      onDone: () {
        debugPrint('BlueComm: Messaging data stream closed');
        onDisconnected?.call();
      },
    );
  }

  // Processes incoming raw bytes from the RFCOMM socket.
  // Appends bytes to the buffer, then segments complete messages on newline delimiters.
  void _onData(Uint8List data) {
    // Decode incoming bytes from UTF-8 and append to the rolling buffer.
    _buffer += utf8.decode(data);

    // Extract complete messages delimited by newline characters.
    while (_buffer.contains('\n')) {
      final newlineIndex = _buffer.indexOf('\n');
      final messageText = _buffer.substring(0, newlineIndex).trim();
      _buffer = _buffer.substring(newlineIndex + 1);

      // Only process non-empty messages.
      if (messageText.isNotEmpty) {
        // Intercept control signals — don't treat them as chat messages.
        if (messageText == disconnectSignal) {
          debugPrint('BlueComm: Received disconnect signal from peer');
          onRemoteDisconnect?.call();
          return;
        }
        if (messageText == acceptSignal) {
          // Accept signal is handled by the discovery screen, ignore here.
          return;
        }

        final message = ChatMessage(
          messageText: messageText,
          isSentByUser: false,
        );
        messageList.add(message);
        if (!_messageController.isClosed) {
          _messageController.add(message);
        }
      }
    }
  }

  // Sends the disconnect signal to the peer before closing the socket.
  Future<void> sendDisconnectSignal() async {
    final bytes = Uint8List.fromList(utf8.encode('$disconnectSignal\n'));
    await rfcommChannel.send(bytes);
    // Small delay to let the signal reach the peer before socket closes.
    await Future.delayed(const Duration(milliseconds: 200));
  }

  // Encodes and sends a text message over the RFCOMM socket via the native channel.
  // Appends a newline delimiter for message framing, then writes UTF-8 bytes.
  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    // Encode the message as UTF-8 bytes with newline framing.
    final bytes = Uint8List.fromList(utf8.encode('$text\n'));
    final success = await rfcommChannel.send(bytes);

    if (success) {
      // Create a local ChatMessage marked as sent by user and add to the list.
      final message = ChatMessage(
        messageText: text,
        isSentByUser: true,
      );
      messageList.add(message);
      if (!_messageController.isClosed) {
        _messageController.add(message);
      }
    } else {
      debugPrint('BlueComm: Failed to send message');
    }
  }

  // Releases all resources: cancels the data subscription and closes the stream.
  void dispose() {
    _dataSubscription?.cancel();
    if (!_messageController.isClosed) {
      _messageController.close();
    }
  }
}
