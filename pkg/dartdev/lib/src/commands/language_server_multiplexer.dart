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
    configDir =
        Platform.environment['XDG_CONFIG_HOME'] ??
        p.join(Platform.environment['HOME']!, '.config');
  } else if (Platform.isMacOS) {
    configDir = p.join(
      Platform.environment['HOME']!,
      'Library',
      'Application Support',
    );
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
  final lockFile = File(discoveryFile);
  final portFile = File(p.join(p.dirname(discoveryFile), 'multiplexer.port'));

  RandomAccessFile? raf;
  try {
    raf = lockFile.openSync(mode: FileMode.writeOnlyAppend);
    raf.lockSync(); // Exclusive lock
  } catch (e) {
    stderr.writeln('Error: Failed to acquire lock for multiplexer: $e');
    return 255;
  }

  // Start server socket on a random port
  final serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = serverSocket.port;

  // Write port to port file
  portFile.writeAsStringSync('$port', flush: true);

  // Note: We keep `raf` open and locked for the lifetime of the process.

  stderr.writeln('Multiplexer listening on port $port');

  // Spawn real analysis server
  final script = sdk.analysisServerAotSnapshot;
  if (!checkArtifactExists(script)) {
    stderr.writeln('Error: Analysis server snapshot not found at $script');
    return 255;
  }

  final serverProcess = await Process.start(sdk.dartAotRuntime, [
    script,
    '--protocol=lsp',
  ]);
  stderr.writeln('Spawned real analysis server (PID: ${serverProcess.pid})');

  // Handle server exit
  serverProcess.exitCode.then((code) {
    stderr.writeln('Real analysis server exited with code $code');
    exit(code);
  });

  // Pipe server stderr to multiplexer stderr
  serverProcess.stderr.listen((data) => stderr.add(data));

  // Start multiplexer instance
  final logFile = File(p.join(p.dirname(discoveryFile), 'multiplexer.log'));
  final logSink = logFile.openWrite(mode: FileMode.append);
  stderr.writeln('Logging traffic to ${logFile.path}');
  final multiplexer = Multiplexer(serverProcess, logSink);

  // Listen for client connections
  await for (final socket in serverSocket) {
    stderr.writeln('New client connected');
    multiplexer.addClient(socket);
  }

  return 0;
}

class Multiplexer {
  final Process _serverProcess;
  final IOSink? _logSink;
  final List<Socket> _clients = [];
  final Map<String, _PendingRequest> _pendingRequests = {};
  int _requestIdCounter = 0;

  bool _isServerInitialized = false;
  bool _isAnalyzing = false;
  Map<String, dynamic>? _initializeResult;
  String? _initialInitializeRequestId;

  final Map<Socket, Set<String>> _clientWorkspaces = {};
  Set<String> _currentServerWorkspaces = {};
  final Map<Socket, Map<String, dynamic>> _clientCapabilities = {};
  final Map<Socket, Set<String>> _clientOpenFiles = {};
  final Map<Socket, Set<String>> _clientDirtyFiles = {};
  final Map<String, Socket> _lastWriterPerFile = {};
  final Map<String, String> _cachedDiagnostics = {};
  final List<Map<String, dynamic>> _cachedRegistrations = [];
  final Map<String, dynamic> _pendingServerRequests = {};
  int _serverRequestIdCounter = 0;
  Timer? _shutdownTimer;
  static const Duration _shutdownTimeout = Duration(seconds: 60);

  Multiplexer(this._serverProcess, this._logSink) {
    _serverProcess.stdout
        .cast<List<int>>()
        .transform(LspPacketTransformer())
        .listen(_handleServerMessage);
  }

  void _log(String tag, String message) {
    if (_logSink != null) {
      final now = DateTime.now().toIso8601String();
      _logSink!.writeln('[$now] $tag $message');
    }
  }

  void _sendToClient(Socket client, String payload) {
    client.write(formatLspMessage(payload));
    _log('<== CLIENT', payload);
  }

  void _sendToServer(String payload) {
    _serverProcess.stdin.write(formatLspMessage(payload));
    _log('==> SERVER', payload);
  }

