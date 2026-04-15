// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analysis_server/src/lsp/lsp_packet_transformer.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../sdk.dart';

/// Returns the path to the discovery file used by the multiplexer.
String getDiscoveryFilePath() {
  String configDir;
  if (Platform.isLinux) {
    configDir = Platform.environment['XDG_CONFIG_HOME'] ??
        p.join(Platform.environment['HOME']!, '.config');
  } else if (Platform.isMacOS) {
    configDir = p.join(Platform.environment['HOME']!, 'Library', 'Application Support');
  } else if (Platform.isWindows) {
    configDir = Platform.environment['APPDATA']!;
  } else {
    // Fallback to home directory if platform is not recognized
    configDir = Platform.environment['HOME'] ?? '.';
  }

  final dir = Directory(p.join(configDir, 'dart-language-server'));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return p.join(dir.path, 'multiplexer.lock');
}

/// Runs the multiplexer server.
Future<int> runMultiplexer() async {
  final discoveryFile = getDiscoveryFilePath();
  final file = File(discoveryFile);

  RandomAccessFile? raf;
  try {
    raf = file.openSync(mode: FileMode.writeOnly);
    raf.lockSync(); // Exclusive lock
  } catch (e) {
    stderr.writeln('Error: Failed to acquire lock for multiplexer: $e');
    return 255;
  }

  // Start server socket on a random port
  final serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = serverSocket.port;

  // Write port to file
  raf.truncateSync(0);
  raf.writeStringSync('$port');
  raf.flushSync();

  // Note: We keep `raf` open and locked for the lifetime of the process.

  stderr.writeln('Multiplexer listening on port $port');

  // Spawn real analysis server
  final script = sdk.analysisServerAotSnapshot;
  if (!checkArtifactExists(script)) {
    stderr.writeln('Error: Analysis server snapshot not found at $script');
    return 255;
  }

  final serverProcess = await Process.start(Platform.executable, [script, '--protocol=lsp']);
  stderr.writeln('Spawned real analysis server (PID: ${serverProcess.pid})');

  // Handle server exit
  serverProcess.exitCode.then((code) {
    stderr.writeln('Real analysis server exited with code $code');
    exit(code);
  });

  // Pipe server stderr to multiplexer stderr
  serverProcess.stderr.listen((data) => stderr.add(data));

  // Start multiplexer instance
  final multiplexer = Multiplexer(serverProcess);

  // Listen for client connections
  await for (final socket in serverSocket) {
    stderr.writeln('New client connected');
    multiplexer.addClient(socket);
  }

  return 0;
}

class Multiplexer {
  final Process _serverProcess;
  final List<Socket> _clients = [];
  final Map<String, _PendingRequest> _pendingRequests = {};
  int _requestIdCounter = 0;

  bool _isServerInitialized = false;
  Map<String, dynamic>? _initializeResult;
  String? _initialInitializeRequestId;

  final Map<Socket, Set<String>> _clientWorkspaces = {};
  Set<String> _currentServerWorkspaces = {};
  final Map<Socket, Map<String, dynamic>> _clientCapabilities = {};

  Multiplexer(this._serverProcess) {
    _serverProcess.stdout
        .cast<List<int>>()
        .transform(LspPacketTransformer())
        .listen(_handleServerMessage);
  }

  void addClient(Socket socket) {
    _clients.add(socket);
    socket
        .cast<List<int>>()
        .transform(LspPacketTransformer())
        .listen((message) {
          _handleClientMessage(socket, message);
        }, onDone: () {
          _clients.remove(socket);
          _clientWorkspaces.remove(socket);
          _updateServerWorkspaces();
          stderr.writeln('Client disconnected');
        });
  }

  void _handleServerMessage(String messagePayload) {
    final message = jsonDecode(messagePayload) as Map<String, dynamic>;

    if (message.containsKey('id') && !message.containsKey('method')) {
      final serverId = message['id'];
      final pending = _pendingRequests.remove(serverId);
      if (pending != null) {
        if (serverId == _initialInitializeRequestId) {
          _initializeResult = message['result'] as Map<String, dynamic>?;
        }
        message['id'] = pending.clientId;
        pending.client.write(formatLspMessage(jsonEncode(message)));
      }
    } else if (message.containsKey('id') && message.containsKey('method')) {
      // Request from server to client
      final method = message['method'];
      stderr.writeln('Received request from server: $method');

      // TODO: Implement proper routing and ID mapping for server requests.
      // For now, route to the first client as a fallback.
      if (_clients.isNotEmpty) {
        _clients.first.write(formatLspMessage(messagePayload));
      }
    } else {
      for (final client in _clients) {
        client.write(formatLspMessage(messagePayload));
      }
    }
  }

