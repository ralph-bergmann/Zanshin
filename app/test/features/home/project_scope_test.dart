// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_model.dart';
import 'package:zanshin/src/features/home/project_scope.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';

import '../../helpers/fake_projects.dart';

void main() {
  test(
    "the app's list sources: the tags for the Tags list, the bookmarks (not the tags) for the Bookmarks list",
    () async {
      final ProjectRepo repo = await FakeProjectRepos().open('/r/zanshin');
      expect(repoRefListSourceOf(repo, RefKind.tag), isA<RepoTagListSource>());
      // A RepoTagListSource is a RepoBookmarkListSource too.
      expect(
        repoRefListSourceOf(repo, RefKind.bookmark),
        allOf(isA<RepoBookmarkListSource>(), isNot(isA<RepoTagListSource>())),
      );
    },
  );
}
