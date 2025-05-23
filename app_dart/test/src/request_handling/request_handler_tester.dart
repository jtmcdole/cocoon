// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:cocoon_service/src/request_handling/body.dart';
import 'package:cocoon_service/src/request_handling/request_handler.dart';
import 'package:meta/meta.dart';

import 'fake_http.dart';

class RequestHandlerTester {
  RequestHandlerTester({FakeHttpRequest? request})
    : request = request ?? FakeHttpRequest();

  FakeHttpRequest request;

  /// This tester's [FakeHttpResponse], derived from [request].
  FakeHttpResponse get response => request.response;

  /// Executes [RequestHandler.get] on the specified [handler].
  Future<Body> get(RequestHandler handler) {
    return run(() {
      // ignore: invalid_use_of_protected_member
      return handler.get(Request.fromHttpRequest(request));
    });
  }

  /// Executes [RequestHandler.post] on the specified [handler].
  Future<Body> post(RequestHandler handler) {
    return run(() {
      // ignore: invalid_use_of_protected_member
      return handler.post(Request.fromHttpRequest(request));
    });
  }

  @protected
  Future<Body> run(Future<Body> Function() callback) {
    return runZoned(
      () {
        return callback();
      },
      zoneValues: <RequestKey<dynamic>, Object?>{RequestKey.response: response},
    );
  }
}
