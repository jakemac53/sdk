// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analysis_server/src/lsp/lsp_packet_transformer.dart';
import 'package:analysis_server_client/protocol.dart'
    show
        AddContentOverlay,
        AnalysisUpdateContentParams,
        EditBulkFixesResult,
        ResponseDecoder;

import 'package:args/args.dart';
import 'package:path/path.dart' as path;

import 'core.dart';
import 'sdk.dart';
import 'utils.dart';

/// When set, this function is executed just before the Analysis Server starts.
void Function(
  String cmdName,
  List<FileSystemEntity> analysisRoots,
  ArgResults? argResults,
)?
preAnalysisServerStart;

/// A class to provide an API wrapper around an analysis server process.
class AnalysisServer {
  AnalysisServer(
    this.packagesFile,
    this.sdkPath,
    this.analysisRoots, {
    this.cacheDirectoryPath,
    required this.commandName,
    required this.argResults,
    required this._usePlugins,
    this.enabledExperiments = const [],
    this.disableStatusNotificationDebouncing = false,
    this.suppressAnalytics = false,
    this._useAotSnapshot = false,
    this.socket,
  });

  final String? cacheDirectoryPath;
  final File? packagesFile;
  final Directory sdkPath;
  final List<FileSystemEntity> analysisRoots;
  final String commandName;
  final ArgResults? argResults;
  final List<String> enabledExperiments;
  final bool disableStatusNotificationDebouncing;
  final bool suppressAnalytics;
  final bool _useAotSnapshot;
  final bool _usePlugins;
  final Socket? socket;

  Process? _process;

  /// When not null, this is a [Completer] which completes when analysis has
  /// finished, otherwise `null`.
  Completer<bool>? _analysisFinished;

  int _id = 0;

  bool _shutdownResponseReceived = false;

  bool _serverErrorReceived = false;

  /// Whether any server error occurred that could mean analysis was not
  /// performed correctly.
  bool get serverErrorReceived => _serverErrorReceived;

  Stream<bool> get onAnalyzing {
    return _streamController(
      r'$/analyzerStatus',
    ).stream.map((event) => event['isAnalyzing'] as bool);
  }

  /// This future completes when we next receive an analysis finished event
  /// (unless there's no current analysis and we've already received a complete
  /// event, in which case this future completes immediately).
  Future<bool>? get analysisFinished => _analysisFinished?.future;

  Stream<FileAnalysisErrors> get onErrors {
    return _streamController('textDocument/publishDiagnostics').stream.map((
      event,
    ) {
      final uri = event['uri'] as String;
      final file = path.fromUri(uri);
      final diagnostics = event['diagnostics'] as List<dynamic>;
      final errors = [
        for (final diagnostic in diagnostics)
          AnalysisError(
            _translateDiagnostic(file, diagnostic as Map<String, dynamic>),
          ),
      ];
      return FileAnalysisErrors(file, errors);
    });
  }

  Map<String, dynamic> _translateDiagnostic(
    String file,
    Map<String, dynamic> diagnostic,
  ) {
    final range = diagnostic['range'] as Map<String, dynamic>;
    final start = range['start'] as Map<String, dynamic>;

    final startLine = (start['line'] as int) + 1;
    final startColumn = (start['character'] as int) + 1;

    final severity = diagnostic['severity'] as int?;
    String severityStr;
    switch (severity) {
      case 1:
        severityStr = 'ERROR';
        break;
      case 2:
        severityStr = 'WARNING';
        break;
      case 3:
        severityStr = 'INFO';
        break;
      case 4:
        severityStr = 'INFO'; // Hint
        break;
      default:
        severityStr = 'INFO';
    }

    return {
      'severity': severityStr,
      'type': 'LINT', // Default type
      'location': {
        'file': file,
        'offset': startLine * 1000 + startColumn, // Dummy offset for sorting
        'length': 0, // Dummy length
        'startLine': startLine,
        'startColumn': startColumn,
      },
      'message': diagnostic['message'],
      'code': diagnostic['code']?.toString() ?? '',
    };
  }

