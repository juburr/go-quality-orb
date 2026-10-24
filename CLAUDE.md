# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb that holds Go code to a standard on every commit. It installs Go, golangci-lint, gotestsum, gofumpt and benchstat, each checksum-verified, and wraps the checks around them: `fmt`, `mod_tidy`, `vet`, `lint`, `generate_check`, `test`, `fuzz`, `bench` and `build`. Vulnerability and security scanning (govulncheck, gosec) is out of scope; it is planned for a separate go-security-orb.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*/*.sh tests/*.sh tests/install_fixtures/*.sh

# Tests (offline; commands_test.sh needs Go and jq)
for t in tests/*_test.sh; do bash "$t" || break; done

# Run one command's script with its YAML defaults (what test-deploy.yml uses for steps that must fail)
bash tests/run_command.sh vet working_dir=tests/fixtures/dirty

# Generate SHA-512 checksum table entries for a new release of one tool
./src/install/<tool>/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/`
  - `install.yml` - Installs the tools named in `tools`, through one `install_<tool>` step per tool, each picked by a `when: condition: matches:` on the `tools` string (`^(.*[ ,])?<tool>([ ,].*)?$`). Its first step, `scripts/install_tools.sh`, rejects unknown names, since a misspelled one would otherwise install nothing. `go` goes first, so benchstat's build finds it.
  - `install_<tool>.yml` - One per tool, in the family's standard install command shape: cache key from `scripts/cache_key.sh`, `restore_cache`, the tool's `install/<tool>/install.sh`, `save_cache`. `ORB_NAME` is `go-quality-orb-<tool>`, so each tool has its own cache directory and key.
  - `fmt`, `mod_tidy`, `vet`, `lint`, `generate_check`, `test`, `fuzz`, `bench`, `build` - One script each in `scripts/`.
- `install/<tool>/install.sh` and `install_hash.sh` - Kept outside `scripts/`, because `tests/shell_conventions_test.sh` exempts only `src/scripts/install.sh`, `install_hash.sh` and `cache_key.sh` by exact path, and the shared install code doesn't follow the command scripts' conventions. orb pack ignores the directory; commands include its files with `<< include(install/<tool>/install.sh) >>`.
- `scripts/lib/go_quality.sh` - Helpers shared by the command scripts, passed to each step as `SCRIPT_GO_QUALITY_LIB: << include(scripts/lib/go_quality.sh) >>` and `eval`ed after a check that it is set. Only defines functions; no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version

### Install scripts (`src/install/<tool>/install.sh`)

Each follows the layout every juburr orb's install.sh shares: a tool definition, the shared install logic (byte-identical across the orbs; never edit it here alone), and the `sha512sums` table keyed `"<version>/<arch>"`. The tool definition holds a helper block, `# >>> go-quality-orb install helpers >>>` to `# <<< ... <<<`, which must be identical in all five scripts (`tests/install_test.sh` checks): `gq_download_base_url DEFAULT` reads `download_base_url`, an `https://` mirror that replaces DEFAULT (`https://github.com` for the GitHub tools, `https://dl.google.com/go` for Go and benchstat's Go) in the download URL, refusing credentials, a query or a fragment.

- **go**: the release archive itself is hashed (`tool_archive_member` is empty). `tool_install` unpacks it in a private directory beside `install_path`, smoke-tests `go/bin/go`, then moves any earlier installation into that directory (removed by the EXIT trap) and the new one into place. `install_path` is the installation's root, `ORB_BIN_DIR` its `bin`. It must be missing, hold no files (empty directories are fine: the contract test puts the `PATH` directory there first), or be an earlier Go installation (`VERSION` and `bin/go`), so a mistyped path such as `$HOME` is never moved aside. A `GOROOT` naming another installation is exported as the new one.
- **golangci-lint**, **gotestsum**: `.tar.gz` members. Their `install_hash.sh` checks the archive against the release's `checksums.txt`; golangci-lint's also runs `gh attestation verify` when `gh` is installed (the current entries were made without it).
- **gofumpt**: the raw binary. It publishes no checksums, but builds reproducibly, so its `verify_upstream` reads the binary's build information (`go version -m`, so it needs a `go`), downloads the Go release named there (checked against go.dev's SHA-256), clones the tag, and requires `go build -trimpath -ldflags='-w -s'` to give the same bytes. A binary built from a modified tree (0.9.0 says `+dirty`) can't be anchored that way and is left out.
- **benchstat**: `golang.org/x/perf` has no releases, so `version` is a pseudo-version and the table pins the binary built with `BENCHSTAT_GO_VERSION`, skopeo-orb's model: `benchstat_build` pins every setting that shapes the binary (`CGO_ENABLED=0`, `GOFLAGS=-trimpath -modcacherw`, `GOTOOLCHAIN=local`, `GOAMD64=v1`, `GOARM64=v8.0`, `GOFIPS140=off`, GOROOT and GOEXPERIMENT unset, private GOPATH and GOCACHE) and leaves the job's download settings (`GOPROXY`, `GOSUMDB`) alone. When the job's `go` is that release, it builds with it; when that binary doesn't match (a distribution's Go can differ), it downloads the release, checked against `benchstat_go_sha512sums`, and builds again. `tests/install_benchstat_test.sh` covers it, since the shared contract serves release assets. Changing `BENCHSTAT_GO_VERSION` means generating the entries again and bumping the cache key version in `install_benchstat.yml`.

`install_hash.sh` for go, golangci-lint, gotestsum and gofumpt is the tool's `verify_upstream` plus the shared install_hash logic, which sources `install.sh` from its own directory. benchstat's is its own (`-v` builds, `-g` prints Go table entries).

When a tool's default version changes, change it in `install_<tool>.yml` and in `install.yml`'s `<tool>_version`; `tests/wiring_test.sh` fails when they differ.

### Command scripts (`src/scripts/`)

Every check runs in each module `gq_modules` resolves from `modules`: `.` by default, a list of directories that hold a `go.mod`, or `all` (every `go.mod` below `working_dir`, skipping `vendor`, `testdata` and names starting with `.` or `_`, as `./...` does). `fmt` instead checks every `.go` file below `working_dir`, found the same way. Messages name modules with `gq_label` (the module path from `go.mod`, plus the directory when it isn't `.`), and paths in reports are relative to `working_dir`. Package patterns can't start with `-` (`go test` takes no `--` before packages), and every flag the scripts build is `-flag=value`.

Every check takes `output_dir` (absolute, not expanded, since `store_artifacts` reads it too), `report_name`, `junit` (all but `bench`; `output_dir/junit/<report_name>.xml`, or a directory of gotestsum files for `test`) and `report_only` (all but `test`). The rule every gate follows: findings fail the step unless `report_only` is true; a tool that didn't complete always fails it. Each script tells them apart from the tool's output, not only its exit code:

- **fmt**: `gofmt -l` exits 0 with unformatted files listed; a file that doesn't parse makes it exit 2. Files are passed as `./<path>`, so a name starting with `-` is never a flag. gofmt has no version option.
- **mod_tidy**: `go mod tidy -diff` (Go 1.23+) exits 1 for changes, printing a diff on stdout starting `diff `, and 1 for errors too, with no diff. Every module's Go (`go env GOVERSION` in its directory, after any toolchain switch) is checked before anything runs; older than 1.23 is an error.
- **vet**: `go vet -json` exits 0 when diagnostics are all it found; non-zero means it couldn't complete. The JSON is on stdout from Go 1.26, and on stderr before, between `# package` lines, so the lines starting with `{`, `}` or a tab are read from both. An analyzer that failed reports `{"error": ...}` instead of diagnostics, which counts as not completing. Positions are absolute; they are made relative with both the logical and physical module path.
- **lint**: golangci-lint 2 only (`version` is checked). Exit 1 is issues (`--issues-exit-code=1` overrides a config's `run.issues-exit-code`), anything else not completing. Also not completing: any `typecheck` issue (code that doesn't compile: golangci-lint then checks nothing else), and a `level=error` line on stderr with exit 0 (as for a package path that doesn't exist). golangci-lint 2 writes paths relative to the directory of the config it uses (`run.relative-path-mode: cfg`), which can be above the module, where `--path-prefix=<module>` would double the module's directory. So it runs with `--path-mode=abs` (which also overrides a config's `output.path-prefix`), and the JSON's `Pos.Filename` and every SARIF `artifactLocation.uri` are made relative to `working_dir` by its logical or physical path; the text output stays absolute. SARIF runs are merged into one file. Hints follow the "built with an older Go", version 1 configuration and missing `--path-mode` errors.
- **generate_check**: snapshots `git status --porcelain -z --untracked-files=all` with each file's `git hash-object` before and after `go generate`, with `GIT_OPTIONAL_LOCKS=0` so git doesn't rewrite the index. git status compares contents, so a generator that rewrites a file as it was doesn't count (`git ls-files -m` would, by stat). The checkout's git status leaves out files in submodules (`--ignore-submodules=all`), so each repository that holds a module (`git rev-parse --show-toplevel` in it) is snapshotted too, and each file's diff is made in its own repository with `--src-prefix`/`--dst-prefix` naming it from the checkout's top. Paths are relative to the checkout's top. go generate's output is collected in the work directory and copied to `output_dir` after the second snapshot, since `output_dir` can be in the checkout, where a report written between the snapshots would count as a change.
- **test**: gotestsum with `--packages` (which `--rerun-fails` needs) and go test's flags after `--`. Coverage profiles are per module; the total merges every profile's blocks (a block counts once, covered if any test binary ran it), as `go tool cover` does. `coverage_min` compares the statement counts, not the total rounded to one decimal (1999 of 2000 prints as 100.0%). `race` checks `CGO_ENABLED` and `go env CC` first. `split_tests` pipes `go list` (with `-race` and `tags` when the tests have them, and the build flags in `extra_args` that decide which packages and files build: `-race`, `-msan`, `-asan`, `-tags`, `-mod`, `-modfile` and `-overlay`, in either `-flag=value` or `-flag value` form, since go list refuses go test's own flags) to `circleci tests split --split-by=timings --timings-type=classname` (gotestsum's JUnit classname is the import path), whose output is read from a file after its exit status is checked (a process substitution would hide a failure, and the empty share would skip the tests), and refuses `coverage_min` across nodes.
- **fuzz**: lists fuzz tests with `go test -list '^Fuzz' -json` (with `extra_args`, whose build flags such as `-race` decide which files build; `-list` in them is refused; a name is `Fuzz` and any Unicode letters, digits and underscores, as Go identifiers allow), then runs `go test -run '^$' -fuzz '^Name$' -fuzztime T pkg` for each. A failure is a `--- FAIL: Name ` line; a new file in the package's `testdata/fuzz/Name` is copied to the reports, under the package's path, which `go list -e` finds whatever build constraints say (go list takes build flags but not go test's). Anything else non-zero is not completing.
- **bench**: without `base_ref`, one `go test -bench -count N` per module. With it, a `git worktree add --detach` of the commit (removed by the EXIT trap), and N alternating `-count=1` runs of base and head. benchstat writes text and CSV (`base=` and `head=` labels). The gate reads the CSV: units `sec/op`, `B/op` and `allocs/op`, rows other than geomean whose change is `+X%` above `max_regression`, or `?` from a base of 0 with p < 0.05 (benchstat can't make a percentage of a rise from zero). `~` is noise.
- **build**: `go build -o /dev/null` per module and `GOOS/GOARCH` (Go never replaces `/dev/null`, and it accepts any number of packages), after checking each platform against `go tool dist list`.

### Shared helpers (`scripts/lib/go_quality.sh`)

- `gq_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI. `gq_list` substitutes and splits on commas and spaces; `gq_words` splits `extra_args` with `split_shell_words` (the same parser container-ops-orb, oras-orb, crane-orb, skopeo-orb and rust-security-orb use), refusing `$(...)`, backticks and shell operators outside quotes.
- `gq_bool`, `gq_match` (`[[ =~ ]]` in the C locale: cimg images set `LC_ALL=en_US.UTF-8`, where `[a-z]` matches `é`), `gq_uint`, `gq_duration`, `gq_regex`, `gq_output` (absolute `output_dir`, a `report_name` that is a plain file name), `gq_tool` (a binary on the `PATH` or an error naming the install command), `gq_go`, `gq_require_jq`.
- `gq_modules`, `gq_label`/`gq_labels`, `gq_join` (a module-relative path made `working_dir`-relative), `gq_packages`, `gq_go_version` (`GQ_GO_VERSION` and `GQ_GO_MINOR`, 999 for a development build).
- `gq_junit FILE SUITE CASES_JSON` writes JUnit from `{classname, name, status: passed|failed|skipped, message, detail}` cases, escaping with jq's `@html`, with one passing case when there are none. `gq_gate FINDINGS REPORT_ONLY SUMMARY` ends the step. `gq_plural` and `gq_tail` format messages.
- The scripts must work with jq 1.6: never use `jq -e` on a tool's output, and never name a jq variable `$module` (a keyword in jq 1.6; the scripts use `$mod`).

### CI Pipeline (`.circleci/`)

- `config.yml` - Setup workflow: `test-install` (`tests/install_test.sh`, the shared install contract, a copy of `tests/install_contract.sh`, run for go, golangci-lint, gotestsum and gofumpt with fixtures from `tests/install_fixtures/`, then `tests/install_benchstat_test.sh`), `test-env-subst` (env subst and shell conventions), `test-commands` (`tests/commands_test.sh` on `cimg/go`, with the real go and gofmt against copies of `tests/fixtures` and stand-ins for golangci-lint, gotestsum, gofumpt, benchstat and the CircleCI CLI; then `tests/wiring_test.sh`), orb-tools lint, pack and review (`orb_name: go-quality`, with `exclude: RC008`: that check takes any key named `run` for a run step, so it fails on the `run` parameters of `test` and `generate_check`, which keep the name of the flag they set; `tests/wiring_test.sh` checks instead that every run step has a name), shellcheck.
- `test-deploy.yml` - Runs against `tests/fixtures`: `clean`, which every check passes, and `dirty`, which every check finds something in (an unformatted file, a junk `go.sum`, a self-assignment for vet (not printf: `go test` runs that analyzer itself and would fail), an unchecked error for errcheck, stale generated code, a fuzz test that panics on `FUZZ`, a test that fails with the `failing` tag, and a package that doesn't build for Windows). Neither needs a module from the network. Jobs: `install-test` (every tool, the binaries the tables pin, a second install from the cache), `checksum-test` (unlisted versions fail closed; `known_versions`; a local HTTPS mirror serving the real gotestsum release, then a tampered one), `arm64-test`, `machine-test` (a machine executor with the orb's Go), `checks-test` (everything passes on clean, and the checkout is left unchanged), `findings-test` (report_only reports every finding on dirty; lint's paths stay relative to `working_dir` with one config above the module; each check fails by default; tools that can't complete fail with report_only), `old-go-test` (`cimg/go:1.22`: vet's JSON on stderr, and mod_tidy's refusal), `bench-test` (a commit that slows `Hello` fails `max_regression`). Steps that must fail run through `tests/run_command.sh`. Publishing runs on `v*` tags.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline; the fixture fragments in `tests/install_fixtures/` carry a `# shellcheck shell=bash` directive.

Scripts pass parameter values to `circleci env subst` on stdin, as `gq_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them (`tests/run_command.sh` sets them from the YAML).
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 has no `mapfile -d`, so NUL-separated lists are read with `while IFS= read -r -d ''`. `tests/commands_test.sh` passes with bash 4.0, 4.3 and 5 first on the `PATH`.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_GO_QUALITY_LIB}"`). Secrets never go on a command line, and curl that sends credentials or fetches trusted content uses `--fail` and `--proto '=https'`.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).

## Naming

Command names are the go subcommands they wrap, in snake_case (`mod_tidy` for `go mod tidy`, `vet`, `test`, `build`), or what they check (`fmt`, `lint`, `generate_check`, `fuzz`, `bench`). Parameters that map onto one flag take its long name in snake_case (`fuzz_time` for `-fuzztime`, `new_from_rev`, `rerun_fails`, `coverpkg`, `benchtime`); `modules`, `packages`, `tags` and `extra_args` mean the same in every command. Plumbing matches the other juburr orbs: `output_dir`, `report_name`, `junit`, `report_only`, `store_artifacts`, and lists take commas or spaces.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh src/install/*/*.sh tests/*.sh tests/install_fixtures/*.sh` to lint shell scripts
- Run every `tests/*_test.sh`, also under `LC_ALL=en_US.UTF-8` (as CI does) when the system has that locale, with jq 1.6, and with bash 4.0 and 4.3 first on the `PATH`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml` to validate the orb structure
- For changes to a command, also run it with the real tools against `tests/fixtures/clean` and `tests/fixtures/dirty` through `tests/run_command.sh`, as `test-deploy.yml` does
- `tests/commands_test.sh` fails if a command leaves `/dev/null` anything but a device: run as root, a tool that replaced it would break everything after it
