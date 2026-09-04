# AI Development Instructions

## Primary Objective

Make correct, production-quality changes while minimizing unnecessary AI token usage,
GitHub Actions usage, repetitive repository scanning, and unnecessary commits.

GitHub CI is final validation. It is not the primary debugging environment.

## Repository Inspection

Before modifying code:

1. Read the user's requested change carefully.
2. Run or inspect `git status` and the current diff first.
3. Identify the smallest set of files relevant to the requested change.
4. Inspect those files before exploring unrelated parts of the repository.
5. Search for specific symbols, types, functions, errors, or filenames instead of
   repeatedly reading the entire repository.
6. Do not reread README files, specifications, architecture documents, or historical
   documentation unless they are directly relevant to the task.
7. Do not perform a full repository audit unless explicitly requested.

Prefer targeted inspection over broad context loading.

## Implementation Strategy

Batch related work into one coherent implementation pass.

Do not use this development loop:

`change -> commit -> push -> wait for CI -> change -> commit -> push -> repeat`

Use this loop instead:

`inspect -> understand -> implement related changes -> local validation -> review diff -> fix locally -> final validation -> commit/push once`

When several files need related changes, make them together before testing.

Do not create checkpoint commits solely so CI can tell you whether partially completed
work compiles.

## Local Validation

Before pushing:

1. Run the narrowest relevant tests first.
2. Fix locally reproducible failures locally.
3. Run `swift test` when Swift package behavior has changed.
4. Perform an Xcode build locally when changes affect application compilation,
   project configuration, entitlements, resources, or app-only code.
5. Review the final diff for unintended changes.

Do not rely on GitHub Actions to discover ordinary compiler errors that can be found
locally.

## GitHub Actions Cost Control

GitHub-hosted macOS runners are expensive compared with ordinary CI runners.

Therefore:

1. Do not push after every small edit.
2. Do not intentionally trigger CI to test speculative changes.
3. Push only when the implementation is reasonably complete and locally validated.
4. If a CI failure is reproducible locally, fix and validate it locally before pushing again.
5. Avoid repeated CI reruns unless the failure appears infrastructure-related or
   nondeterministic.
6. Do not modify CI workflows unless the task requires it.

Pull-request CI is intended for validation.

Release packaging is intended for main-branch or explicitly requested builds.

## Commit Discipline

Prefer one logical commit per completed task.

A second commit is appropriate when:

- the first implementation exposed a genuinely separate issue,
- review feedback requires a follow-up, or
- separating the changes materially improves repository history.

Do not create commits for:

- formatting experiments,
- temporary logging,
- speculative fixes,
- partial implementations,
- README updates that simply narrate what was just done,
- or every individual debugging step.

## Documentation

Do not update documentation automatically after every code change.

Update README or docs only when the change materially affects:

- installation,
- configuration,
- architecture,
- externally visible behavior,
- supported workflows,
- required dependencies,
- or important operational procedures.

Do not add development diaries, implementation narratives, or redundant summaries
to the repository.

Prefer concise durable documentation.

## AI Context Efficiency

Minimize unnecessary context.

Do not repeatedly load files that have not changed and whose contents are already
understood during the current task.

Prefer:

- targeted search,
- targeted file reads,
- diffs,
- compiler diagnostics,
- specific test failures,
- and relevant source files.

Avoid:

- full repository dumps,
- repeated README reads,
- repeated architecture-document reads,
- large generated summaries,
- and rereading unrelated source directories.

When sufficient evidence exists to make the change safely, make the change.

## Debugging

For a failure:

1. Read the exact error.
2. Locate the responsible code.
3. Form a concrete hypothesis.
4. Reproduce locally when possible.
5. Make the smallest correct fix.
6. Run the relevant validation.
7. Only broaden the investigation if the evidence requires it.

Do not make multiple speculative changes at once unless they form one clearly
understood fix.

## Generated Output

Keep terminal output and AI explanations concise.

Do not paste full build logs when a small relevant excerpt is sufficient.

When reporting completion, summarize:

- what changed,
- validation performed,
- any remaining known risk.

Do not produce long implementation narratives unless specifically requested.

## Release Builds

A distributable application build is not required after every development change.

Only perform a full Release build/package when:

- preparing a merge to main,
- validating changes that specifically affect Release compilation or packaging,
- the user explicitly requests an installable build,
- or diagnosing a Release-only issue.

During normal development, targeted tests and local compilation should be preferred.

## Default Decision Rule

When two approaches are equally safe and correct, choose the approach that:

1. reads fewer unrelated files,
2. requires fewer AI tokens,
3. performs fewer full builds,
4. triggers fewer GitHub Actions runs,
5. creates fewer commits,
6. and leaves the repository simpler.