  Future<int> get onExit {
    final p = _process;
    if (p != null) {
      return p.exitCode;
    }
    final s = socket;
    if (s != null) {
      return s.done.then((_) => 0);
    }
    return Future.value(0);
  }

  final Map<String, StreamController<Map<String, dynamic>>> _streamControllers =
      {};

  /// Completes when an analysis server crash has been detected.
  Future<void> get onCrash => _onCrash.future;

  final _onCrash = Completer<void>();

  final Map<String, Completer<Map<String, dynamic>>> _requestCompleters = {};

  /// Starts the process and returns the pid for it.
  Future<int> start({bool setAnalysisRoots = true}) async {
    preAnalysisServerStart?.call(commandName, analysisRoots, argResults);

    _analysisFinished = Completer<bool>();

    if (socket != null) {
      _shutdownResponseReceived = false;
    } else {
      final process = await _startProcess();
      _process = process;
      _shutdownResponseReceived = false;
      // This callback hookup can't throw.
      process.exitCode
          .then((code) {
            log.stderr('Analysis server process exited with code: $code');
          })
          .whenComplete(() {
            _process = null;

            if (!_shutdownResponseReceived) {
              // The process exited unexpectedly. Report the crash.
              final error = StateError(
                'The analysis server crashed unexpectedly',
              );

              final analysisFinished = _analysisFinished;
              if (analysisFinished != null && !analysisFinished.isCompleted) {
                // Complete this completer in order to unstick the process.
                analysisFinished.completeError(error);
              }

              // Complete these completers in order to unstick the process.
              for (final completer in _requestCompleters.values) {
                completer.completeError(error);
              }

              _onCrash.complete();
            }
          });

      final errorStream = process.stderr
          .transform<String>(utf8.decoder)
          .transform<String>(const LineSplitter());
      errorStream.listen(log.stderr);
    }

    final analysisRootPaths = [
      for (final root in analysisRoots)
        trimEnd(
          (root is File ? root.parent : root).absolute
              .resolveSymbolicLinksSync(),
          path.context.separator,
        ),
    ].toSet().toList();

    final streamSource = socket ?? _process!.stdout;

    final inStream = streamSource.cast<List<int>>().transform(
      LspPacketTransformer(),
    );
    inStream.listen(_handleServerResponse);

    final analysisRootUris = analysisRootPaths
        .map((p) => path.toUri(p).toString())
        .toList();
    final rootUri = analysisRootUris.isNotEmpty ? analysisRootUris.first : null;

    // LSP Handshake
    await _sendCommand(
      'initialize',
      params: <String, dynamic>{
        'processId': null,
        'rootUri': rootUri,
        'capabilities': <String, dynamic>{},
        if (setAnalysisRoots && analysisRootUris.isNotEmpty)
          'workspaceFolders': analysisRootUris
              .map((uri) => {'uri': uri, 'name': path.basename(uri)})
              .toList(),
      },
    );

    await _sendNotification('initialized');

    onAnalyzing.listen((isAnalyzing) {
      final analysisFinished = _analysisFinished;
      if (isAnalyzing && (analysisFinished?.isCompleted ?? true)) {
        // Start a new completer, to be completed when we receive the
        // corresponding analysis complete event.
        _analysisFinished = Completer();
      } else if (!isAnalyzing) {
        if (analysisFinished != null && !analysisFinished.isCompleted) {
          analysisFinished.complete(true);
        }
      }
    });

    return socket != null ? 0 : _process!.pid;
  }

  Future<Process> _startProcess() {
    final executable = sdk.dart;
    final arguments = [
      'language-server',
      '--protocol=lsp',
      '--client-id=dart-$commandName',
      '--dart-sdk=${sdkPath.path}',
      if (cacheDirectoryPath != null) '--cache=$cacheDirectoryPath',
      if (packagesFile != null) '--packages=${packagesFile!.path}',
    ];

    log.trace('$executable ${arguments.join(' ')}');
    return Process.start(executable, arguments);
  }

  Future<String> getVersion() {
    return _sendCommand(
      'server.getVersion',
    ).then((response) => response['version']);
  }

