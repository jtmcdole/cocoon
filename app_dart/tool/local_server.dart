// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:appengine/appengine.dart';
import 'package:cocoon_server_test/fake_secret_manager.dart';
import 'package:cocoon_service/cocoon_service.dart';
import 'package:cocoon_service/server.dart';
import 'package:cocoon_service/src/model/appengine/cocoon_config.dart';
import 'package:cocoon_service/src/service/build_status_provider.dart';
import 'package:cocoon_service/src/service/commit_service.dart';
import 'package:cocoon_service/src/service/datastore.dart';
import 'package:cocoon_service/src/service/get_files_changed.dart';
import 'package:cocoon_service/src/service/scheduler/ci_yaml_fetcher.dart';
import 'package:gcloud/db.dart';

import '../test/src/datastore/fake_datastore.dart';

Future<void> main() async {
  final cache = CacheService(inMemory: false);
  final DatastoreDB dbService = FakeDatastoreDB();
  final datastoreService = DatastoreService(dbService, defaultMaxEntityGroups);
  await datastoreService.insert(<CocoonConfig>[
    CocoonConfig.fake(
      dbService.emptyKey.append(CocoonConfig, id: 'WebhookKey'),
      'fake-secret',
    ),
    CocoonConfig.fake(
      dbService.emptyKey.append(CocoonConfig, id: 'FrobWebhookKey'),
      'fake-secret',
    ),
  ]);
  final config = Config(dbService, cache, FakeSecretManager());
  final authProvider = AuthenticationProvider(config: config);
  final AuthenticationProvider swarmingAuthProvider =
      SwarmingAuthenticationProvider(config: config);

  final buildBucketClient = BuildBucketClient(
    accessTokenService: AccessTokenService.defaultProvider(config),
  );

  /// LUCI service class to communicate with buildBucket service.
  final luciBuildService = LuciBuildService(
    config: config,
    cache: cache,
    buildBucketClient: buildBucketClient,
    pubsub: const PubSub(),
  );

  /// Github checks api service used to provide luci test execution status on the Github UI.
  final githubChecksService = GithubChecksService(config);

  // Gerrit service class to communicate with GoB.
  final gerritService = GerritService(config: config);

  final ciYamlFetcher = CiYamlFetcher(cache: cache, config: config);

  /// Cocoon scheduler service to manage validating commits in presubmit and postsubmit.
  final scheduler = Scheduler(
    cache: cache,
    config: config,
    githubChecksService: githubChecksService,
    getFilesChanged: GithubApiGetFilesChanged(config),
    luciBuildService: luciBuildService,
    ciYamlFetcher: ciYamlFetcher,
  );

  final branchService = BranchService(
    config: config,
    gerritService: gerritService,
  );

  final commitService = CommitService(config: config);

  final buildStatusService = BuildStatusService(config);

  final server = createServer(
    config: config,
    cache: cache,
    authProvider: authProvider,
    branchService: branchService,
    buildBucketClient: buildBucketClient,
    gerritService: gerritService,
    scheduler: scheduler,
    luciBuildService: luciBuildService,
    githubChecksService: githubChecksService,
    commitService: commitService,
    swarmingAuthProvider: swarmingAuthProvider,
    ciYamlFetcher: ciYamlFetcher,
    buildStatusService: buildStatusService,
  );

  return runAppEngine(
    server,
    onAcceptingConnections: (InternetAddress address, int port) {
      final host = address.isLoopback ? 'localhost' : address.host;
      print('Serving requests at http://$host:$port/');
    },
  );
}
