// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:cocoon_server_test/test_logging.dart';
import 'package:cocoon_service/src/model/firestore/commit.dart';
import 'package:cocoon_service/src/service/firestore.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import '../../src/utilities/entity_generators.dart';
import '../../src/utilities/mocks.dart';

void main() {
  useTestLoggerPerTest();

  group('Commit.fromFirestore', () {
    late MockFirestoreService mockFirestoreService;

    setUp(() {
      mockFirestoreService = MockFirestoreService();
    });

    test('generates commit correctly', () async {
      final commit = generateFirestoreCommit(1);
      when(mockFirestoreService.getDocument(captureAny)).thenAnswer((
        Invocation invocation,
      ) {
        return Future<Commit>.value(commit);
      });
      final resultedCommit = await Commit.fromFirestore(
        firestoreService: mockFirestoreService,
        documentName: 'test',
      );
      expect(resultedCommit.name, commit.name);
      expect(resultedCommit.fields, commit.fields);
    });
  });

  test('creates commit document correctly from commit data model', () async {
    final commit = generateCommit(1);
    final commitDocument = commitToCommitDocument(commit);
    expect(
      commitDocument.name,
      '$kDatabase/documents/$kCommitCollectionId/${commit.sha}',
    );
    expect(
      commitDocument.fields![kCommitAvatarField]!.stringValue,
      commit.authorAvatarUrl,
    );
    expect(
      commitDocument.fields![kCommitBranchField]!.stringValue,
      commit.branch,
    );
    expect(
      commitDocument.fields![kCommitCreateTimestampField]!.integerValue,
      commit.timestamp.toString(),
    );
    expect(
      commitDocument.fields![kCommitAuthorField]!.stringValue,
      commit.author,
    );
    expect(
      commitDocument.fields![kCommitMessageField]!.stringValue,
      commit.message,
    );
    expect(
      commitDocument.fields![kCommitRepositoryPathField]!.stringValue,
      commit.repository,
    );
    expect(commitDocument.fields![kCommitShaField]!.stringValue, commit.sha);
  });

  test('commit facade', () {
    final commitDocument = generateFirestoreCommit(1);
    final expectedResult = <String, dynamic>{
      kCommitDocumentName: commitDocument.name,
      kCommitRepositoryPath: commitDocument.repositoryPath,
      kCommitCreateTimestamp: commitDocument.createTimestamp,
      kCommitSha: commitDocument.sha,
      kCommitMessage: commitDocument.message,
      kCommitAuthor: commitDocument.author,
      kCommitAvatar: commitDocument.avatar,
      kCommitBranch: commitDocument.branch,
    };
    expect(commitDocument.facade, expectedResult);
  });
}
