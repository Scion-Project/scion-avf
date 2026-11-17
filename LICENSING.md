# Licensing

This file is a plain-English map of who may use what under which licence. It does not replace the licence files.

The repository-level `LICENSE` is AGPL-3.0 and is not changed.

## Original work: MIT-0

Files that the Scion project wrote entirely from scratch (every commit by the project's authors, no third-party notice, nothing ported or derived from another codebase) are licensed **MIT-0** (MIT No Attribution, SPDX `MIT-0`; text in `LICENSES/MIT-0.txt`). Each such file carries `SPDX-License-Identifier: MIT-0` in its first lines, except the files listed in the table below, which cannot hold a comment.

MIT-0 paths (top-level location, number of files):

- `(top level)`: 2 files
- `bench`: 5 files
- `display`: 17 files
- `docs`: 5 files
- `gpu3d`: 8 files
- `probe`: 13 files
- `tools`: 5 files
- `vmapple`: 5 files

The full per-file list is in the pull request that introduced this file, and every file's own first lines are authoritative.

Note: 30 of these files already carried a project-chosen `SPDX-License-Identifier` tag (MIT or AGPL-3.0-or-later); it was replaced by `MIT-0`.

## Files that keep their existing licence

- Anything not listed above, and any file that has no explicit `SPDX-License-Identifier: MIT-0` tag, stays under the repository's existing licence, as before.
- `vmapple/patches/*`: modifications of Apple's XNU (APSL-2.0) and `vmapple/buildfix.sh`, which edits and stands in for Apple build files.
- Gradle wrapper files: Apache-2.0.
- Captured logs and generated reports under `docs/`.

