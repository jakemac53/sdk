// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/dart/abstract_producer.dart';
import 'package:analysis_server/src/services/correction/fix.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

class RemoveOperator extends CorrectionProducer {
  @override
  FixKind get fixKind => DartFixKind.REMOVE_OPERATOR;

  @override
  Future<void> compute(DartChangeBuilder builder) async {
    if (node is BinaryExpression) {
      var expression = node as BinaryExpression;
      var operator = expression.operator;
      var rightOperand = expression.rightOperand;
      await builder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(range.startStart(operator, rightOperand));
      });
    }
  }

  /// Return an instance of this class. Used as a tear-off in `FixProcessor`.
  static RemoveOperator newInstance() => RemoveOperator();
}
