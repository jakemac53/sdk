// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../common.dart';
import '../common/elements.dart' show CommonElements;
import '../common/names.dart' show Identifiers, Selectors;
import '../elements/entities.dart';
import '../inferrer/types.dart' show GlobalTypeInferenceResults;
import '../kernel/kelements.dart' show KFunction;
import '../kernel/no_such_method_resolver.dart';
import '../serialization/serialization.dart';
import 'no_such_method_registry_interfaces.dart' as interfaces;

/// [NoSuchMethodRegistry] and [NoSuchMethodData] categorizes `noSuchMethod`
/// implementations.
///
/// If user code includes `noSuchMethod` implementations, type inference is
/// hindered because (for instance) any selector where the type of the
/// receiver is not known all implementations of `noSuchMethod` must be taken
/// into account when inferring the return type.
///
/// The situation can be ameliorated with some heuristics for disregarding some
/// `noSuchMethod` implementations during type inference. We can partition
/// `noSuchMethod` implementations into 4 categories.
///
/// Implementations in category A are the default implementations
/// `Object.noSuchMethod` and `Interceptor.noSuchMethod`.
///
/// Implementations in category B syntactically immediately throw, for example:
///
///     noSuchMethod(x) => throw 'not implemented'
///
/// Implementations in category C are not applicable, for example:
///
///     noSuchMethod() { /* missing parameter */ }
///     noSuchMethod(a, b) { /* too many parameters */ }
///
/// Implementations that do not fall into category A, B or C are in category D.
/// They are the only category of implementation that are considered during type
/// inference.
///
/// Implementations that syntactically just forward to the super implementation,
/// for example:
///
///     noSuchMethod(x) => super.noSuchMethod(x);
///
/// are in the same category as the superclass implementation. This covers a
/// common case, where users implement `noSuchMethod` with these dummy
/// implementations to avoid warnings.

/// Registry for collecting `noSuchMethod` implementations and categorizing them
/// into categories `A`, `B`, `C`, `D`.
class NoSuchMethodRegistry implements interfaces.NoSuchMethodRegistry {
  /// The implementations that fall into category A, described above.
  final Set<FunctionEntity> _defaultImpls = {};

  /// The implementations that fall into category B, described above.
  final Set<FunctionEntity> _throwingImpls = {};

  /// The implementations that fall into category C, described above.
  // TODO(johnniwinther): Remove this category when Dart 1 is no longer
  // supported.
  final Set<FunctionEntity> _notApplicableImpls = {};

  /// The implementations that fall into category D, described above.
  final Set<FunctionEntity> _otherImpls = {};

  /// The implementations that have not yet been categorized.
  final Set<FunctionEntity> _uncategorizedImpls = {};

  /// The implementations that a forwarding syntax as defined by
  /// [NoSuchMethodResolver.hasForwardSyntax].
  final Set<FunctionEntity> _forwardingSyntaxImpls = {};

  final CommonElements _commonElements;
  final NoSuchMethodResolver _resolver;

  NoSuchMethodRegistry(this._commonElements, this._resolver);

  NoSuchMethodResolver get internalResolverForTesting => _resolver;

  /// `true` if a category `B` method has been seen so far.
  @override
  bool get hasThrowingNoSuchMethod => _throwingImpls.isNotEmpty;

  /// `true` if a category `D` method has been seen so far.
  @override
  bool get hasComplexNoSuchMethod => _otherImpls.isNotEmpty;

  Iterable<FunctionEntity> get defaultImpls => _defaultImpls;

  Iterable<FunctionEntity> get throwingImpls => _throwingImpls;

  Iterable<FunctionEntity> get otherImpls => _otherImpls;

  /// Register [noSuchMethodElement].
  @override
  void registerNoSuchMethod(FunctionEntity noSuchMethodElement) {
    _uncategorizedImpls.add(noSuchMethodElement);
  }

  /// Categorizes the registered methods.
  @override
  void onQueueEmpty() {
    _uncategorizedImpls.forEach(_categorizeImpl);
    _uncategorizedImpls.clear();
  }

  NsmCategory _categorizeImpl(FunctionEntity element) {
    assert(element.name == Identifiers.noSuchMethod_);
    assert(!element.isAbstract);
    if (_defaultImpls.contains(element)) {
      return NsmCategory.DEFAULT;
    }
    if (_throwingImpls.contains(element)) {
      return NsmCategory.THROWING;
    }
    if (_otherImpls.contains(element)) {
      return NsmCategory.OTHER;
    }
    if (_notApplicableImpls.contains(element)) {
      return NsmCategory.NOT_APPLICABLE;
    }
    if (!Selectors.noSuchMethod_.signatureApplies(element)) {
      _notApplicableImpls.add(element);
      return NsmCategory.NOT_APPLICABLE;
    }
    if (_commonElements.isDefaultNoSuchMethodImplementation(element)) {
      _defaultImpls.add(element);
      return NsmCategory.DEFAULT;
    } else if (_resolver.hasForwardingSyntax(element as KFunction)) {
      _forwardingSyntaxImpls.add(element);
      // If the implementation is 'noSuchMethod(x) => super.noSuchMethod(x);'
      // then it is in the same category as the super call.
      FunctionEntity superCall = _resolver.getSuperNoSuchMethod(element);
      NsmCategory category = _categorizeImpl(superCall);
      switch (category) {
        case NsmCategory.DEFAULT:
          _defaultImpls.add(element);
          break;
        case NsmCategory.THROWING:
          _throwingImpls.add(element);
          break;
        case NsmCategory.OTHER:
          _otherImpls.add(element);
          break;
        case NsmCategory.NOT_APPLICABLE:
          // If the super method is not applicable, the call is redirected to
          // `Object.noSuchMethod`.
          _defaultImpls.add(element);
          category = NsmCategory.DEFAULT;
          break;
      }
      return category;
    } else if (_resolver.hasThrowingSyntax(element)) {
      _throwingImpls.add(element);
      return NsmCategory.THROWING;
    } else {
      _otherImpls.add(element);
      return NsmCategory.OTHER;
    }
  }

