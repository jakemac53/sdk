// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*strong.class: Class:*/
/*omit.class: Class:*/
class Class<T> {
  /*strong.element: Class.:*/
  /*omit.element: Class.:*/
  Class();
}

/*strong.element: main:*/
/*omit.element: main:*/
main() {
  /*strong.needsSignature*/
  /*omit.*/
  local1() {}

  /*strong.needsSignature*/
  /*omit.*/
  local2(int i, String s) => i;

  print('${local1.runtimeType}');
  local2(0, '');
  new Class();
}