  void _handleClientMessage(Socket client, String messagePayload) {
    final message = jsonDecode(messagePayload) as Map<String, dynamic>;

    if (message.containsKey('id') && message.containsKey('method')) {
      final clientId = message['id'];
      final method = message['method'];

      if (method == 'initialize') {
        final params = message['params'] as Map<String, dynamic>?;
        final workspaceFolders = params?['workspaceFolders'] as List<dynamic>?;
        if (workspaceFolders != null) {
          final folders = workspaceFolders.map((f) => f['uri'] as String).toSet();
          _clientWorkspaces[client] = folders;
          _updateServerWorkspaces();
        }

        final capabilities = params?['capabilities'] as Map<String, dynamic>?;
        if (capabilities != null) {
          _clientCapabilities[client] = capabilities;
        }

        if (_isServerInitialized) {
          final response = {
            'jsonrpc': '2.0',
            'id': clientId,
            'result': _initializeResult
          };
          client.write(formatLspMessage(jsonEncode(response)));
          return;
        } else {
          _initialInitializeRequestId = 'req_${_requestIdCounter++}';
          _pendingRequests[_initialInitializeRequestId!] = _PendingRequest(client, clientId);
          message['id'] = _initialInitializeRequestId;
          _serverProcess.stdin.write(formatLspMessage(jsonEncode(message)));
          return;
        }
      }

      final serverId = 'req_${_requestIdCounter++}';
      _pendingRequests[serverId] = _PendingRequest(client, clientId);
      message['id'] = serverId;
      _serverProcess.stdin.write(formatLspMessage(jsonEncode(message)));
    } else {
      if (message['method'] == 'initialized') {
        if (_isServerInitialized) {
          return;
        }
        _isServerInitialized = true;
      }
      _serverProcess.stdin.write(formatLspMessage(messagePayload));
    }
  }

  void _updateServerWorkspaces() {
    final allFolders = <String>{};
    for (final folders in _clientWorkspaces.values) {
      allFolders.addAll(folders);
    }

    final foldersToAdd = allFolders.difference(_currentServerWorkspaces);
    final foldersToRemove = _currentServerWorkspaces.difference(allFolders);

    if (foldersToAdd.isNotEmpty || foldersToRemove.isNotEmpty) {
      if (_isServerInitialized) {
        final notification = {
          'jsonrpc': '2.0',
          'method': 'workspace/didChangeWorkspaceFolders',
          'params': {
            'event': {
              'added': foldersToAdd.map((uri) => {'uri': uri, 'name': p.basename(uri)}).toList(),
              'removed': foldersToRemove.map((uri) => {'uri': uri, 'name': p.basename(uri)}).toList(),
            }
          }
        };
        _serverProcess.stdin.write(formatLspMessage(jsonEncode(notification)));
      }
      _currentServerWorkspaces = allFolders;
    }
  }
}

class _PendingRequest {
  final Socket client;
  final dynamic clientId;
  _PendingRequest(this.client, this.clientId);
}

String formatLspMessage(String jsonPayload) {
  return 'Content-Length: ${utf8.encode(jsonPayload).length}\r\n\r\n$jsonPayload';
}

/// Runs the client proxy that connects to the multiplexer.
Future<int> runClientProxy(ArgResults argResults) async {
  final discoveryFile = getDiscoveryFilePath();
  final file = File(discoveryFile);

  RandomAccessFile? raf;
  bool ownsLock = false;

  try {
    raf = file.openSync(mode: FileMode.writeOnlyAppend);
    try {
      raf.lockSync();
      ownsLock = true;
    } catch (_) {
      ownsLock = false;
    }
  } catch (_) {
    ownsLock = false;
  }

  if (ownsLock) {
    raf?.closeSync(); // Release lock so detached process can get it.

    // Spawn detached multiplexer
    final dartPath = Platform.executable;
    // We pass the same arguments we received, plus the --multiplexer flag.
    // Wait, we should only pass relevant arguments or just spawn it.
    // The user said "possibly spawning it as a detached process if there is no active one."
    // Let's spawn it with the --multiplexer flag.
    Process.start(dartPath, ['language-server', '--multiplexer'], mode: ProcessStartMode.detached);

    // Wait for the file to be written by the multiplexer
    int attempts = 0;
    while (attempts < 50) {
      try {
        final content = file.readAsStringSync();
        if (content.isNotEmpty) {
          break;
        }
      } catch (_) {
        // File might be locked or not readable yet
      }
      await Future.delayed(Duration(milliseconds: 100));
      attempts++;
    }
  }

  // Now read the file and connect.
  try {
    final content = file.readAsStringSync();
    if (content.isEmpty) {
      stderr.writeln('Error: Failed to connect to multiplexer (file empty)');
      return 255;
    }

    final port = int.tryParse(content.trim());
    if (port == null) {
      stderr.writeln('Error: Invalid connection info in lock file: $content');
      return 255;
    }

    final socket = await Socket.connect('localhost', port);

    // Pipe stdin to socket and socket to stdout
    // Note: pipe closes the destination by default.
    // For a proxy, we might need to handle streams manually to keep them open or handle close correctly.
    // But for a simple proxy, pipe might be okay if the server closes the socket when done.
    // Let's use a simple pipe for now.
    stdin.listen((data) => socket.add(data), onDone: () => socket.close());
    socket.listen((data) => stdout.add(data), onDone: () => exit(0));

    await socket.done;
    return 0;
  } catch (e) {
    stderr.writeln('Error: Failed to connect to multiplexer: $e');
    return 255;
  }
}
