// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:buildbucket/buildbucket_pb.dart' as bbv2;
import 'package:cocoon_server/logging.dart';
import 'package:gcloud/db.dart';
import 'package:googleapis/firestore/v1.dart' hide Status;
import 'package:meta/meta.dart';

import '../../ci_yaml.dart';
import '../model/appengine/commit.dart';
import '../model/appengine/task.dart';
import '../model/firestore/task.dart' as firestore;
import '../model/luci/user_data.dart';
import '../request_handling/body.dart';
import '../request_handling/exceptions.dart';
import '../request_handling/subscription_handler.dart';
import '../service/datastore.dart';
import '../service/firestore.dart';
import '../service/github_checks_service.dart';
import '../service/scheduler.dart';
import '../service/scheduler/ci_yaml_fetcher.dart';

/// An endpoint for listening to build updates for postsubmit builds.
///
/// The PubSub subscription is set up here:
/// https://console.cloud.google.com/cloudpubsub/subscription/detail/build-bucket-postsubmit-sub?project=flutter-dashboard
///
/// This endpoint is responsible for updating Datastore with the result of builds from LUCI.
@immutable
class PostsubmitLuciSubscription extends SubscriptionHandler {
  /// Creates an endpoint for listening to LUCI status updates.
  const PostsubmitLuciSubscription({
    required super.cache,
    required super.config,
    super.authProvider,
    @visibleForTesting
    this.datastoreProvider = DatastoreService.defaultProvider,
    required this.scheduler,
    required this.githubChecksService,
    required this.ciYamlFetcher,
  }) : super(subscriptionName: 'build-bucket-postsubmit-sub');

  final DatastoreServiceProvider datastoreProvider;
  final Scheduler scheduler;
  final GithubChecksService githubChecksService;
  final CiYamlFetcher ciYamlFetcher;

  @override
  Future<Body> post() async {
    if (message.data == null) {
      log.info('no data in message');
      return Body.empty;
    }

    final datastore = datastoreProvider(config.db);
    final firestoreService = await config.createFirestoreService();

    final pubSubCallBack = bbv2.PubSubCallBack();
    pubSubCallBack.mergeFromProto3Json(
      jsonDecode(message.data!) as Map<String, dynamic>,
    );
    final buildsPubSub = pubSubCallBack.buildPubsub;

    var userDataMap = <String, dynamic>{};
    try {
      userDataMap =
          json.decode(String.fromCharCodes(pubSubCallBack.userData))
              as Map<String, dynamic>;
      log.info('User data was not base64 encoded.');
    } on FormatException {
      userDataMap = UserData.decodeUserDataBytes(pubSubCallBack.userData);
      log.info('Decoding base64 encoded user data.');
    }

    // collect userData
    if (userDataMap.isEmpty) {
      log.info('User data is empty');
      return Body.empty;
    }

    log.debug('userData=$userDataMap');

    if (!buildsPubSub.hasBuild()) {
      log.warn('No build was found in message.');
      return Body.empty;
    }

    final build = buildsPubSub.build;

    // Note that result is no longer present in the output.
    log.debug('Updating buildId=${build.id} for result=${build.status}');

    // Add build fields that are stored in a separate compressed buffer.
    build.mergeFromBuffer(ZLibCodec().decode(buildsPubSub.buildLargeFields));

    log.info('build ${build.toProto3Json()}');

    final rawTaskKey = userDataMap['task_key'] as String?;
    final rawCommitKey = userDataMap['commit_key'] as String?;
    final taskDocumentName =
        userDataMap['firestore_task_document_name'] as String?;
    if (taskDocumentName == null) {
      throw const BadRequestException(
        'userData does not contain firestore_task_document_name',
      );
    }

    final commitKey = Key<String>(
      Key<dynamic>.emptyKey(Partition(null)),
      Commit,
      rawCommitKey,
    );
    Task? task;
    firestore.Task? firestoreTask;
    log.info(
      'Looking up task document $kDatabase/documents/${firestore.kTaskCollectionId}/$taskDocumentName...',
    );
    final taskId = int.parse(rawTaskKey!);
    final taskKey = Key<int>(commitKey, Task, taskId);
    task = await datastore.lookupByValue<Task>(taskKey);
    firestoreTask = await firestore.Task.fromFirestore(
      firestoreService: firestoreService,
      documentName:
          '$kDatabase/documents/${firestore.kTaskCollectionId}/$taskDocumentName',
    );
    log.info('Found $firestoreTask');

    if (_shouldUpdateTask(build, firestoreTask)) {
      final oldTaskStatus = firestoreTask.status;
      firestoreTask.updateFromBuild(build);

      log.info('Updated firestore task $firestoreTask');

      task.updateFromBuildbucketBuild(build);
      await datastore.insert(<Task>[task]);
      final writes = documentsToWrites([firestoreTask], exists: true);
      await firestoreService.batchWriteDocuments(
        BatchWriteRequest(writes: writes),
        kDatabase,
      );
      log.debug(
        'Updated datastore from $oldTaskStatus to ${firestoreTask.status}',
      );
    } else {
      log.debug(
        'skip processing for build with status scheduled or task with status '
        'finished.',
      );
    }

    final commit = await datastore.lookupByValue<Commit>(commitKey);

    final ciYaml = await ciYamlFetcher.getCiYamlByDatastoreCommit(commit);
    final postsubmitTargets = [
      ...ciYaml.postsubmitTargets(),
      if (ciYaml.isFusion)
        ...ciYaml.postsubmitTargets(type: CiType.fusionEngine),
    ];

    // Do not block on the target not found.
    if (!postsubmitTargets.any(
      (element) => element.value.name == firestoreTask!.taskName,
    )) {
      log.warn(
        'Target ${firestoreTask.taskName} has been deleted from TOT. Skip '
        'updating.',
      );
      return Body.empty;
    }
    final target = postsubmitTargets.singleWhere(
      (Target target) => target.value.name == firestoreTask!.taskName,
    );
    if (firestoreTask.status == firestore.Task.statusFailed ||
        firestoreTask.status == firestore.Task.statusInfraFailure ||
        firestoreTask.status == firestore.Task.statusCancelled) {
      log.debug('Trying to auto-retry...');
      final retried = await scheduler.luciBuildService.checkRerunBuilder(
        commit: commit,
        target: target,
        task: task,
        datastore: datastore,
        taskDocument: firestoreTask,
        firestoreService: firestoreService,
      );
      log.info('Retried: $retried');
    }

    // Only update GitHub checks if target is not bringup
    if (target.value.bringup == false &&
        config.postsubmitSupportedRepos.contains(target.slug)) {
      log.info('Updating check status for ${target.getTestName}');
      await githubChecksService.updateCheckStatus(
        build: build,
        checkRunId: userDataMap['check_run_id'] as int,
        luciBuildService: scheduler.luciBuildService,
        slug: commit.slug,
      );
    }

    return Body.empty;
  }

  // No need to update task in datastore if
  // 1) the build is `scheduled`. Task is marked as `In Progress`
  //    whenever scheduled, either from scheduler/backfiller/rerun. We need to update
  //    task in datastore only for
  //    a) `started`: update info like builder number.
  //    b) `completed`: update info like status.
  // 2) the task is already completed.
  //    The task may have been marked as completed from test framework via update-task-status API.
  bool _shouldUpdateTask(bbv2.Build build, firestore.Task task) {
    return build.status != bbv2.Status.SCHEDULED &&
        !firestore.Task.finishedStatusValues.contains(task.status);
  }
}
