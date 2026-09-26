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
It will drive these scripts, probably over `ssh <server> sudo <command>`. So every script must be automatable:

- Every input has a flag. Prompts appear only when a value is missing **and** stdin is a TTY.
- When stdin is not a TTY and a required value is missing, exit non-zero naming the missing flag. Never hang waiting for input.
- Secrets never go in argv (visible in `ps`). Read them from stdin (`--password-stdin`, like `docker login`) or from the `--config` JSON.
- Destructive actions take `-y` to skip confirmation.
- Exit code 0 on success, non-zero on failure. Errors go to stderr.
- List and status commands get a `--json` output as they are built (`dhis2-list-instances`, backups, remotes).
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
