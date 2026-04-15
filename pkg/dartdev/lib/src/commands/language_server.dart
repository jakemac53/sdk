// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/src/server/driver.dart' as server;
import 'package:args/args.dart';

import '../core.dart';
import '../sdk.dart';
import '../utils.dart';
import 'language_server_multiplexer.dart';

class LanguageServerCommand extends DartdevCommand {
  static const String commandName = 'language-server';

  @override
  CommandCategory get commandCategory => CommandCategory.tools;

  static const String commandDescription = '''
Start Dart's analysis server.

This is a long-running process used to provide language services to IDEs and other tooling clients.

It communicates over stdin and stdout and provides services like code completion, errors and warnings, and refactorings. This command is generally not user-facing but consumed by higher level tools.

For more information about the server's capabilities and configuration, see:

  https://github.com/dart-lang/sdk/tree/main/pkg/analysis_server''';

  LanguageServerCommand({bool verbose = false})
    : super(commandName, commandDescription, verbose, hidden: !verbose);

  @override
  ArgParser createArgParser() {
    return server.Driver.createArgParser(
      usageLineLength: dartdevUsageLineLength,
      includeHelpFlag: false,
      defaultToLsp: true,
    )..addFlag(
      useAotSnapshotFlag,
      help: 'Use the AOT analysis server snapshot',
      defaultsTo: true,
      hide: true,
    )..addFlag(
      'multiplexer',
      help: 'Run the analysis server multiplexer',
      defaultsTo: false,
      hide: true,
    );
  }

  @override
  Future<int> run() async {
    if (argResults!['multiplexer'] as bool? ?? false) {
      return runMultiplexer();
    }
    return runClientProxy(argResults!);
  }
}