  /// Closes the registry and returns data object used during type inference.
  NoSuchMethodData close() {
    return NoSuchMethodData(
        _throwingImpls, _otherImpls, _forwardingSyntaxImpls);
  }
}

/// Data object used during type inference.
///
/// Post inference collected category `D` methods are into subcategories `D1`
/// and `D2`.
class NoSuchMethodData implements interfaces.NoSuchMethodData {
  /// Tag used for identifying serialized [NoSuchMethodData] objects in a
  /// debugging data stream.
  static const String tag = 'no-such-method-data';

  /// The implementations that fall into category B, described above.
  final Set<FunctionEntity> _throwingImpls;

  /// The implementations that fall into category D, described above.
  final Set<FunctionEntity> _otherImpls;

  /// The implementations that fall into category D1
  final Set<FunctionEntity> _complexNoReturnImpls = {};

  /// The implementations that fall into category D2
  final Set<FunctionEntity> _complexReturningImpls = {};

  final Set<FunctionEntity> _forwardingSyntaxImpls;

  NoSuchMethodData(
      this._throwingImpls, this._otherImpls, this._forwardingSyntaxImpls);

  /// Deserializes a [NoSuchMethodData] object from [source].
  factory NoSuchMethodData.readFromDataSource(DataSourceReader source) {
    source.begin(tag);
    Set<FunctionEntity> throwingImpls =
        source.readMembers<FunctionEntity>().toSet();
    Set<FunctionEntity> otherImpls =
        source.readMembers<FunctionEntity>().toSet();
    Set<FunctionEntity> forwardingSyntaxImpls =
        source.readMembers<FunctionEntity>().toSet();
    List<FunctionEntity> complexNoReturnImpls =
        source.readMembers<FunctionEntity>();
    List<FunctionEntity> complexReturningImpls =
        source.readMembers<FunctionEntity>();
    source.end(tag);
    return NoSuchMethodData(throwingImpls, otherImpls, forwardingSyntaxImpls)
      .._complexNoReturnImpls.addAll(complexNoReturnImpls)
      .._complexReturningImpls.addAll(complexReturningImpls);
  }

  /// Serializes this [NoSuchMethodData] to [sink].
  void writeToDataSink(DataSinkWriter sink) {
    sink.begin(tag);
    sink.writeMembers(_throwingImpls);
    sink.writeMembers(_otherImpls);
    sink.writeMembers(_forwardingSyntaxImpls);
    sink.writeMembers(_complexNoReturnImpls);
    sink.writeMembers(_complexReturningImpls);
    sink.end(tag);
  }

  Iterable<FunctionEntity> get throwingImpls => _throwingImpls;

  Iterable<FunctionEntity> get otherImpls => _otherImpls;

  Iterable<FunctionEntity> get forwardingSyntaxImpls => _forwardingSyntaxImpls;

  Iterable<FunctionEntity> get complexNoReturnImpls => _complexNoReturnImpls;

  Iterable<FunctionEntity> get complexReturningImpls => _complexReturningImpls;

  /// Now that type inference is complete, split category D into two
  /// subcategories: D1, those that have no return type, and D2, those
  /// that have a return type.
  @override
  void categorizeComplexImplementations(GlobalTypeInferenceResults results) {
    _otherImpls.forEach((FunctionEntity element) {
      if (results.resultOfMember(element).throwsAlways) {
        _complexNoReturnImpls.add(element);
      } else {
        _complexReturningImpls.add(element);
      }
    });
  }

  /// Emits a diagnostic about methods in categories `B`, `D1` and `D2`.
  @override
  void emitDiagnostic(DiagnosticReporter reporter) {
    _throwingImpls.forEach((e) {
      if (!_forwardingSyntaxImpls.contains(e)) {
        reporter.reportHintMessage(e, MessageKind.DIRECTLY_THROWING_NSM);
      }
    });
    _complexNoReturnImpls.forEach((e) {
      if (!_forwardingSyntaxImpls.contains(e)) {
        reporter.reportHintMessage(e, MessageKind.COMPLEX_THROWING_NSM);
      }
    });
    _complexReturningImpls.forEach((e) {
      if (!_forwardingSyntaxImpls.contains(e)) {
        reporter.reportHintMessage(e, MessageKind.COMPLEX_RETURNING_NSM);
      }
    });
  }

  /// Returns [true] if the given element is a complex [noSuchMethod]
  /// implementation. An implementation is complex if it falls into
  /// category D, as described above.
  @override
  bool isComplex(FunctionEntity element) {
    assert(element.name == Identifiers.noSuchMethod_);
    return _otherImpls.contains(element);
  }
}

enum NsmCategory {
  DEFAULT,
  THROWING,
  NOT_APPLICABLE,
  OTHER,
}
