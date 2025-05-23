// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:github/github.dart';
import 'package:googleapis/firestore/v1.dart' hide Status;
import 'package:path/path.dart' as p;

import '../../../cocoon_service.dart';
import '../../service/firestore.dart';
import 'base.dart';

const String kGithubGoldStatusCollectionId = 'githubGoldStatuses';
const String kGithubGoldStatusPrNumberField = 'prNumber';
const String kGithubGoldStatusHeadField = 'head';
const String kGithubGoldStatusStatusField = 'status';
const String kGithubGoldStatusDescriptionField = 'description';
const String kGithubGoldStatusUpdatesField = 'updates';
const String kGithubGoldStatusRepositoryField = 'repository';

/// A update having been posted to a GitHub PR on the status of the build.
///
/// This documents layout is currently:
/// ```
///  /projects/flutter-dashboard/databases/cocoon/commits/
///    document: <this.slug.owner>_<this.slug.name>_<this.prNumber>
/// ```
final class GithubGoldStatus extends AppDocument<GithubGoldStatus> {
  static AppDocumentId<GithubGoldStatus> documentIdFor({
    required String owner,
    required String repo,
    required int prNumber,
  }) {
    return AppDocumentId.fromDocumentId(
      [owner, repo, prNumber].join('_'),
      runtimeMetadata: metadata,
    );
  }

  @override
  AppDocumentMetadata<GithubGoldStatus> get runtimeMetadata => metadata;

  /// Description of the document in Firestore.
  static final metadata = AppDocumentMetadata<GithubGoldStatus>(
    collectionId: kGithubGoldStatusCollectionId,
    fromDocument: GithubGoldStatus.fromDocument,
  );

  /// Lookup [GithubGoldStatus] from Firestore.
  ///
  /// `documentName` follows `/projects/{project}/databases/{database}/documents/{document_path}`
  static Future<GithubGoldStatus> fromFirestore({
    required FirestoreService firestoreService,
    required String documentName,
  }) async {
    final document = await firestoreService.getDocument(documentName);
    return GithubGoldStatus.fromDocument(document);
  }

  factory GithubGoldStatus({
    required int prNumber,
    required String head,
    required String status,
    required String description,
    required int updates,
    required String repository,
  }) {
    final slug = RepositorySlug.full(repository);
    return GithubGoldStatus.fromDocument(
      Document(
        fields: {
          kGithubGoldStatusPrNumberField: prNumber.toValue(),
          kGithubGoldStatusHeadField: head.toValue(),
          kGithubGoldStatusStatusField: status.toValue(),
          kGithubGoldStatusDescriptionField: description.toValue(),
          kGithubGoldStatusUpdatesField: updates.toValue(),
          kGithubGoldStatusRepositoryField: repository.toValue(),
        },
        name: p.posix.join(
          kDatabase,
          'documents',
          metadata.collectionId,
          documentIdFor(
            owner: slug.owner,
            repo: slug.name,
            prNumber: prNumber,
          ).documentId,
        ),
      ),
    );
  }

  /// Create [GithubGoldStatus] from a GithubGoldStatus Document.
  GithubGoldStatus.fromDocument(super.other);

  // The flutter-gold status cannot report a `failure` status
  // due to auto-rollers. This is why we hold a `pending` status
  // when there are image changes. This provides the opportunity
  // for images to be triaged, and the auto-roller to proceed.
  // For more context, see: https://github.com/flutter/flutter/issues/48744

  static const String statusCompleted = 'success';

  static const String statusRunning = 'pending';

  int get prNumber =>
      int.parse(fields[kGithubGoldStatusPrNumberField]!.integerValue!);

  String get head => fields[kGithubGoldStatusHeadField]!.stringValue!;

  String get status => fields[kGithubGoldStatusStatusField]!.stringValue!;

  String get description =>
      fields[kGithubGoldStatusDescriptionField]!.stringValue!;

  int get updates =>
      int.parse(fields[kGithubGoldStatusUpdatesField]!.integerValue!);

  String setStatus(String status) {
    fields[kGithubGoldStatusStatusField] = status.toValue();
    return status;
  }

  String setHead(String head) {
    fields[kGithubGoldStatusHeadField] = head.toValue();
    return head;
  }

  int setUpdates(int updates) {
    fields[kGithubGoldStatusUpdatesField] = updates.toValue();
    return updates;
  }

  String setDescription(String description) {
    fields[kGithubGoldStatusDescriptionField] = description.toValue();
    return description;
  }

  /// A serializable form of [slug].
  ///
  /// This will be of the form `<org>/<repo>`. e.g. `flutter/flutter`.
  String get repository =>
      fields[kGithubGoldStatusRepositoryField]!.stringValue!;

  /// [RepositorySlug] of where this commit exists.
  RepositorySlug get slug => RepositorySlug.full(repository);
}
