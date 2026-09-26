# dhis2-tools-ng (redmondking fork)

Bash tooling to run DHIS2 on a single Ubuntu host using LXD containers:
one nginx proxy (apache2 on older installs, being phased out), one postgres, optional munin monitor, and one
tomcat container per DHIS2 instance.

- `origin`: github.com/redmondking/dhis2-tools-ng
- `upstream`: github.com/bobjolliffe/dhis2-tools-ng (fork was level with it as of 2026-09-25).
  This fork is the user's own project and is not contributed back. `upstream` is kept only to pull fixes.

## Layout

Repo:
- `install.sh` – installs or updates the tools from GitHub (hardcoded `redmondking/dhis2-tools-ng`, branch `master`)
- `setup/lxd_setup.sh` (`dhis2-setup`) – host bootstrap: LXD, sysctl, ufw, then `install_scripts.sh` and `create_containers.sh`
- `setup/ssl_setup.sh` (`dhis2-ssl-setup`), `setup/upgrade_setup.sh` (`dhis2-upgrade-setup`)
- `setup/parse_config.sh` – reads `/usr/local/etc/dhis/containers.json` into shell variables
- `setup/containers/<type>` – script piped into a new container; `<type>_postsetup` is then sourced on the host
- `setup/service/dhis2-*` – admin commands
- `setup/etc/*` – templates copied once to `/usr/local/etc/dhis` (never overwritten)
- `setup/configs/*` – LXD preseed, sysctl, proxy/postgres configs, `containers.json.sample`

On a server:
- `/opt/dhis2-tools/` = the repo's `setup/` + `install.sh` + `VERSION` (sha, date). Replaced by every update.
  The previous version is kept in `/opt/dhis2-tools.old` (`dhis2-tools-update --rollback`).
- `/usr/local/bin/dhis2-*` = symlinks into `/opt/dhis2-tools`: `dhis2-setup`, `dhis2-ssl-setup`, `dhis2-upgrade-setup`,
  `dhis2-tools-update`, plus every `service/*` script under its own name. Internal scripts get no link.
- `/usr/local/etc/dhis/` = this server's settings; updates never replace them.
- Entry scripts `cd "$(dirname "$(readlink -f "$0")")"` so their relative paths work from anywhere.
- **Any change to an `etc/*` template or to installed state must ship with a matching `upgrade_setup.sh` step**,
  because `dhis2-tools-update` runs `dhis2-upgrade-setup` after installing.
- `install.sh` testing overrides: `DHIS2_TOOLS_BRANCH` (e.g. develop), `DHIS2_TOOLS_DEST`, `DHIS2_TOOLS_BIN`.
  Exit codes: 0 ok, 1 error, 2 update available (`--check`).

Scripts must run on the Ubuntu host as root with `lxc`, `jq` and `ufw` available.
Nothing here runs on macOS, so check syntax locally with `bash -n` and `shellcheck`.

## Workflow

- **Before starting any task:** discuss all its features and requirements with the user and agree on them.
  Then create the plan **in plan mode** (EnterPlanMode, then present it with ExitPlanMode) and get it approved. Only then implement.
  Whenever the user says "create a plan", that means plan mode.
- Work on the `develop` branch. `master` stays at the original code (`a37e7db`) until testing passes, then `develop` is merged into it.
- Commit messages must not mention Claude or carry Claude attribution.

## Future management system

The user will later build a Nuxt web app to manage servers: deploy instances on existing servers, manage backups, and so on.
It will drive these scripts, probably over `ssh <server> sudo <command>`, and Ansible may drive them too.
So every command follows the rules below.

## Command and flag rules (every `dhis2-*` command, existing and new)

Agreed with the user 2026-09-26. Existing commands are brought in line in phase 3b; new commands follow the rules from the start.

**Inputs**
- Every input has a flag. Positional arguments are only for the main subject (usually the instance name).
  Any other positional argument also gets a named flag (e.g. `--ip`, `--postgres`).
- Prompts appear only on a terminal, and only for values not given as flags.
- `-y` means nothing is asked at all. Every required answer must come from a flag, or from a default documented as safe.
  If anything is missing, the command stops **before changing anything** and lists **all** missing flags in one error (exit 3).
- Without `-y` and without a terminal, nothing can be asked, including a confirmation. The command stops and says to add `-y` (exit 3).
  Automation therefore always passes `-y`, and nothing ever hangs.
- Secrets never go in argv (visible in `ps`):
  - one secret: `--password-stdin` (like `docker login`)
  - several secrets in one command: **pending the user's answer**. Proposed: one `--<what>-password-file <file|->` flag per secret
    (`-` = stdin), e.g. `--glowroot-password-file`, `--admin-password-file`. JSON on stdin was rejected (too cumbersome for people).
  - install: inside the `--config` JSON

**Before changing anything**
- A command that changes things shows a **summary** of what it will do. On a terminal it asks to confirm; `-y` skips that.
- `--dry-run` on every command that changes state: check everything, print the summary (what would change and whether it
  would be refused), change nothing. Exit 0, or the exit code the real run would give if it would be refused (1 or 3).
- Destructive or risky actions need confirmation. The riskiest (e.g. going back to an older DHIS2 release) also need `--force`,
  plus typing the instance name on a terminal, or `--force -y` without one.

**Output**
- `--json` on every list/status command. Missing values are `null`. With `--json`, stdout is pure JSON; everything else goes to stderr.
- Errors go to stderr through `die` (`lib/dhis2-lib.sh`).
- `-h`/`--help` lists every flag with its default, and exits 0.

**Exit codes**
- 0 success (also for `--dry-run`)
- 1 failure, or refused
- 2 update available (`dhis2-tools-update --check` only)
- 3 missing input (a required flag was not given, or a confirmation is needed and there is no terminal)
- A command never exits 0 after a partial failure: e.g. one failed database in a backup run means a non-zero exit.

**State**
- All state lives on the server: container labels `user.dhis2.*` and files in `/usr/local/etc/dhis`. Nothing is kept only in the tool's memory.
- Re-running a command should be safe (check before changing).

## Install

Two ways, both required:

- **People**: `sudo ./setup.sh` runs the wizard (plain bash prompts for now), which writes `containers.json`.
- **Automation** (Ansible, the future Nuxt app): `sudo ./setup.sh --config <file|->` asks nothing.
  All answers come from the file, or from stdin with `-`, in the same JSON format the wizard writes.
  - Secrets (Munin password, shared Glowroot password, ...) may be included in that input. `setup.sh` strips them before saving
    `/usr/local/etc/dhis/containers.json`, which never holds plaintext passwords.
  - A missing required value is an error naming it. It never falls back to a prompt when stdin isn't a TTY.
  - `configs/containers.json.sample` stays as the documented example of this format, kept complete and in sync with the wizard.
- Single-secret commands (e.g. `dhis2-munin-login`, `dhis2-glowroot-login`, instance creation in own-login mode) take `--password-stdin`.
- Ansible example: template the JSON (secrets from Ansible Vault) to a root-only file, run `setup.sh --config` on it, then delete it.

## Conventions

- Keep scripts plain bash, matching the existing style (`lxc exec $NAME -- ...`, heredocs for config files).
- Quote variables in new or changed code.
- Keep every script usable non-interactively. Prompt only when an argument is missing and stdin is a TTY (`[[ -t 0 ]]`).