  Future<EditBulkFixesResult> requestBulkFixes(
    String filePath,
    bool inTestMode,
    List<String> codes, {
    bool updatePubspec = false,
  }) {
    return _sendCommand(
      'edit.bulkFixes',
      params: <String, dynamic>{
        'included': [path.canonicalize(filePath)],
        'inTestMode': inTestMode,
        'updatePubspec': updatePubspec,
        if (codes.isNotEmpty) 'codes': codes,
      },
    ).then((result) {
      return EditBulkFixesResult.fromJson(
        ResponseDecoder(null),
        'result',
        result,
      );
    });
  }

  Future<void> shutdown({Duration? timeout}) async {
    // Request shutdown.
    final Future<void> future = _sendCommand('shutdown').then((
      Map<String, dynamic> value,
    ) {
      _shutdownResponseReceived = true;
      _sendNotification('exit');
      return;
    });
    await (timeout != null
            ? future.timeout(
                timeout,
                onTimeout: () {
                  log.stderr(
                    'The analysis server timed out while shutting down.',
                  );
                },
              )
            : future)
        .whenComplete(dispose);
  }

  /// Send an `analysis.updateContent` request with the given [files].
  Future<void> updateContent(Map<String, AddContentOverlay> files) async {
    await _sendCommand(
      'analysis.updateContent',
      params: AnalysisUpdateContentParams(files).toJson(),
    );
  }

  Future<Map<String, dynamic>> _sendCommand(
    String method, {
    Map<String, dynamic>? params,
  }) async {
    final String id = (++_id).toString();
    final String message = json.encode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });

    final payload =
        'Content-Length: ${utf8.encode(message).length}\r\n\r\n$message';

    final Completer<Map<String, dynamic>> completer = Completer();

    _requestCompleters[id] = completer;

    if (socket != null) {
      socket!.write(payload);
      await socket!.flush();
    } else {
      _process!.stdin.write(payload);
      await _process!.stdin.flush();
    }

    log.trace('==> $payload');

    return completer.future;
  }

  Future<void> _sendNotification(
    String method, {
    Map<String, dynamic>? params,
  }) async {
    final String message = json.encode(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });

    final payload =
        'Content-Length: ${utf8.encode(message).length}\r\n\r\n$message';

    if (socket != null) {
      socket!.write(payload);
      await socket!.flush();
    } else {
      _process!.stdin.write(payload);
      await _process!.stdin.flush();
    }

    log.trace('==> $payload');
  }

  void _handlePluginError(Map<String, dynamic>? error) {
    _serverErrorReceived = true;
    final err = error!;
    // No need for a preamble (like in _handleServerError); the message should
    // have all of the context necessary.
    log.stderr(err['message']);
    final stackTrace = err['stackTrace'];
    if (stackTrace is String && stackTrace.isNotEmpty) {
      log.stderr(stackTrace);
    }
  }

  void _handleServerResponse(String message) {
    log.trace('<== $message');

    final response = json.decode(message) as Object?;

    if (response is Map<String, dynamic>) {
      if (response.containsKey('id')) {
        // Response or Request
        final id = response['id'].toString();
        if (response.containsKey('method')) {
          // Request from server to client (not expected in this simple client)
          log.trace('Received request from server: ${response['method']}');
        } else {
          // Response to a request we sent
          if (response.containsKey('error')) {
            final error = response['error'] as Map<String, dynamic>;
            _requestCompleters
                .remove(id)
                ?.completeError(
                  RequestError(
                    error['code']?.toString() ?? '',
                    error['message'] as String? ?? '',
                    stackTrace: error['data']?.toString() ?? '',
                  ),
                );
          } else {
            _requestCompleters
                .remove(id)
                ?.complete(
                  (response['result'] as Map<String, dynamic>?) ?? {},
                );
          }
        }
      } else if (response.containsKey('method')) {
        // Notification
        final method = response['method'] as String;
        final params = response['params'] as Map<String, dynamic>?;

        if (method == r'$/progress') {
          final token = params?['token'];
          if (token == 'ANALYZING') {
            final value = params?['value'] as Map<String, dynamic>?;
            final kind = value?['kind'] as String?;
            if (kind == 'begin') {
              _streamController(r'$/analyzerStatus').add({'isAnalyzing': true});
            } else if (kind == 'end') {
              _streamController(
                r'$/analyzerStatus',
              ).add({'isAnalyzing': false});
            }
          }
        }

        // Route notifications to stream controllers based on method name.
        _streamController(method).add(params ?? {});
      }
    }
  }

  StreamController<Map<String, dynamic>> _streamController(String streamId) {
    return _streamControllers.putIfAbsent(
      streamId,
      () => StreamController<Map<String, dynamic>>.broadcast(),
    );
  }

  Future<bool> dispose() async {
    socket?.destroy();
    return _process?.kill() ?? true;
  }
}

