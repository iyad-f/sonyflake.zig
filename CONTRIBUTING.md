<!--
SPDX-FileCopyrightText: 2026 Iyad

SPDX-License-Identifier: Apache-2.0
-->

# Contribution Guide

First off, thanks for taking the time to contribute. It makes the library substantially better. :+1:

See the [Development section of the README](README.md#development) to get started.

## Reporting Bugs

Please search the existing issues first to avoid duplicates. Make sure to provide enough information to make the issue workable. The issue template will generally walk you through the process, but the details are enumerated here as well:

- A short **summary** of the problem.
- **How to reproduce it**, ideally a minimal code sample we can run. If you can't share code, describe the steps and how often it happens.
- What you **expected** to happen.
- What **actually** happens. "It doesn't work" isn't actionable, so tell us how it failed: an error, a panic, a hang, or a wrong id.
- Your **environment**: the `sonyflake` version, your Zig version, and your operating system.

Reports missing this information take longer to fix and may be closed if a request for clarification goes unanswered.

## Submitting a Pull Request

Keep each pull request focused on a single change and avoid scope creep, so it stays easy to review.

Before opening a pull request:

- Install the git hooks (`pre-commit install`) so formatting, licensing, and commit-message checks run automatically.
- Make sure `zig build test` passes.
- Add SPDX headers to any new files, the repository is [REUSE](https://reuse.software) compliant.
- Write commit messages in the [Conventional Commits](https://www.conventionalcommits.org) format.

When you open the pull request, CI runs the same `pre-commit` checks and the tests. A pull request can't be merged until they pass.
