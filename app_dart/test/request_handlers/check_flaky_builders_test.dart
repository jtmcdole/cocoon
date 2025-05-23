// Copyright 2019 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io' as io;

import 'package:cocoon_server_test/mocks.dart';
import 'package:cocoon_server_test/test_logging.dart';
import 'package:cocoon_service/ci_yaml.dart';
import 'package:cocoon_service/cocoon_service.dart';
import 'package:cocoon_service/src/model/proto/internal/scheduler.pb.dart'
    as pb;
import 'package:cocoon_service/src/request_handlers/flaky_handler_utils.dart';
import 'package:cocoon_service/src/service/big_query.dart';
import 'package:cocoon_service/src/service/github_service.dart';
import 'package:github/github.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../src/fake_config.dart';
import '../src/request_handling/api_request_handler_tester.dart';
import '../src/request_handling/fake_dashboard_authentication.dart';
import '../src/request_handling/fake_http.dart';
import '../src/utilities/mocks.dart';
import 'check_flaky_builders_test_data.dart';

const String kThreshold = '0.02';
const String kCurrentMasterSHA = 'b6156fc8d1c6e992fe4ea0b9128f9aef10443bdb';
const String kCurrentUserName = 'Name';
const String kCurrentUserLogin = 'login';
const String kCurrentUserEmail = 'login@email.com';

