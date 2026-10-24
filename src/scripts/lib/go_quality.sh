#!/bin/bash

# Shared helpers for the go-quality-orb commands. Each command passes this
# file to its step as SCRIPT_GO_QUALITY_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions.

# gq_subst VALUE: prints VALUE with environment variables expanded. The value
# is piped in on stdin: passed as an argument, a value starting with "-" would
# be parsed as a flag. Without the CircleCI CLI (local runs), the value is used
# as is.
gq_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# gq_bool NAME VALUE: prints true or false. CircleCI passes boolean parameters
# as 1 or 0; local callers use true or false.
gq_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# gq_words PARAMETER VALUE: sets GQ_WORDS to VALUE split like shell words
# (see split_shell_words), naming PARAMETER in any error. Nothing in it is
# expanded or executed: a $(...) or backtick that reached a parameter through
# an environment variable (a branch name, a commit message) reaches the tool as
# text inside quotes, and fails the step outside them.
gq_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    GQ_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# gq_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, setting
# BASH_REMATCH. In other locales a range such as [a-z] can match letters such
# as é (cimg images set LC_ALL=en_US.UTF-8), so checks with ranges use this.
gq_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# gq_list PARAMETER VALUE: sets GQ_LIST to VALUE, with environment variables
# expanded, split on commas and spaces.
gq_list() {
    local value
    GQ_LIST=()
    value=$(gq_subst "$2")
    if [[ "${value}" == *$'\n'* ]]; then
        echo "ERROR: ${1} must be separated by commas or spaces, not newlines." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    read -r -a GQ_LIST <<< "${value//,/ }"
}

# gq_tool BINARY COMMAND: sets GQ_TOOL to BINARY's path on the PATH, or stops
# the step saying how to install it with this orb's COMMAND.
gq_tool() {
    # shellcheck disable=SC2034 # read by the script that evals this file
    if ! GQ_TOOL=$(command -v "$1"); then
        echo "ERROR: $1 is not on the PATH. Install it in an earlier step with this orb's $2 command." >&2
        exit 1
    fi
}

# gq_go: stops the step unless go is on the PATH.
gq_go() {
    if ! command -v go > /dev/null 2>&1; then
        echo "ERROR: go is not on the PATH. Use an image with Go, such as cimg/go, or install it in an earlier step" >&2
        echo "  with this orb's install_go command." >&2
        exit 1
    fi
}

# gq_require_jq: stops the step unless jq, which the reports are built with,
# is on the PATH.
gq_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "ERROR: jq is not on the PATH, and this command needs it to write its reports." >&2
        echo "  CircleCI's cimg images have it; on other images, install jq in an earlier step." >&2
        exit 1
    fi
}

