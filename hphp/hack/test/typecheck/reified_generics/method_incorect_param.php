<?hh // strict
// Copyright 2004-present Facebook. All Rights Reserved.

class C {
  public function f<T>(T $t): void {}
  public function g<reify T>(T $t): void {}
}

function h(): void {
  $c = new C();
  $c->f<reify int>(3);
  $c->g<int>(3);
}