enum _AnalysisSeverity { error, warning, info, none }

class AnalysisError implements Comparable<AnalysisError> {
  AnalysisError(this.json);

  static final Map<String, _AnalysisSeverity> _severityMap =
      <String, _AnalysisSeverity>{
        'INFO': _AnalysisSeverity.info,
        'WARNING': _AnalysisSeverity.warning,
        'ERROR': _AnalysisSeverity.error,
      };

  // "severity":"INFO","type":"TODO","location":{
  //   "file":"/Users/.../lib/test.dart","offset":362,"length":72,"startLine":15,"startColumn":4
  // },"message":"...","hasFix":false}
  Map<String, dynamic> json;

  String? get severity => json['severity'] as String?;

  _AnalysisSeverity get _severityLevel =>
      _severityMap[severity!] ?? _AnalysisSeverity.none;

  bool get isInfo => _severityLevel == _AnalysisSeverity.info;

  bool get isWarning => _severityLevel == _AnalysisSeverity.warning;

  bool get isError => _severityLevel == _AnalysisSeverity.error;

  String get type => json['type'] as String;

  String get message => json['message'] as String;

  String get code => json['code'] as String;

  String? get correction => json['correction'] as String?;

  int? get endColumn => json['location']['endColumn'] as int?;

  int? get endLine => json['location']['endLine'] as int?;

  String get file => json['location']['file'] as String;

  int? get startLine => json['location']['startLine'] as int?;

  int? get startColumn => json['location']['startColumn'] as int?;

  int get offset => json['location']['offset'] as int;

  int get length => json['location']['length'] as int;

  String? get url => json['url'] as String?;

  List<DiagnosticMessage> get contextMessages {
    var messages = json['contextMessages'] as List<dynamic>?;
    if (messages == null) {
      // The field is optional, so we return an empty list as a default value.
      return [];
    }
    return messages.map((message) => DiagnosticMessage(message)).toList();
  }

  @override
  int compareTo(AnalysisError other) {
    // Sort in order of severity, file path, error location, and message.
    final int diff = _severityLevel.index - other._severityLevel.index;
    if (diff != 0) {
      return diff;
    }

    if (file != other.file) {
      return file.compareTo(other.file);
    }

    if (offset != other.offset) {
      return offset - other.offset;
    }

    return message.compareTo(other.message);
  }

  @override
  String toString() =>
      '${severity!.toLowerCase()} • '
      '$message • $file:$startLine:$startColumn • '
      '($code)';
}

class DiagnosticMessage {
  final Map<String, dynamic> json;

  DiagnosticMessage(this.json);

  int? get column => json['location']['startColumn'] as int?;

  int? get endColumn => json['location']['endColumn'] as int?;

  int? get endLine => json['location']['endLine'] as int?;

  String get filePath => json['location']['file'] as String;

  int get length => json['location']['length'] as int;

  int get line => json['location']['startLine'] as int;

  String get message => json['message'] as String;

  int get offset => json['location']['offset'] as int;
}

class FileAnalysisErrors {
  final String file;
  final List<AnalysisError> errors;

  FileAnalysisErrors(this.file, this.errors);
}

class RequestError {
  static RequestError parse(dynamic error) {
    return RequestError(
      error['code'],
      error['message'],
      stackTrace: error['stackTrace'],
    );
  }

  final String code;
  final String message;
  final String stackTrace;

  RequestError(this.code, this.message, {required this.stackTrace});

  @override
  String toString() => '[RequestError code: $code, message: $message]';
}