  void addClient(Socket socket) {
    _clients.add(socket);
    stderr.writeln('New client connected');

    if (_shutdownTimer != null) {
      stderr.writeln('Cancelling shutdown timer');
      _shutdownTimer!.cancel();
      _shutdownTimer = null;
    }

    socket
        .cast<List<int>>()
        .transform(LspPacketTransformer())
        .listen(
          (message) {
            _handleClientMessage(socket, message);
          },
          onDone: () {
            _clients.remove(socket);
            _clientWorkspaces.remove(socket);
            _clientOpenFiles.remove(socket);
            _updateServerWorkspaces();
            stderr.writeln('Client disconnected');

            if (_clients.isEmpty) {
              stderr.writeln(
                'All clients disconnected. Starting shutdown timer...',
              );
              _shutdownTimer = Timer(_shutdownTimeout, () {
                stderr.writeln(
                  'Shutdown timeout reached. Shutting down server...',
                );
                _serverProcess.kill();
                exit(0);
              });
            }
          },
        );
  }

  void _handleServerMessage(String messagePayload) {
    _log('<== SERVER', messagePayload);
    final message = jsonDecode(messagePayload) as Map<String, dynamic>;

    if (message.containsKey('id') && !message.containsKey('method')) {
      final serverId = message['id'];
      final pending = _pendingRequests.remove(serverId);
      if (pending != null) {
        if (serverId == _initialInitializeRequestId) {
          _initializeResult = message['result'] as Map<String, dynamic>?;
        }
        if (pending.method == 'textDocument/codeAction') {
          final result = message['result'] as List<dynamic>?;
          if (result != null) {
            if (_anyFileIsDirtyByOthers(pending.client, result)) {
              _sendQuickFixFailed(pending.client, pending.clientId);
              return;
            }
          }
        }
        message['id'] = pending.clientId;
        _sendToClient(pending.client, jsonEncode(message));
      }
    } else if (message.containsKey('id') && message.containsKey('method')) {
      // Request from server to client
      final serverId = message['id'];
      final method = message['method'];
      stderr.writeln('Received request from server: $method');

      Socket? targetClient;

      if (method == 'client/registerCapability') {
        _handleRegisterCapability(message);
        return;
      }

      if (method == 'workspace/applyEdit') {
        final params = message['params'] as Map<String, dynamic>?;
        final edit = params?['edit'] as Map<String, dynamic>?;
        if (edit != null) {
          final changes = edit['changes'] as Map<String, dynamic>?;
          if (changes != null) {
            // Find target client by last writer
            for (final uri in changes.keys) {
              targetClient = _lastWriterPerFile[uri];
              if (targetClient != null) break;
            }
          }
        }
      }

      // Fallback to first client if no target found
      targetClient ??= _clients.isNotEmpty ? _clients.first : null;

      if (targetClient != null) {
        // If it's applyEdit, check for conflicts
        if (method == 'workspace/applyEdit') {
          final params = message['params'] as Map<String, dynamic>?;
          final edit = params?['edit'] as Map<String, dynamic>?;
          final changes = edit?['changes'] as Map<String, dynamic>?;
          if (changes != null) {
            for (final uri in changes.keys) {
              if (_isFileDirtyByOthers(targetClient, uri)) {
                final response = {
                  'jsonrpc': '2.0',
                  'id': serverId,
                  'result': {
                    'applied': false,
                    'failureReason': 'Conflicting unsaved edits in another window.'
                  }
                };
                _sendToServer(jsonEncode(response));
                _sendWarning(targetClient, "Quick fix failed: conflicting unsaved edits in another window.");
                return;
              }
            }
          }
        }

        final clientId = 'srv_req_${_serverRequestIdCounter++}';
        _pendingServerRequests[clientId] = serverId;
        message['id'] = clientId;
        targetClient.write(formatLspMessage(jsonEncode(message)));
      }
    } else {
      // Notification from server to client
      final method = message['method'];

      // Synthesize $/analyzerStatus from $/progress if needed (if the client
      // doesn't support LSP progress messages).
      if (method == r'$/progress') {
        final params = message['params'] as Map<String, dynamic>?;
        if (params?['token'] == 'ANALYZING') {
          final value = params?['value'] as Map<String, dynamic>?;
          final kind = value?['kind'] as String?;
          bool? isAnalyzing;
          if (kind == 'begin') {
            isAnalyzing = true;
          } else if (kind == 'end') {
            isAnalyzing = false;
          }
          if (isAnalyzing != null) {
            _isAnalyzing = isAnalyzing;
            final statusMessage = {
              'jsonrpc': '2.0',
              'method': r'$/analyzerStatus',
              'params': {'isAnalyzing': isAnalyzing},
            };
            for (final client in _clients) {
              final capabilities = _clientCapabilities[client];
              final window = capabilities?['window'] as Map<String, dynamic>?;
              final supportsProgress = window?['workDoneProgress'] == true;
              if (!supportsProgress) {
                _sendToClient(client, jsonEncode(statusMessage));
              }
            }
          }
        }
      }

      if (method == 'textDocument/publishDiagnostics') {
        final params = message['params'] as Map<String, dynamic>?;
        final uri = params?['uri'] as String?;
        if (uri != null) {
          final oldPayload = _cachedDiagnostics[uri];
          if (oldPayload == messagePayload) {
            return; // Skip redundant diagnostics
          }
          _cachedDiagnostics[uri] = messagePayload;
          for (final client in _clients) {
            // Check if client has file open
            final openFiles = _clientOpenFiles[client];
            if (openFiles != null && openFiles.contains(uri)) {
              _sendToClient(client, messagePayload);
              continue;
            }

            // Check if file is in client's workspace
            final workspaces = _clientWorkspaces[client];
            if (workspaces != null) {
              for (final workspaceUri in workspaces) {
                if (uri.startsWith(workspaceUri)) {
                  _sendToClient(client, messagePayload);
                  break; // Found match for this client
                }
              }
            }
          }
          return; // Handled
        }
      }

      // Fallback: broadcast other notifications
      for (final client in _clients) {
        _sendToClient(client, messagePayload);
      }
    }
  }