# gq_output DIR NAME: checks output_dir and report_name, creates DIR, and sets
# GQ_OUT to DIR and GQ_BASE to the path every report of this run starts with.
gq_output() {
    if [[ "$1" != /* || "$1" == *$'\n'* ]]; then
        echo "ERROR: output_dir must be an absolute path, not '$1'." >&2
        exit 1
    fi
    if ! gq_match "$2" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        echo "ERROR: report_name must be letters, digits, '.', '_' and '-', not '$2'." >&2
        exit 1
    fi
    if ! mkdir -p "$1"; then
        echo "ERROR: Could not create output_dir $1." >&2
        exit 1
    fi
    GQ_OUT=${1%/}
    GQ_OUT=${GQ_OUT:-/}
    # shellcheck disable=SC2034 # read by the script that evals this file
    GQ_BASE="${GQ_OUT%/}/$2"
}

# gq_uint PARAMETER VALUE [MIN]: stops the step unless VALUE is a whole number
# of at least MIN (default 0).
gq_uint() {
    if ! gq_match "$2" '^[0-9]{1,9}$' || ((10#$2 < ${3:-0})); then
        echo "ERROR: ${1} must be a whole number of at least ${3:-0}, not '$2'." >&2
        exit 1
    fi
}

# gq_duration PARAMETER VALUE: stops the step unless VALUE looks like a Go
# duration (30s, 1m30s, 500ms), or, for flags that take one, a count of runs
# (100x). Go checks it exactly; this catches a value that isn't one at all.
gq_duration() {
    if ! gq_match "$2" '^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$|^[0-9]+x$'; then
        echo "ERROR: ${1} must be a Go duration such as 30s, 5m or 1h30m, not '$2'." >&2
        exit 1
    fi
}

# gq_regex PARAMETER VALUE: stops the step unless VALUE can be passed to go
# test or go generate as one regular expression argument.
gq_regex() {
    if [[ "$2" == *$'\n'* ]]; then
        echo "ERROR: ${1} must be one line." >&2
        exit 1
    fi
}

# gq_modules VALUE: sets GQ_MODULES to the module directories VALUE names,
# relative to the working directory, and stops the step if one isn't a
# module. VALUE is a list separated by commas or spaces ("." when empty), or
# "all" for every go.mod below the working directory, skipping the
# directories the go command skips in ./... patterns: vendor, testdata, and
# names that start with "." or "_".
gq_modules() {
    local entry dir found
    local -A seen=()
    GQ_MODULES=()
    gq_list modules "$1"
    if [[ ${#GQ_LIST[@]} -eq 0 ]]; then
        GQ_LIST=(.)
    fi
    if [[ ${#GQ_LIST[@]} -eq 1 && "${GQ_LIST[0]}" == all ]]; then
        while IFS= read -r -d '' found; do
            dir=${found%/go.mod}
            dir=${dir#./}
            GQ_MODULES+=("${dir}")
        done < <(find . -mindepth 1 -type d \( -name vendor -o -name testdata -o -name '.*' -o -name '_*' \) -prune \
            -o -type f -name go.mod -print0 | LC_ALL=C sort -z)
        if [[ ${#GQ_MODULES[@]} -eq 0 ]]; then
            echo "ERROR: modules is all, but there is no go.mod in $(pwd) or below it." >&2
            exit 1
        fi
        # find prints the working directory's own go.mod as ./go.mod.
        for entry in "${!GQ_MODULES[@]}"; do
            if [[ "${GQ_MODULES[${entry}]}" == go.mod ]]; then
                GQ_MODULES[entry]=.
            fi
        done
        return 0
    fi
    for entry in "${GQ_LIST[@]}"; do
        dir=${entry}
        while [[ "${dir}" == */ && "${dir}" != / ]]; do
            dir=${dir%/}
        done
        while [[ "${dir}" == ./* ]]; do
            dir=${dir#./}
        done
        if [[ "${dir}" == all ]]; then
            echo "ERROR: modules can be all, or a list of module directories, not both." >&2
            exit 1
        fi
        if [[ "${dir}" == /* || "/${dir}/" == */../* ]]; then
            echo "ERROR: modules must name directories inside the working directory, without '..', not '${entry}'." >&2
            exit 1
        fi
        if [[ ! -f "${dir}/go.mod" ]]; then
            echo "ERROR: modules names ${entry}, which has no go.mod (in $(pwd))." >&2
            if [[ "${dir}" == . ]]; then
                echo "  For a repository without a go.mod at its top, set modules to all, or list the module directories." >&2
            fi
            exit 1
        fi
        if [[ -z "${seen[${dir}]+set}" ]]; then
            seen[${dir}]=1
            GQ_MODULES+=("${dir}")
        fi
    done
}

# gq_label DIR: prints how messages name the module in DIR: its module path,
# from its go.mod, and DIR when it isn't the working directory, such as
# "example.com/api (services/api)".
gq_label() {
    local path
    path=$(awk '$1 == "module" { gsub(/"/, "", $2); print $2; exit }' "$1/go.mod" 2> /dev/null) || path=""
    if [[ -z "${path}" ]]; then
        printf '%s\n' "$1"
    elif [[ "$1" == . ]]; then
        printf '%s\n' "${path}"
    else
        printf '%s (%s)\n' "${path}" "$1"
    fi
}

# gq_labels DIR...: prints the labels of the modules in DIR..., separated by
# commas.
gq_labels() {
    local dir out=""
    for dir in "$@"; do
        out+="${out:+, }$(gq_label "${dir}")"
    done
    printf '%s\n' "${out}"
}

# gq_join MODULE PATH: prints PATH, which is relative to MODULE, relative to
# the working directory instead.
gq_join() {
    if [[ "$1" == . ]]; then
        printf '%s\n' "$2"
    else
        printf '%s/%s\n' "$1" "$2"
    fi
}

# gq_packages VALUE: sets GQ_PACKAGES to the package patterns VALUE names,
# separated by commas or spaces ("./..." when empty). A pattern can't start
# with "-", which the go command would read as a flag.
gq_packages() {
    local pattern
    gq_list packages "$1"
    GQ_PACKAGES=(${GQ_LIST[@]+"${GQ_LIST[@]}"})
    if [[ ${#GQ_PACKAGES[@]} -eq 0 ]]; then
        GQ_PACKAGES=(./...)
    fi
    for pattern in "${GQ_PACKAGES[@]}"; do
        if [[ "${pattern}" == -* ]]; then
            echo "ERROR: packages names '${pattern}', which the go command would read as a flag. Put flags in extra_args." >&2
            exit 1
        fi
    done
}

# gq_go_version DIR: sets GQ_GO_VERSION to the Go release that runs in DIR,
# such as go1.27.3 (go.mod's toolchain line can make go switch to another,
# as GOTOOLCHAIN allows), and GQ_GO_MINOR to its minor version, such as 27,
# or 999 for a development build. Stops the step if go can't say.
gq_go_version() {
    if ! GQ_GO_VERSION=$(cd "$1" && go env GOVERSION) || [[ -z "${GQ_GO_VERSION}" ]]; then
        echo "ERROR: go could not say which Go release runs in $1 (go env GOVERSION)." >&2
        exit 1
    fi
    if gq_match "${GQ_GO_VERSION}" '^go1\.([0-9]+)'; then
        GQ_GO_MINOR=$((10#${BASH_REMATCH[1]}))
    else
        # shellcheck disable=SC2034 # read by the script that evals this file
        GQ_GO_MINOR=999
    fi
}

# gq_junit FILE SUITE CASES: writes JUnit XML to FILE for CircleCI's Tests
# tab, from CASES, a JSON array of test cases:
#   {"classname": ..., "name": ..., "status": "failed" | "skipped" | "passed",
#    "message": ..., "detail": ...}
# A run with no cases gets one passing case, so the tab shows it ran.
gq_junit() {
    local dir=${1%/*}
    mkdir -p "${dir}"
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --arg suite "$2" '
        (if length == 0 then [{classname: $suite, name: "no findings", status: "passed"}] else . end) as $cases
        | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<testsuites>",
          "  <testsuite name=\"\($suite | @html)\" tests=\"\($cases | length)\" failures=\"\([$cases[] | select(.status == "failed")] | length)\" skipped=\"\([$cases[] | select(.status == "skipped")] | length)\">",
          ($cases[] |
            "    <testcase classname=\"\(.classname | @html)\" name=\"\(.name | @html)\">"
            + (if .status == "failed" then "<failure message=\"\((.message // "") | @html)\">\((.detail // "") | @html)</failure>"
               elif .status == "skipped" then "<skipped message=\"\((.message // "") | @html)\"/>"
               else "" end)
            + "</testcase>"),
          "  </testsuite>",
          "</testsuites>"
    ' <<< "$3" > "$1"
}

# gq_gate FINDINGS REPORT_ONLY SUMMARY: ends a check. Without findings it
# succeeds. With findings it fails with SUMMARY, unless REPORT_ONLY is true,
# when it only warns: the reports are written either way.
gq_gate() {
    if [[ "$1" == false ]]; then
        echo "Passed: $3"
        exit 0
    fi
    if [[ "$2" == true ]]; then
        echo "WARN: $3" >&2
        echo "WARN: report_only is true, so this step passes. The reports are in ${GQ_OUT}." >&2
        exit 0
    fi
    echo "ERROR: $3" >&2
    echo "  The reports are in ${GQ_OUT}. Set report_only to true to report findings without failing." >&2
    exit 1
}

# gq_plural COUNT SINGULAR PLURAL: prints COUNT and the word that goes with
# it, such as "1 file" or "2 files".
gq_plural() {
    if [[ "$1" -eq 1 ]]; then
        printf '%s %s\n' "$1" "$2"
    else
        printf '%s %s\n' "$1" "$3"
    fi
}

# gq_tail FILE [LINES]: prints the last LINES (default 40) lines of FILE to
# stderr, indented, to show why a tool failed.
gq_tail() {
    tail -n "${2:-40}" "$1" | sed 's/^/  /' >&2
}
