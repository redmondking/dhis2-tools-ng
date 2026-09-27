# CLAUDE.md

Operational rules for the dhis2-tools-ng fork. See `architecture.md` for the design and every agreed decision, and
`tasks.md` for the work by phase, its status and "Where we are" (the next step).

## 1. Repositories

*   **`origin`:** github.com/redmondking/dhis2-tools-ng. The user's own project. All work goes here.
*   **`upstream`:** github.com/bobjolliffe/dhis2-tools-ng. Only for pulling fixes. Push is disabled.

## 2. Environment

*   **Language:** Bash
*   **Target:** scripts run as root on Ubuntu 24.04 hosts, and on existing 20.04/22.04 hosts through
    `dhis2-upgrade-setup`, with `lxc`, `jq` and `ufw` available

The repo layout and what runs where are in `architecture.md` (Overview, Commands, Install, update and migrate, Containers and packages).

## 3. Commands

| Task | Command |
| :--- | :--- |
| Syntax check | `bash -n <file>` |
| Lint | `shellcheck <file>` |
| Install from the release branch on the test server | `curl -fsSL https://raw.githubusercontent.com/redmondking/dhis2-tools-ng/refs/heads/release/0.1.0/install.sh \| sudo DHIS2_TOOLS_BRANCH=release/0.1.0 bash` |

Real tests are only done on the test server, never on the development machine. Locally, check every changed file with
`bash -n` and `shellcheck`, and test logic with stand-in `lxc`/`curl` scripts in the scratchpad.

## 4. Workflow

*   **Tasks and phases:** A task is one numbered line in `tasks.md` (e.g. 3.1). A phase is a group of tasks (e.g. phase 3).
*   **Branches:** Work on the branch of the version being built, `release/<version>` (now `release/0.1.0`). `master` holds
    released code only, and stays at the original code (`a37e7db`) until `0.1.0` is released. See `architecture.md`, Versions and releases.
*   **Merging:** Move `master` to a release (fast-forward from the release branch) only after asking the user and getting a yes in chat. Pushing any branch,
    force-pushing and rebasing are left to the user.

### Delivery Steps
1.  **Discuss:** Before starting a phase, discuss its tasks with the user and agree on them.
2.  **Plan:** Create the plan in plan mode (EnterPlanMode, then ExitPlanMode for approval). If a task turns out to be
    large or unclear once work starts, stop and plan it on its own before continuing.
3.  **Implement:** Follow sections 5 and 6.
4.  **Check:** Run the local checks in section 3 and fix what they find before moving on.
5.  **Record:** Update `tasks.md`, and `architecture.md` if a decision changed (section "Updating architecture.md"), in the same commit.
    Add anything that needs a real server to check to task 1.3. Then mark the task `[~]`.
6.  **Approve:** The user approves a whole phase, not single tasks. When the user says a phase is tested and approved,
    mark all of its `[~]` tasks `[x]` in one commit. Never mark anything `[x]` without that approval.

### Commits
*   Each commit belongs to one task and starts with its number, e.g. `3b.7 dhis2-logview: run journalctl with an argument list`.
    A large task may take several commits.
*   Commit messages carry no Claude attribution and no `Co-Authored-By` footers.
*   Fix only what the task says. A bug found on the way becomes a new line in `tasks.md`.
*   Secrets never go in code, `tasks.md`, `architecture.md`, commits or chat.

### Updating architecture.md
*   It describes the **current design only**: what the tools do and the rules they follow. No history, no dates, no "agreed on",
    "changed from" or reasons for past choices (git history keeps those), and no decisions log.
*   When a decision is made or changed, **edit the section it belongs to**: replace the old text, don't add a new paragraph
    next to it. One area per section; short rules, lists and tables rather than prose.
*   Mark parts that aren't built yet with the version they come in, e.g. `[0.3.0]`; remove the mark once built.
*   Keep it lean: if a section grows, tighten it. Details of how something is implemented belong in the code or `tasks.md`.
*   After every edit, check that no section or rule went missing.

### Editing Files
*   Use replacements that fail when the expected text is not found. After editing a doc, check that no section went missing.

## 5. Command and Flag Rules

*   A flag for every input. Positional arguments only for the main subject (usually the instance name).
*   Prompts only on a terminal, and only for values not given as flags.
*   `-y` asks nothing. Every missing flag is listed in one error, exit 3, before anything changes.
*   No `-y` and no terminal: stop and say to add `-y`, exit 3.
*   A summary before changing anything, and `--dry-run` on every command that changes state.
*   Destructive actions need confirmation. The riskiest also need `--force`.
*   `--json` on list and status commands. With `--json`, stdout is pure JSON.
*   Secrets are typed interactively by people, or passed as JSON with `--secrets-stdin` by automation. Never in argv.
*   Errors go to stderr through `die`. Exit codes 0 success, 1 failure or refused, 2 update available, 3 missing input.
    Never exit 0 after a partial failure.
*   `-h`/`--help` lists every flag with its default.

## 6. Coding Principles

*   **Existing style:** Plain bash as the scripts already use it: `lxc exec "$NAME" -- ...`, heredocs for config files.
*   **Names:** New commands, flags, labels and files follow the closest existing name in the repo.
*   **Shared helpers:** Use and extend `setup/lib/dhis2-lib.sh`. Never copy a helper into a command.
*   **Quoting:** Quote every variable in new or changed code.
*   **`set -euo pipefail`:** In new or rewritten scripts only. Never add it to an old script as a side effect, it changes behaviour.
*   **Portability:** `awk` is mawk on Ubuntu, so no gawk-only features (`gensub`, `length(array)`). Container scripts
    never assume the host's tools.
*   **Idempotent:** Every script is safe to run twice. Append config only when its marker line is not already there.
*   **Existing servers:** Any change to installed state or to an `etc/*` template ships with a matching
    `dhis2-upgrade-setup` step (`dhis2-server migrate` from 0.3.0) that patches only known lines (`architecture.md`, Install, update and migrate).
*   **No shell strings:** User input never reaches a shell string. Run commands in containers with an argument list,
    never `lxc exec "$NAME" -- bash -c "$input"`.

## 7. Test Server

*   Touch only the test server the user provides for task 1.1. Never any other host.
*   Before anything that deletes or replaces something (`delete_all.sh`, `dhis2-delete-instance`, `lxc delete`, dropping
    a database, wiping `/opt/dhis2-tools`), say what it will remove and wait for the user to agree in chat. `-y` is not consent.
*   Record every command run on the server, in order, with its exit code, in the notes for that task.
*   Report a result only from output actually seen. Anything not seen stays `[~]`.

## 8. When Unsure

*   If a task is ambiguous, requirements conflict, or `architecture.md` does not cover it: stop and ask. One focused
    question is better than a wrong assumption.
*   A decision exists only once it is in `architecture.md`. Agreement in chat is not enough.