  void _handleClientMessage(Socket client, String messagePayload) async {
    _log('==> CLIENT', messagePayload);
    final message = jsonDecode(messagePayload) as Map<String, dynamic>;

    if (message.containsKey('id') && message.containsKey('method')) {
      // Message from client to server
      final clientId = message['id'];
      final method = message['method'];

      if (method == 'initialize') {
        final params = message['params'] as Map<String, dynamic>?;
        final workspaceFolders = params?['workspaceFolders'] as List<dynamic>?;
        if (workspaceFolders != null) {
          final folders = workspaceFolders
              .map((f) => f['uri'] as String)
              .toSet();
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
            'result': _initializeResult,
          };
          _sendToClient(client, jsonEncode(response));

          // Check for new capabilities to register with the server.
          final newRegistrations = <Map<String, dynamic>>[];
          capabilities?.forEach((section, features) {
            if (features is! Map<String, dynamic>) return;

            features.forEach((feature, value) {
              if (value == true || value is Map) {
                if (!_anyOtherClientSupports(client, section, feature)) {
                  newRegistrations.add({
                    'id': 'mux_reg_${_requestIdCounter++}',
                    'method': '$section/$feature',
                  });
                }
              }
            });
          });

          if (newRegistrations.isNotEmpty) {
            final regMessage = {
              'jsonrpc': '2.0',
              'method': 'server/registerCapability',
              'params': {'registrations': newRegistrations},
            };
            _sendToServer(jsonEncode(regMessage));
          }
          return;
        } else {
          _initialInitializeRequestId = 'req_${_requestIdCounter++}';
          _pendingRequests[_initialInitializeRequestId!] = _PendingRequest(
            client,
            clientId,
            method as String,
          );
          message['id'] = _initialInitializeRequestId;
          _sendToServer(jsonEncode(message));
          return;
        }
      } else if (method == 'shutdown') {
        // Don't actually forward these, just close the socket after sending a response;
        _sendToClient(client, jsonEncode({'jsonrpc': '2.0', 'id': clientId, 'result': null}));
        await client.flush();
        client.close();
        return;
      }

      final serverId = 'req_${_requestIdCounter++}';
      _pendingRequests[serverId] = _PendingRequest(client, clientId, method as String);
      message['id'] = serverId;
      _sendToServer(jsonEncode(message));
    } else if (message.containsKey('id') && !message.containsKey('method')) {
      // Response from client to server
      final clientId = message['id'];
      final pending = _pendingServerRequests[clientId];

      if (pending is _PendingServerRequest) {
        _pendingServerRequests.remove(clientId);
        pending.pendingClients.remove(client);

        final error = message['error'];
        if (error == null) {
          // Success!
          if (!pending.succeeded) {
            pending.succeeded = true;
            // Send success to server
            final response = {
              'jsonrpc': '2.0',
              'id': pending.serverId,
              'result': null,
            };
            _sendToServer(jsonEncode(response));
          }
        }

        // If all clients responded and none succeeded, send error to server
        if (pending.pendingClients.isEmpty && !pending.succeeded) {
          final response = {
            'jsonrpc': '2.0',
            'id': pending.serverId,
            'error': {
              'code': -32603,
              'message': 'All clients failed to register capability',
            },
          };
          _sendToServer(jsonEncode(response));
        }

        return;
      }

      final serverId = _pendingServerRequests.remove(clientId);
      if (serverId != null) {
        message['id'] = serverId;
        _sendToServer(jsonEncode(message));
      }
    } else {
      // Notifications
      final method = message['method'];
      if (method == 'initialized') {
        if (_isServerInitialized) {
          _replayCachedDiagnostics(client);
          _replayCachedRegistrations(client);
          _sendToClient(
            client,
            jsonEncode({
              'jsonrpc': '2.0',
              'method': r'$/analyzerStatus',
              'params': {'isAnalyzing': _isAnalyzing},
            }),
          );
          return;
        }
        _isServerInitialized = true;
      } else if (method == 'textDocument/didOpen') {
        final params = message['params'] as Map<String, dynamic>?;
        final textDocument = params?['textDocument'] as Map<String, dynamic>?;
        final uri = textDocument?['uri'] as String?;
        if (uri != null) {
          _clientOpenFiles.putIfAbsent(client, () => {}).add(uri);
          _lastWriterPerFile[uri] = client;
          _warnIfDirtyByOthers(client, uri);
        }
      } else if (method == 'textDocument/didChange') {
        final params = message['params'] as Map<String, dynamic>?;
        final textDocument = params?['textDocument'] as Map<String, dynamic>?;
        final uri = textDocument?['uri'] as String?;
        if (uri != null) {
          _clientDirtyFiles.putIfAbsent(client, () => {}).add(uri);
          _lastWriterPerFile[uri] = client;
          _warnOtherClientsIfDirty(client, uri);
        }
      } else if (method == 'textDocument/didSave') {
        final params = message['params'] as Map<String, dynamic>?;
        final textDocument = params?['textDocument'] as Map<String, dynamic>?;
        final uri = textDocument?['uri'] as String?;
        if (uri != null) {
          _clientDirtyFiles[client]?.remove(uri);
        }
      } else if (method == 'textDocument/didClose') {
        final params = message['params'] as Map<String, dynamic>?;
        final textDocument = params?['textDocument'] as Map<String, dynamic>?;
        final uri = textDocument?['uri'] as String?;
        if (uri != null) {
          _clientOpenFiles[client]?.remove(uri);
          _clientDirtyFiles[client]?.remove(uri);
        }
      } else if (method == 'exit') {
        // Close the socket and return, do not send exit message to the actual
        // server.
        client.close();
        return;
      }
      _sendToServer(messagePayload);
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
              'added': foldersToAdd
                  .map((uri) => {'uri': uri, 'name': p.basename(uri)})
                  .toList(),
              'removed': foldersToRemove
                  .map((uri) => {'uri': uri, 'name': p.basename(uri)})
                  .toList(),
            },
          },
        };
        _sendToServer(jsonEncode(notification));
      }
      _currentServerWorkspaces = allFolders;
    }
  }

  void _replayCachedDiagnostics(Socket client) {
    final workspaces = _clientWorkspaces[client];
    final openFiles = _clientOpenFiles[client];

    _cachedDiagnostics.forEach((uri, messagePayload) {
      // Check if client has file open
      if (openFiles != null && openFiles.contains(uri)) {
        _sendToClient(client, messagePayload);
        return;
      }

      // Check if file is in client's workspace
      if (workspaces != null) {
        for (final workspaceUri in workspaces) {
          if (uri.startsWith(workspaceUri)) {
            _sendToClient(client, messagePayload);
            break;
          }
        }
      }
    });
  }

  void _replayCachedRegistrations(Socket client) {
    final clientCaps = _clientCapabilities[client];
    if (clientCaps == null) return;

    final supported = _cachedRegistrations.where((reg) {
      final method = reg['method'] as String;
      return _clientSupportsFeature(clientCaps, method);
    }).toList();

    if (supported.isNotEmpty) {
      final clientId = 'srv_req_${_serverRequestIdCounter++}';
      final clientMessage = {
        'jsonrpc': '2.0',
        'id': clientId,
        'method': 'client/registerCapability',
        'params': {'registrations': supported},
      };
      _sendToClient(client, jsonEncode(clientMessage));
    }
  }

  void _warnIfDirtyByOthers(Socket client, String uri) {
    for (final otherClient in _clients) {
      if (otherClient == client) continue;
      final dirtyFiles = _clientDirtyFiles[otherClient];
      if (dirtyFiles != null && dirtyFiles.contains(uri)) {
        _sendWarning(client, 'Warning: File $uri has unsaved edits in another IDE window. Diagnostics may be misaligned.');
        break;
      }
    }
  }

  void _warnOtherClientsIfDirty(Socket editingClient, String uri) {
    for (final client in _clients) {
      if (client == editingClient) continue;
      final openFiles = _clientOpenFiles[client];
      if (openFiles != null && openFiles.contains(uri)) {
        _sendWarning(client, 'Warning: File $uri has unsaved edits in another IDE window. Diagnostics may be misaligned.');
      }
    }
  }

  void _sendWarning(Socket client, String message) {
    final msg = {
      'jsonrpc': '2.0',
      'method': 'window/showMessage',
      'params': {
        'type': 2, // Warning
        'message': message
      }
    };
    _sendToClient(client, jsonEncode(msg));
  }

  bool _anyFileIsDirtyByOthers(Socket client, List<dynamic> actions) {
    for (final action in actions) {
      if (action is! Map<String, dynamic>) continue;
      final edit = action['edit'] as Map<String, dynamic>?;
      if (edit != null) {
        final changes = edit['changes'] as Map<String, dynamic>?;
        if (changes != null) {
          for (final uri in changes.keys) {
            if (_isFileDirtyByOthers(client, uri)) {
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  bool _isFileDirtyByOthers(Socket client, String uri) {
    for (final otherClient in _clients) {
      if (otherClient == client) continue;
      final dirtyFiles = _clientDirtyFiles[otherClient];
      if (dirtyFiles != null && dirtyFiles.contains(uri)) {
        return true;
      }
    }
    return false;
  }

  void _sendQuickFixFailed(Socket client, dynamic clientId) {
    final response = {
      'jsonrpc': '2.0',
      'id': clientId,
      'error': {
        'code': -32603,
        'message': 'Quick fix failed. Some files have unsaved edits in another window. Please save them first.'
      }
    };
    _sendToClient(client, jsonEncode(response));
    _sendWarning(client, "Quick fix failed: conflicting unsaved edits in another window.");
  }

  void _handleRegisterCapability(Map<String, dynamic> message) {
    final serverId = message['id'];
    final params = message['params'] as Map<String, dynamic>?;
    final registrations = params?['registrations'] as List<dynamic>?;
    if (registrations == null) return;

    // Cache registrations for late-joining clients
    for (final reg in registrations) {
      _cachedRegistrations.add(reg as Map<String, dynamic>);
    }

    final supportingClients = <Socket>{};
    final clientRegistrations = <Socket, List<dynamic>>{};

    for (final client in _clients) {
      final clientCaps = _clientCapabilities[client];
      if (clientCaps == null) continue;

      final supported = registrations.where((reg) {
        final method = reg['method'] as String;
        return _clientSupportsFeature(clientCaps, method);
      }).toList();

      if (supported.isNotEmpty) {
        supportingClients.add(client);
        clientRegistrations[client] = supported;
      }
    }

    if (supportingClients.isNotEmpty) {
      final pendingRequest = _PendingServerRequest(
        serverId,
        Set.from(supportingClients),
      );

      for (final client in supportingClients) {
        final clientId = 'srv_req_${_serverRequestIdCounter++}';
        _pendingServerRequests[clientId] = pendingRequest;

        final clientMessage = {
          'jsonrpc': '2.0',
          'id': clientId,
          'method': 'client/registerCapability',
          'params': {'registrations': clientRegistrations[client]},
        };
        _sendToClient(client, jsonEncode(clientMessage));
      }
    } else {
      stderr.writeln(
        'No client supports any of the requested capabilities: $registrations',
      );
      final response = {
        'jsonrpc': '2.0',
        'id': serverId,
        'error': {
          'code': -32601,
          'message': 'No client supports any of the requested capabilities',
        },
      };
      _sendToServer(jsonEncode(response));
    }
  }

  bool _clientSupportsFeature(
    Map<String, dynamic> capabilities,
    String method,
  ) {
    final parts = method.split('/');
    if (parts.length != 2) return false;

    final section = parts[0];
    final feature = parts[1];

    final sectionMap = capabilities[section] as Map<String, dynamic>?;
    if (sectionMap == null) return false;

    // Special case for document synchronization methods which are grouped under
    // 'synchronization' in client capabilities.
    if (section == 'textDocument' &&
        (feature == 'didOpen' ||
            feature == 'didChange' ||
            feature == 'didClose' ||
            feature == 'didSave')) {
      final syncMap = sectionMap['synchronization'] as Map<String, dynamic>?;
      if (syncMap != null) {
        final dynamicRegistration = syncMap['dynamicRegistration'];
        if (dynamicRegistration is bool) return dynamicRegistration;
      }
    }

    final featureMap = sectionMap[feature];
    if (featureMap == null) return false;

    if (featureMap is bool) return featureMap;
    if (featureMap is Map) return true;

    return false;
  }

  bool _anyOtherClientSupports(
    Socket currentClient,
    String section,
    String feature,
  ) {
    for (final client in _clients) {
      if (client == currentClient) continue;
      final caps = _clientCapabilities[client];
      if (caps == null) continue;
      final sec = caps[section] as Map<String, dynamic>?;
      if (sec == null) continue;
      final feat = sec[feature];
      if (feat == true || feat is Map) return true;
    }
    return false;
  }
}

class _PendingRequest {
  final Socket client;
  final dynamic clientId;
  final String method;
  _PendingRequest(this.client, this.clientId, this.method);
}

class _PendingServerRequest {
  final dynamic serverId;
  final Set<Socket> pendingClients;
  bool succeeded = false;
  _PendingServerRequest(this.serverId, this.pendingClients);
}

String formatLspMessage(String jsonPayload) {
  return 'Content-Length: ${utf8.encode(jsonPayload).length}\r\n\r\n$jsonPayload';
}

/// Runs the client proxy that connects to the multiplexer.
Future<int> runClientProxy(ArgResults argResults) async {
  final discoveryFile = getDiscoveryFilePath();
  final lockFile = File(discoveryFile);
  final portFile = File(p.join(p.dirname(discoveryFile), 'multiplexer.port'));

  RandomAccessFile? raf;
  bool ownsLock = false;

  try {
    raf = lockFile.openSync(mode: FileMode.writeOnlyAppend);
    raf.lockSync();
    ownsLock = true;
  } catch (_) {
    ownsLock = false;
  }

  if (ownsLock) {
    portFile.writeAsStringSync('', flush: true); // Truncate port file!
    raf?.closeSync(); // Release lock so detached process can get it.

    // Spawn detached multiplexer
    final dartPath = Platform.executable;
    Process.start(dartPath, [
      'language-server',
      '--multiplexer',
    ], mode: ProcessStartMode.detached);

    // Wait for the file to be written by the multiplexer
    int attempts = 0;
    while (attempts < 50) {
      try {
        final content = portFile.readAsStringSync();
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
    final content = portFile.readAsStringSync();
    if (content.isEmpty) {
      stderr.writeln('Error: Failed to connect to multiplexer (file empty)');
      return 255;
    }

    final port = int.tryParse(content.trim());
    if (port == null) {
      stderr.writeln('Error: Invalid connection info in lock file: $content');
      return 255;
    }

    Socket? socket;
    int connectAttempts = 0;
    while (connectAttempts < 20) {
      try {
        socket = await Socket.connect('localhost', port);
        break;
      } catch (e) {
        connectAttempts++;
        if (connectAttempts >= 20) {
          stderr.writeln('Error: Failed to connect to multiplexer: $e');
          return 255;
        }
        await Future.delayed(Duration(milliseconds: 200));
      }
    }

    // Pipe stdin to socket and socket to stdout
    // Note: pipe closes the destination by default.
    // For a proxy, we might need to handle streams manually to keep them open or handle close correctly.
    // But for a simple proxy, pipe might be okay if the server closes the socket when done.
    // Let's use a simple pipe for now.
    final s = socket!;
    stdin.listen((data) => s.add(data), onDone: () => s.close());
    s.listen((data) => stdout.add(data), onDone: () => exit(0));

    await s.done;
    return 0;
  } catch (e) {
    stderr.writeln('Error: Failed to connect to multiplexer: $e');
    return 255;
  }
}
