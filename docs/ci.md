# Choosing CI runners

The **CI** and **Mutation testing** workflows accept an `arm64_runner` input when
started manually. In **Actions**, select the workflow, choose **Run workflow**,
and select `github-hosted` or `self-hosted` under **ARM64 runner**.

| Choice | ARM64 jobs | Intel CI job |
| --- | --- | --- |
| `github-hosted` (default) | `macos-15` | `macos-15-intel` |
| `self-hosted` | Runner matching `self-hosted`, `macOS`, and `ARM64` | `macos-15-intel` |

Self-hosted runs must be dispatched manually from `main`. A self-hosted request
from another branch or event fails validation on a hosted runner before checkout.
Push, pull-request, scheduled, and existing release runs retain their hosted
defaults. Intel validation still needs GitHub-hosted capacity. Selecting a runner
does not provide automatic fallback when that runner is unavailable.

The equivalent GitHub CLI commands are:

```sh
gh workflow run ci.yml --ref main -f arm64_runner=self-hosted
gh workflow run mutation-testing.yml --ref main -f arm64_runner=self-hosted
```

These commands start real CI jobs. The workflow changes must be on the default
branch before GitHub exposes the manual inputs. Manual CI runs test and check
packaging; they do not publish a release or run SonarQube analysis.

The reusable CI workflow accepts the same `arm64_runner` input as a string,
defaulting to `github-hosted`. It validates the value and applies the same
manual-`main` restriction using the caller's event and ref. The release workflow
continues to use the default.

## Self-hosted prerequisites

Use an Apple Silicon Mac with the runner service active and the three labels
above, macOS 15 or later for mutation testing, full Xcode with Swift 6 or later,
Git, and Python 3.9 or later. These workflows run automated tests and CLI help;
they do not require Teams or Accessibility permission.

Hosted jobs select Xcode 16.4. Self-hosted jobs default to
`/Applications/Xcode.app/Contents/Developer`. To use another installation, set the
repository Actions variable `SELF_HOSTED_DEVELOPER_DIR` to its absolute
`Contents/Developer` path. Each job checks Xcode and adds that installation's Swift
toolchain to its own `PATH`; it does not change the machine's `xcode-select`
setting or install tools. Compare results with the selected toolchain in mind.

Checkout uses its default clean behavior, so use the runner's dedicated work
directory rather than a development checkout. Mutation report summaries and
uploads require a successful checkout, preventing stale files from a previous
run from being reported if checkout fails.

This repository accepts public pull requests. The workflow conditions limit the
provided self-hosted option, but editable YAML is not an access-control boundary.
Restrict runner access to trusted workflows/refs through available GitHub runner
policies and use an isolated runner environment. Do not expose a personal Mac to
untrusted PR code. See GitHub's [self-hosted runner security guidance](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners).
