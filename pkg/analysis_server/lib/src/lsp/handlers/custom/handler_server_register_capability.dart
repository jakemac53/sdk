// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/lsp_protocol/protocol.dart';
import 'package:analysis_server/src/lsp/constants.dart';
import 'package:analysis_server/src/lsp/error_or.dart';
import 'package:analysis_server/src/lsp/handlers/handlers.dart';

class ServerRegisterCapabilityHandler
    extends LspMessageHandler<RegistrationParams, void> {
  ServerRegisterCapabilityHandler(super.server);

  @override
  Method get handlesMessage => CustomMethods.registerCapability;

  @override
  LspJsonHandler<RegistrationParams> get jsonHandler =>
      RegistrationParams.jsonHandler;

  @override
  Future<ErrorOr<void>> handle(
    RegistrationParams params,
    MessageInfo message,
    CancellationToken token,
  ) async {
    server.registerCapabilities(params.registrations);
    return success(null);
  }
}
