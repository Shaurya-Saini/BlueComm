# BlueComm: Bluetooth Classic Based Android Messaging System

BlueComm is a standalone Android messaging application developed using Flutter. It enables two Android devices to seamlessly discover each other over Bluetooth Classic, establish a robust RFCOMM connection, and exchange messages in real-time. The application operates entirely offline without any reliance on external servers, databases, or cloud infrastructure, ensuring session-based, localized communication.

<!-- ![BlueComm App Screenshots](insert_image_link_here) -->

## Features
- **Device Discovery:** Scan for, and list nearby paired Bluetooth devices.
- **Offline Messaging:** Chat in real-time without Wi-Fi, cellular data, or internet access.
- **Bidirectional Communication:** Send and receive UTF-8 encoded text seamlessly.
- **No Cloud Dependency:** Complete privacy and direct device-to-device connectivity.

## Technical Details:

The application uses native Android API bridges via Flutter platform channels to manage Bluetooth connections. Communication relies on the RFCOMM protocol, which acts like a serial port emulation over Bluetooth.

When connecting, the app executes a **3-tier RFCOMM fallback strategy** to maximize compatibility across different Android hardware and OS versions:
1. **Standard SPP:** Attempts a standard secure connection using `createRfcommSocketToServiceRecord(SPP_UUID)`.
2. **Reflection Fallback:** Uses `createRfcommSocket(1)` to bypass SDP (Service Discovery Protocol) lookup if the standard approach fails (common on some devices).
3. **Insecure SPP:** Falls back to `createInsecureRfcommSocketToServiceRecord(SPP_UUID)` if secure channels are unavailable.

Concurrently, every device running BlueComm spins up a background **Server Socket** that listens for incoming connections on the SPP UUID. When Device A initiates a connection to Device B, Device B's server socket automatically accepts the incoming request. Once accepted, both devices transition to the chat interface utilizing the established bidirectional stream.

## Setup & Run Instructions

For complete setup, project dependencies, permissions configuration, and running directions, please carefully review the [`instructions.md`](./instructions.md) file included in this project.