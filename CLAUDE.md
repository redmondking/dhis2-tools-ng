# dhis2-tools-ng (redmondking fork)

Bash tools that run DHIS2 on one Ubuntu server with LXD containers (nginx proxy, PostgreSQL, optional Munin,
one Tomcat container per DHIS2 instance), driven by `dhis2-*` commands.

- `origin`: github.com/redmondking/dhis2-tools-ng: the user's own project; all work goes here.
- `upstream`: github.com/bobjolliffe/dhis2-tools-ng: the original, kept only to pull fixes (push disabled; nothing is contributed back).

## Read first

- `architecture.md`: the design and every agreed decision. The reference for how things work and why.
- `tasks.md`: the work by phase, its status (`[~]` = done but not tested on a real server), and "Where we are" (next step).

## Workflow

- **Before starting any task:** discuss all its features and requirements with the user and agree on them.
  Then create the plan **in plan mode** (EnterPlanMode, then ExitPlanMode for approval). Only then implement.
  Whenever the user says "create a plan", that means plan mode.
- Work on the `develop` branch. `master` stays at the original code (`a37e7db`) until testing passes, then `develop` is merged in.
- Commit messages must not mention Claude or carry Claude attribution.
- Record agreed decisions in `architecture.md` (including its decisions log) and status in `tasks.md` as they happen.

## Rules when writing code

- Every command follows the **command and flag rules** (`architecture.md` section 12). In short:
  - a flag for every input
  - prompts only on a terminal
  - `-y` = ask nothing: every missing flag is listed in one error, exit 3
  - a summary before changing anything, and `--dry-run`
  - `--json` on list/status commands
  - secrets interactive for people, `--secrets-stdin` JSON for automation, never in argv
  - errors to stderr through `die`
  - exit codes 0/1/2/3
- Any change to installed state or to an `etc/*` template needs a matching `dhis2-upgrade-setup` step (`architecture.md` section 14).
- Use and extend the shared helpers in `setup/lib/dhis2-lib.sh`; don't duplicate them in commands.
- Plain bash in the existing style (`lxc exec $NAME -- ...`, heredocs for config files). Quote variables in new or changed code.
- Scripts run on the Ubuntu host as root, with `lxc`, `jq` and `ufw` available.

## Checking changes

- Nothing here runs on macOS: check with `bash -n` and `shellcheck`, and test logic with stand-in `lxc`/`curl` scripts
  in the scratchpad. Mark anything untested on a real server as `[~]` in `tasks.md` and add it to the test list (task 1.3).
- Edit files with replacements that **fail when the expected text isn't found**. A too-wide replace once deleted
  ~110 lines of this file (commit `356d186`) and a later edit silently did nothing. After editing docs, check that no section went missing.