void main() {
  useTestLoggerPerTest();

  group('Deflake', () {
    late CheckFlakyBuilders handler;
    late ApiRequestHandlerTester tester;
    FakeHttpRequest request;
    late FakeConfig config;
    FakeClientContext clientContext;
    FakeDashboardAuthentication auth;
    late MockBigQueryService mockBigQueryService;
    MockGitHub mockGitHubClient;
    late MockRepositoriesService mockRepositoriesService;
    late MockPullRequestsService mockPullRequestsService;
    late MockIssuesService mockIssuesService;
    late MockGitService mockGitService;
    MockUsersService mockUsersService;

    setUp(() {
      request = FakeHttpRequest(
        queryParametersValue: <String, dynamic>{
          FileFlakyIssueAndPR.kThresholdKey: kThreshold,
        },
      );

      clientContext = FakeClientContext();
      auth = FakeDashboardAuthentication(clientContext: clientContext);
      mockBigQueryService = MockBigQueryService();
      mockGitHubClient = MockGitHub();
      mockRepositoriesService = MockRepositoriesService();
      mockIssuesService = MockIssuesService();
      mockPullRequestsService = MockPullRequestsService();
      mockGitService = MockGitService();
      mockUsersService = MockUsersService();
      // when gets the content of .ci.yaml
      when(
        // ignore: discarded_futures
        mockRepositoriesService.getContents(captureAny, kCiYamlPath),
      ).thenAnswer((Invocation invocation) {
        return Future<RepositoryContents>.value(
          RepositoryContents(
            file: GitHubFile(content: gitHubEncode(ciYamlContent)),
          ),
        );
      });
      // when gets the content of TESTOWNERS
      when(
        // ignore: discarded_futures
        mockRepositoriesService.getContents(captureAny, kTestOwnerPath),
      ).thenAnswer((Invocation invocation) {
        return Future<RepositoryContents>.value(
          RepositoryContents(
            file: GitHubFile(content: gitHubEncode(testOwnersContent)),
          ),
        );
      });
      // when gets existing marks flaky prs.
      when(mockPullRequestsService.list(captureAny)).thenAnswer((
        Invocation invocation,
      ) {
        return const Stream<PullRequest>.empty();
      });
      // when gets the current head of master branch
      // ignore: discarded_futures
      when(mockGitService.getReference(captureAny, kMasterRefs)).thenAnswer((
        Invocation invocation,
      ) {
        return Future<GitReference>.value(
          GitReference(
            ref: 'refs/$kMasterRefs',
            object: GitObject('', kCurrentMasterSHA, ''),
          ),
        );
      });
      // when gets the current user.
      // ignore: discarded_futures
      when(mockUsersService.getCurrentUser()).thenAnswer((
        Invocation invocation,
      ) {
        final result = CurrentUser();
        result.email = kCurrentUserEmail;
        result.name = kCurrentUserName;
        result.login = kCurrentUserLogin;
        return Future<CurrentUser>.value(result);
      });
      // when assigns pull request reviewer.
      when(
        // ignore: discarded_futures
        mockGitHubClient.postJSON<Map<String, dynamic>, PullRequest>(
          captureAny,
          statusCode: captureAnyNamed('statusCode'),
          fail: captureAnyNamed('fail'),
          headers: captureAnyNamed('headers'),
          params: captureAnyNamed('params'),
          convert: captureAnyNamed('convert'),
          body: captureAnyNamed('body'),
          preview: captureAnyNamed('preview'),
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<PullRequest>.value(PullRequest());
      });
      when(mockGitHubClient.repositories).thenReturn(mockRepositoriesService);
      when(mockGitHubClient.issues).thenReturn(mockIssuesService);
      when(mockGitHubClient.pullRequests).thenReturn(mockPullRequestsService);
      when(mockGitHubClient.git).thenReturn(mockGitService);
      when(mockGitHubClient.users).thenReturn(mockUsersService);
      config = FakeConfig(githubService: GithubService(mockGitHubClient));
      tester = ApiRequestHandlerTester(request: request);

      handler = CheckFlakyBuilders(
        config: config,
        authenticationProvider: auth,
        bigQuery: mockBigQueryService,
      );
    });

    test(
      'Can create pr if the flaky test is no longer flaky with a closed issue',
      () async {
        // When queries flaky data from BigQuery.
        when(
          mockBigQueryService.listRecentBuildRecordsForBuilder(
            kBigQueryProjectId,
            builder: captureAnyNamed('builder'),
            limit: captureAnyNamed('limit'),
          ),
        ).thenAnswer((Invocation invocation) {
          return Future<List<BuilderRecord>>.value(
            semanticsIntegrationTestRecordsAllPassed,
          );
        });
        // When queries flaky data from BigQuery.
        when(
          mockBigQueryService.listBuilderStatistic(
            kBigQueryProjectId,
            bucket: 'staging',
          ),
        ).thenAnswer((Invocation invocation) {
          return Future<List<BuilderStatistic>>.value(
            stagingSemanticsIntegrationTestResponse,
          );
        });
        // When get issue
        when(mockIssuesService.get(captureAny, captureAny)).thenAnswer((_) {
          return Future<Issue>.value(
            Issue(state: 'CLOSED', htmlUrl: existingIssueURL),
          );
        });
        // When creates git tree
        when(mockGitService.createTree(captureAny, captureAny)).thenAnswer((_) {
          return Future<GitTree>.value(
            GitTree(
              expectedSemanticsIntegrationTestTreeSha,
              '',
              false,
              <GitTreeEntry>[],
            ),
          );
        });
        // When creates git commit
        when(mockGitService.createCommit(captureAny, captureAny)).thenAnswer((
          _,
        ) {
          return Future<GitCommit>.value(
            GitCommit(sha: expectedSemanticsIntegrationTestTreeSha),
          );
        });
        // When creates git reference
        when(
          mockGitService.createReference(captureAny, captureAny, captureAny),
        ).thenAnswer((Invocation invocation) {
          return Future<GitReference>.value(
            GitReference(ref: invocation.positionalArguments[1] as String?),
          );
        });
        // When creates pr to deflake test
        when(mockPullRequestsService.create(captureAny, captureAny)).thenAnswer(
          (_) {
            return Future<PullRequest>.value(
              PullRequest(number: expectedSemanticsIntegrationTestPRNumber),
            );
          },
        );

        CheckFlakyBuilders.kRecordNumber =
            semanticsIntegrationTestRecordsAllPassed.length;
        final result =
            await utf8.decoder
                    .bind(
                      (await tester.get(handler)).serialize()
                          as Stream<List<int>>,
                    )
                    .transform(json.decoder)
                    .single
                as Map<String, dynamic>;

        // Verify BigQuery is called correctly.
        var captured =
            verify(
              mockBigQueryService.listRecentBuildRecordsForBuilder(
                captureAny,
                builder: captureAnyNamed('builder'),
                limit: captureAnyNamed('limit'),
              ),
            ).captured;
        expect(captured.length, 3);
        expect(captured[0].toString(), kBigQueryProjectId);
        expect(
          captured[1] as String?,
          expectedSemanticsIntegrationTestBuilderName,
        );
        expect(captured[2] as int?, CheckFlakyBuilders.kRecordNumber);

        // Verify it gets the correct issue.
        captured =
            verify(mockIssuesService.get(captureAny, captureAny)).captured;
        expect(captured.length, 2);
        expect(captured[0], Config.flutterSlug);
        expect(captured[1] as int?, existingIssueNumber);

        // Verify tree is created correctly.
        captured =
            verify(mockGitService.createTree(captureAny, captureAny)).captured;
        expect(captured.length, 2);
        expect(captured[0].toString(), '$kCurrentUserLogin/flutter');
        expect(captured[1], isA<CreateGitTree>());
        final tree = captured[1] as CreateGitTree;
        expect(tree.baseTree, kCurrentMasterSHA);
        expect(tree.entries!.length, 1);
        expect(
          tree.entries![0].content,
          expectedSemanticsIntegrationTestCiYamlContent,
        );
        expect(tree.entries![0].path, kCiYamlPath);
        expect(tree.entries![0].mode, kModifyMode);
        expect(tree.entries![0].type, kModifyType);

        // Verify commit is created correctly.
        captured =
            verify(
              mockGitService.createCommit(captureAny, captureAny),
            ).captured;
        expect(captured.length, 2);
        expect(captured[0].toString(), '$kCurrentUserLogin/flutter');
        expect(captured[1], isA<CreateGitCommit>());
        final commit = captured[1] as CreateGitCommit;
        expect(
          commit.message,
          expectedSemanticsIntegrationTestPullRequestTitle,
        );
        expect(commit.author!.name, kCurrentUserName);
        expect(commit.author!.email, kCurrentUserEmail);
        expect(commit.committer!.name, kCurrentUserName);
        expect(commit.committer!.email, kCurrentUserEmail);
        expect(commit.tree, expectedSemanticsIntegrationTestTreeSha);
        expect(commit.parents!.length, 1);
        expect(commit.parents![0], kCurrentMasterSHA);

        // Verify reference is created correctly.
        captured =
            verify(
              mockGitService.createReference(
                captureAny,
                captureAny,
                captureAny,
              ),
            ).captured;
        expect(captured.length, 3);
        expect(captured[0].toString(), '$kCurrentUserLogin/flutter');
        expect(captured[2], expectedSemanticsIntegrationTestTreeSha);
        final ref = captured[1] as String?;

        // Verify pr is created correctly.
        captured =
            verify(
              mockPullRequestsService.create(captureAny, captureAny),
            ).captured;
        expect(captured.length, 2);
        expect(captured[0].toString(), Config.flutterSlug.toString());
        expect(captured[1], isA<CreatePullRequest>());
        final pr = captured[1] as CreatePullRequest;
        expect(pr.title, expectedSemanticsIntegrationTestPullRequestTitle);
        expect(pr.body, expectedSemanticsIntegrationTestPullRequestBody);
        expect(pr.head, '$kCurrentUserLogin:$ref');
        expect(pr.base, 'refs/$kMasterRefs');

        expect(result['Status'], 'success');
      },
    );

    test(
      'Can create pr if the flaky test is no longer flaky without an issue',
      () async {
        // when gets the content of .ci.yaml
        when(
          mockRepositoriesService.getContents(captureAny, kCiYamlPath),
        ).thenAnswer((Invocation invocation) {
          return Future<RepositoryContents>.value(
            RepositoryContents(
              file: GitHubFile(content: gitHubEncode(ciYamlContentNoIssue)),
            ),
          );
        });
        // When queries flaky data from BigQuery.
        when(
          mockBigQueryService.listRecentBuildRecordsForBuilder(
            kBigQueryProjectId,
            builder: captureAnyNamed('builder'),
            limit: captureAnyNamed('limit'),
          ),
        ).thenAnswer((Invocation invocation) {
          return Future<List<BuilderRecord>>.value(
            semanticsIntegrationTestRecordsAllPassed,
          );
        });
        // When queries flaky data from BigQuery.
        when(
          mockBigQueryService.listBuilderStatistic(
            kBigQueryProjectId,
            bucket: 'staging',
          ),
        ).thenAnswer((Invocation invocation) {
          return Future<List<BuilderStatistic>>.value(
            stagingSemanticsIntegrationTestResponse,
          );
        });
        // When creates git tree
        when(mockGitService.createTree(captureAny, captureAny)).thenAnswer((_) {
          return Future<GitTree>.value(
            GitTree(
              expectedSemanticsIntegrationTestTreeSha,
              '',
              false,
              <GitTreeEntry>[],
            ),
          );
        });
        // When creates git commit
        when(mockGitService.createCommit(captureAny, captureAny)).thenAnswer((
          _,
        ) {
          return Future<GitCommit>.value(
            GitCommit(sha: expectedSemanticsIntegrationTestTreeSha),
          );
        });
        // When creates git reference
        when(
          mockGitService.createReference(captureAny, captureAny, captureAny),
        ).thenAnswer((Invocation invocation) {
          return Future<GitReference>.value(
            GitReference(ref: invocation.positionalArguments[1] as String?),
          );
        });
        // When creates pr to deflake test
        when(mockPullRequestsService.create(captureAny, captureAny)).thenAnswer(
          (_) {
            return Future<PullRequest>.value(
              PullRequest(number: expectedSemanticsIntegrationTestPRNumber),
            );
          },
        );

        CheckFlakyBuilders.kRecordNumber =
            semanticsIntegrationTestRecordsAllPassed.length;
        final result =
            await utf8.decoder
                    .bind(
                      (await tester.get(handler)).serialize()
                          as Stream<List<int>>,
                    )
                    .transform(json.decoder)
                    .single
                as Map<String, dynamic>;

        // Verify BigQuery is called correctly.
        var captured =
            verify(
              mockBigQueryService.listRecentBuildRecordsForBuilder(
                captureAny,
                builder: captureAnyNamed('builder'),
                limit: captureAnyNamed('limit'),
              ),
            ).captured;
        expect(captured.length, 3);
        expect(captured[0].toString(), kBigQueryProjectId);
        expect(
          captured[1] as String?,
          expectedSemanticsIntegrationTestBuilderName,
        );
        expect(captured[2] as int?, CheckFlakyBuilders.kRecordNumber);

        // Verify it does not get issue.
        verifyNever(mockIssuesService.get(captureAny, captureAny));

        // Verify tree is created correctly.
        captured =
            verify(mockGitService.createTree(captureAny, captureAny)).captured;
        expect(captured.length, 2);
        expect(captured[0].toString(), '$kCurrentUserLogin/flutter');
        expect(captured[1], isA<CreateGitTree>());
        final tree = captured[1] as CreateGitTree;
        expect(tree.baseTree, kCurrentMasterSHA);
        expect(tree.entries!.length, 1);
        expect(
          tree.entries![0].content,
          expectedSemanticsIntegrationTestCiYamlContent,
        );
        expect(tree.entries![0].path, kCiYamlPath);
        expect(tree.entries![0].mode, kModifyMode);
        expect(tree.entries![0].type, kModifyType);

        // Verify commit is created correctly.
        captured =
            verify(
              mockGitService.createCommit(captureAny, captureAny),
            ).captured;
        expect(captured.length, 2);
        expect(captured[0].toString(), '$kCurrentUserLogin/flutter');
        expect(captured[1], isA<CreateGitCommit>());
        final commit = captured[1] as CreateGitCommit;
        expect(
          commit.message,
          expectedSemanticsIntegrationTestPullRequestTitle,
        );
        expect(commit.author!.name, kCurrentUserName);
        expect(commit.author!.email, kCurrentUserEmail);
        expect(commit.committer!.name, kCurrentUserName);
        expect(commit.committer!.email, kCurrentUserEmail);
        expect(commit.tree, expectedSemanticsIntegrationTestTreeSha);
        expect(commit.parents!.length, 1);
        expect(commit.parents![0], kCurrentMasterSHA);

        // Verify reference is created correctly.
        captured =
            verify(
              mockGitService.createReference(
                captureAny,
                captureAny,
                captureAny,
              ),
            ).captured;
        expect(captured.length, 3);
        expect(captured[0].toString(), '$kCurrentUserLogin/flutter');
        expect(captured[2], expectedSemanticsIntegrationTestTreeSha);
        final ref = captured[1] as String?;

        // Verify pr is created correctly.
        captured =
            verify(
              mockPullRequestsService.create(captureAny, captureAny),
            ).captured;
        expect(captured.length, 2);
        expect(captured[0].toString(), Config.flutterSlug.toString());
        expect(captured[1], isA<CreatePullRequest>());
        final pr = captured[1] as CreatePullRequest;
        expect(pr.title, expectedSemanticsIntegrationTestPullRequestTitle);
        expect(pr.body, expectedSemanticsIntegrationTestPullRequestBodyNoIssue);
        expect(pr.head, '$kCurrentUserLogin:$ref');
        expect(pr.base, 'refs/$kMasterRefs');

        expect(result['Status'], 'success');
      },
    );

    test('Do not create PR if the builder is in the ignored list', () async {
      // when gets the content of .ci.yaml
      when(
        mockRepositoriesService.getContents(captureAny, kCiYamlPath),
      ).thenAnswer((Invocation invocation) {
        return Future<RepositoryContents>.value(
          RepositoryContents(
            file: GitHubFile(
              content: gitHubEncode(ciYamlContentFlakyInIgnoreList),
            ),
          ),
        );
      });
      // When queries flaky data from BigQuery.
      when(
        mockBigQueryService.listBuilderStatistic(
          kBigQueryProjectId,
          bucket: 'staging',
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderStatistic>>.value(
          stagingSemanticsIntegrationTestResponse,
        );
      });
      CheckFlakyBuilders.kRecordNumber =
          semanticsIntegrationTestRecordsAllPassed.length;
      final result =
          await utf8.decoder
                  .bind(
                    (await tester.get(handler)).serialize()
                        as Stream<List<int>>,
                  )
                  .transform(json.decoder)
                  .single
              as Map<String, dynamic>;

      // Verify pr is not called correctly.
      verifyNever(
        mockPullRequestsService.create(captureAny, captureAny),
      ).captured;

      expect(result['Status'], 'success');
    });

    test('Do not create pr if the issue is still open', () async {
      // When queries flaky data from BigQuery.
      when(
        mockBigQueryService.listRecentBuildRecordsForBuilder(
          kBigQueryProjectId,
          builder: captureAnyNamed('builder'),
          limit: captureAnyNamed('limit'),
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderRecord>>.value(
          semanticsIntegrationTestRecordsAllPassed,
        );
      });
      // When queries flaky data from BigQuery.
      when(
        mockBigQueryService.listBuilderStatistic(
          kBigQueryProjectId,
          bucket: 'staging',
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderStatistic>>.value(
          stagingSemanticsIntegrationTestResponse,
        );
      });
      // When get issue
      when(mockIssuesService.get(captureAny, captureAny)).thenAnswer((_) {
        return Future<Issue>.value(
          Issue(state: 'OPEN', htmlUrl: existingIssueURL),
        );
      });
      CheckFlakyBuilders.kRecordNumber =
          semanticsIntegrationTestRecordsAllPassed.length;
      final result =
          await utf8.decoder
                  .bind(
                    (await tester.get(handler)).serialize()
                        as Stream<List<int>>,
                  )
                  .transform(json.decoder)
                  .single
              as Map<String, dynamic>;

      // Verify it gets the correct issue.
      final captured =
          verify(mockIssuesService.get(captureAny, captureAny)).captured;
      expect(captured.length, 2);
      expect(captured[0], Config.flutterSlug);
      expect(captured[1] as int?, existingIssueNumber);

      // Verify pr is not created.
      verifyNever(mockPullRequestsService.create(captureAny, captureAny));

      expect(result['Status'], 'success');
    });

    test(
      'Do not create pr and do not create issue if the records have flaky runs and there is an open issue',
      () async {
        // When queries flaky data from BigQuery.
        when(
          mockBigQueryService.listRecentBuildRecordsForBuilder(
            kBigQueryProjectId,
            builder: captureAnyNamed('builder'),
            limit: captureAnyNamed('limit'),
          ),
        ).thenAnswer((Invocation invocation) {
          return Future<List<BuilderRecord>>.value(
            semanticsIntegrationTestRecordsFlaky,
          );
        });
        // When get issue
        when(mockIssuesService.get(captureAny, captureAny)).thenAnswer((_) {
          return Future<Issue>.value(
            Issue(
              state: 'CLOSED',
              htmlUrl: existingIssueURL,
              closedAt: DateTime.now().subtract(
                const Duration(days: kGracePeriodForClosedFlake - 1),
              ),
            ),
          );
        });
        // When queries flaky data from BigQuery.
        when(
          mockBigQueryService.listBuilderStatistic(
            kBigQueryProjectId,
            bucket: 'staging',
          ),
        ).thenAnswer((Invocation invocation) {
          return Future<List<BuilderStatistic>>.value(
            stagingSemanticsIntegrationTestResponse,
          );
        });

        CheckFlakyBuilders.kRecordNumber =
            semanticsIntegrationTestRecordsAllPassed.length + 1;
        final result =
            await utf8.decoder
                    .bind(
                      (await tester.get(handler)).serialize()
                          as Stream<List<int>>,
                    )
                    .transform(json.decoder)
                    .single
                as Map<String, dynamic>;

        // Verify pr is not created.
        verifyNever(mockPullRequestsService.create(captureAny, captureAny));

        // Verify issue is created correctly.
        verifyNever(mockPullRequestsService.create(captureAny, captureAny));

        expect(result['Status'], 'success');
      },
    );

    test(
      'Do not create pr and do not create issue if the records have flaky runs and there is a recently closed issue',
      () async {
        // When get issue
        when(mockIssuesService.get(captureAny, captureAny)).thenAnswer((_) {
          return Future<Issue>.value(
            Issue(state: 'OPEN', htmlUrl: existingIssueURL),
          );
        });
        // When queries flaky data from BigQuery.
        when(
          mockBigQueryService.listBuilderStatistic(
            kBigQueryProjectId,
            bucket: 'staging',
          ),
        ).thenAnswer((Invocation invocation) {
          return Future<List<BuilderStatistic>>.value(
            stagingSemanticsIntegrationTestResponse,
          );
        });

        CheckFlakyBuilders.kRecordNumber =
            semanticsIntegrationTestRecordsAllPassed.length + 1;
        final result =
            await utf8.decoder
                    .bind(
                      (await tester.get(handler)).serialize()
                          as Stream<List<int>>,
                    )
                    .transform(json.decoder)
                    .single
                as Map<String, dynamic>;

        // Verify pr is not created.
        verifyNever(mockPullRequestsService.create(captureAny, captureAny));

        // Verify issue is created correctly.
        verifyNever(mockPullRequestsService.create(captureAny, captureAny));

        expect(result['Status'], 'success');
      },
    );

    test('Do not create pr if the records have failed runs', () async {
      // When queries flaky data from BigQuery.
      when(
        mockBigQueryService.listRecentBuildRecordsForBuilder(
          kBigQueryProjectId,
          builder: captureAnyNamed('builder'),
          limit: captureAnyNamed('limit'),
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderRecord>>.value(
          semanticsIntegrationTestRecordsFailed,
        );
      });
      // When queries flaky data from BigQuery.
      when(
        mockBigQueryService.listBuilderStatistic(
          kBigQueryProjectId,
          bucket: 'staging',
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderStatistic>>.value(
          stagingSemanticsIntegrationTestResponse,
        );
      });
      // When get issue
      when(mockIssuesService.get(captureAny, captureAny)).thenAnswer((_) {
        return Future<Issue>.value(
          Issue(
            state: 'CLOSED',
            htmlUrl: existingIssueURL,
            closedAt: DateTime.now().subtract(const Duration(days: 50)),
          ),
        );
      });

      CheckFlakyBuilders.kRecordNumber =
          semanticsIntegrationTestRecordsFailed.length;
      final result =
          await utf8.decoder
                  .bind(
                    (await tester.get(handler)).serialize()
                        as Stream<List<int>>,
                  )
                  .transform(json.decoder)
                  .single
              as Map<String, dynamic>;

      // Verify BigQuery is called correctly.
      var captured =
          verify(
            mockBigQueryService.listRecentBuildRecordsForBuilder(
              captureAny,
              builder: captureAnyNamed('builder'),
              limit: captureAnyNamed('limit'),
            ),
          ).captured;
      expect(captured.length, 3);
      expect(captured[0].toString(), kBigQueryProjectId);
      expect(
        captured[1] as String?,
        expectedSemanticsIntegrationTestBuilderName,
      );
      expect(captured[2] as int?, CheckFlakyBuilders.kRecordNumber);

      // Verify it gets the correct issue.
      captured = verify(mockIssuesService.get(captureAny, captureAny)).captured;
      expect(captured.length, 2);
      expect(captured[0], Config.flutterSlug);
      expect(captured[1] as int?, existingIssueNumber);

      // Verify pr is not created.
      verifyNever(mockPullRequestsService.create(captureAny, captureAny));

      expect(result['Status'], 'success');
    });

    test('Do not create pr if there is an open one', () async {
      // When queries flaky data from BigQuery.
      when(
        mockBigQueryService.listRecentBuildRecordsForBuilder(
          kBigQueryProjectId,
          builder: captureAnyNamed('builder'),
          limit: captureAnyNamed('limit'),
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderRecord>>.value(
          semanticsIntegrationTestRecordsAllPassed,
        );
      });
      // When queries flaky data from BigQuery.
      when(
        mockBigQueryService.listBuilderStatistic(
          kBigQueryProjectId,
          bucket: 'staging',
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderStatistic>>.value(
          stagingSemanticsIntegrationTestResponse,
        );
      });
      // when gets existing marks flaky prs.
      when(mockPullRequestsService.list(captureAny)).thenAnswer((
        Invocation invocation,
      ) {
        return Stream<PullRequest>.value(
          PullRequest(body: expectedSemanticsIntegrationTestPullRequestBody),
        );
      });
      // When get issue
      when(mockIssuesService.get(captureAny, captureAny)).thenAnswer((_) {
        return Future<Issue>.value(
          Issue(state: 'CLOSED', htmlUrl: existingIssueURL),
        );
      });

      CheckFlakyBuilders.kRecordNumber =
          semanticsIntegrationTestRecordsAllPassed.length;
      final result =
          await utf8.decoder
                  .bind(
                    (await tester.get(handler)).serialize()
                        as Stream<List<int>>,
                  )
                  .transform(json.decoder)
                  .single
              as Map<String, dynamic>;

      // Verify pr is not created.
      verifyNever(mockPullRequestsService.create(captureAny, captureAny));

      expect(result['Status'], 'success');
    });

    test('Do not create pr if not enough records', () async {
      // When queries flaky data from BigQuery.
      when(
        mockBigQueryService.listRecentBuildRecordsForBuilder(
          kBigQueryProjectId,
          builder: captureAnyNamed('builder'),
          limit: captureAnyNamed('limit'),
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderRecord>>.value(
          semanticsIntegrationTestRecordsAllPassed,
        );
      });
      // When queries flaky data from BigQuery.
      when(
        mockBigQueryService.listBuilderStatistic(
          kBigQueryProjectId,
          bucket: 'staging',
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderStatistic>>.value(
          stagingSemanticsIntegrationTestResponse,
        );
      });
      // When get issue
      when(mockIssuesService.get(captureAny, captureAny)).thenAnswer((_) {
        return Future<Issue>.value(
          Issue(
            state: 'CLOSED',
            htmlUrl: existingIssueURL,
            closedAt: DateTime.now().subtract(const Duration(days: 50)),
          ),
        );
      });

      CheckFlakyBuilders.kRecordNumber =
          semanticsIntegrationTestRecordsAllPassed.length + 1;
      final result =
          await utf8.decoder
                  .bind(
                    (await tester.get(handler)).serialize()
                        as Stream<List<int>>,
                  )
                  .transform(json.decoder)
                  .single
              as Map<String, dynamic>;

      // Verify BigQuery is called correctly.
      var captured =
          verify(
            mockBigQueryService.listRecentBuildRecordsForBuilder(
              captureAny,
              builder: captureAnyNamed('builder'),
              limit: captureAnyNamed('limit'),
            ),
          ).captured;
      expect(captured.length, 3);
      expect(captured[0].toString(), kBigQueryProjectId);
      expect(
        captured[1] as String?,
        expectedSemanticsIntegrationTestBuilderName,
      );
      expect(captured[2] as int?, CheckFlakyBuilders.kRecordNumber);

      // Verify it gets the correct issue.
      captured = verify(mockIssuesService.get(captureAny, captureAny)).captured;
      expect(captured.length, 2);
      expect(captured[0], Config.flutterSlug);
      expect(captured[1] as int?, existingIssueNumber);

      // Verify pr is not created.
      verifyNever(mockPullRequestsService.create(captureAny, captureAny));

      expect(result['Status'], 'success');
    });

    // TODO(matanlurey): Further narrow down.
    // This test exists to help debug https://github.com/flutter/flutter/issues/166758.
    test('regression test for a large .ci.yaml file', () async {
      final ciYaml = io.File(
        p.join(
          'test',
          'request_handlers',
          'check_flaky_builders_large_data.yaml',
        ),
      );

      // Use the specific target above.
      when(
        mockRepositoriesService.getContents(captureAny, kCiYamlPath),
      ).thenAnswer((_) async {
        return RepositoryContents(
          file: GitHubFile(content: gitHubEncode(ciYaml.readAsStringSync())),
        );
      });

      // Report not flaky.
      when(
        mockBigQueryService.listRecentBuildRecordsForBuilder(
          kBigQueryProjectId,
          builder: captureAnyNamed('builder'),
          limit: captureAnyNamed('limit'),
        ),
      ).thenAnswer((Invocation invocation) {
        return Future<List<BuilderRecord>>.value([
          for (var i = 0; i < 10; i++)
            ...semanticsIntegrationTestRecordsAllPassed,
        ]);
      });

      // Report the issue as closed.
      when(mockIssuesService.get(captureAny, captureAny)).thenAnswer((_) {
        return Future<Issue>.value(
          Issue(state: 'CLOSED', htmlUrl: existingIssueURL),
        );
      });

      when(mockGitService.createTree(any, any)).thenAnswer((_) async {
        return GitTree(
          expectedSemanticsIntegrationTestTreeSha,
          '',
          false,
          <GitTreeEntry>[],
        );
      });

      when(mockGitService.createCommit(any, any)).thenAnswer((i) async {
        return GitCommit(sha: expectedSemanticsIntegrationTestTreeSha);
      });

      when(mockGitService.createReference(any, any, any)).thenAnswer((i) async {
        return GitReference(ref: i.positionalArguments[1] as String?);
      });

      when(mockPullRequestsService.create(any, any)).thenAnswer((_) async {
        return PullRequest();
      });

      await tester.get(handler);
    });

    test('getIgnoreFlakiness handles non-existing builderame', () async {
      final ci = loadYaml(ciYamlContent) as YamlMap?;
      final unCheckedSchedulerConfig =
          pb.SchedulerConfig()..mergeFromProto3Json(ci);
      final ciYaml = CiYamlSet(
        slug: Config.flutterSlug,
        branch: Config.defaultBranch(Config.flutterSlug),
        yamls: {CiType.any: unCheckedSchedulerConfig},
      );
      CheckFlakyBuilders.getIgnoreFlakiness('Non_existing', ciYaml);
    });
  });
}
