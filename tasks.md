# Tasks

Design and decisions are in `architecture.md`; how Claude works is in `CLAUDE.md`. This file tracks the work.
Phases are roughly in order: each phase builds on the ones before it.

Status: `[ ]` todo, `[x]` done, `[~]` done but not tested on a real server.

## Where we are (2026-09-26)

- Branch `develop`, nothing pushed. `master` is still the original code (`a37e7db`).
- Phases 0, 2, 3 and 3b are written and committed. Nothing has been tested on a real server yet: all `[~]`.
- Command and flag rules agreed (`architecture.md` section 12). Every command was audited; the results are phase 3b
  (existing commands) and the automation notes in phases 4–9 (new commands).
- 2026-09-26: the design moved from `CLAUDE.md` into `architecture.md`, restoring sections accidentally deleted in commit `356d186`.
- Phase 3b is done (all `[~]`), including 3b.17 (certbot webroot for nginx, config test with rollback).
- **Next step:** phase 4 (hostnames and paths): discuss (including several base domains per server), then plan in plan mode.
- Testing (phase 1) waits until the scripts are written, as the user asked.
  Needed then: test server IP, SSH access for Claude, and a test domain with wildcard DNS.
- Until `develop` is merged, install on the test server with
  `curl -fsSL https://raw.githubusercontent.com/redmondking/dhis2-tools-ng/develop/install.sh | sudo DHIS2_TOOLS_BRANCH=develop bash`
  (this needs `develop` pushed first).

## Phase 0 – Bug fixes

- [~] 0.1 `dhis2-create-instance`: `-n` ignored, `JAVA_HOME` rendered as `java-{{ 17 }}-...`, gawk-only free-IP pick, prefix-matching name checks
- [~] 0.2 `ssl_setup.sh`: renewal cron written to the host. Now uses certbot's own timer, with a prompt for auto-renewal
- [~] 0.3 `dhis2-delete-instance`: required 2 args, broke `/etc/hosts`, no confirmation, left the instance's `pg_hba.conf` line and postgres firewall rule behind
- [~] 0.4 `dhis2-restoredb`: no argument checks, no confirmation
- [~] 0.5 sysctl typo, appended on every run and never applied
- [~] 0.6 NAT network hardcoded to `192.168.0.0/24`
- [~] 0.7 rsyslog logger: wrong subnet, broken config, apt prompt
- [~] 0.8 `upgrade_setup.sh`: repairs servers installed with the old scripts

## Phase 1 – Test what's done

- [ ] 1.1 Test server: Ubuntu 24.04, public IP, can be wiped completely.
  - Claude runs the tests over SSH first. The user re-runs them once all bugs are fixed.
  - Needs from the user: IP/host, SSH user and key access (root or passwordless sudo), and a test domain with DNS for the fqdn and subdomains (a wildcard record is simplest).
- [ ] 1.2 Install with the **original** scripts (`a37e7db`) and create an instance with glowroot, then run `upgrade_setup.sh` and check every step
- [ ] 1.3 Fresh install from `develop` on 24.04 (`DHIS2_TOOLS_BRANCH=develop` with the curl installer), then check:
  - bug fixes:
    - `-n`
    - `JAVA_HOME`
    - free-IP pick with a stopped container
    - `certbot renew --dry-run`
    - delete instance
    - restore database
    - `sysctl` values
    - `iptables -t nat -S`
    - rsyslog
  - install/update:
    - `dhis2-tools-update` (`--check`, update, `--rollback`)
    - commands work from any directory
  - Ubuntu packages:
    - PostgreSQL 16 + PostGIS
    - nginx + certbot (timer renews)
    - containers on 24.04, instances on 22.04
  - Glowroot login:
    - shared and own modes
    - `dhis2-glowroot-login` with and without an instance
    - Glowroot 0.14.7 working on DHIS2 2.38 and 2.41
  - Munin:
    - asks for a login
    - `/munin` stays closed without one
  - `-g no` / `-m no` on instance creation
  - phase 3:
    - create a 2.38, a 2.41 and a 2.42 instance (22.04/tomcat9 and 24.04/tomcat10)
    - Tomcat 10 reads `/etc/default/tomcat10` the same way as tomcat9 (JAVA_HOME, JAVA_OPTS)
    - `dhis2-deploy-war`: patch update, going back with `--force`, refused major version
    - `dhis2-list-instances` and `--json`
    - `dhis2-upgrade-setup` labels on an instance made with the original scripts
    - Glowroot on Tomcat 10
  - phase 3b:
    - `dhis2-create-instance` interactively: the create/deploy menu, the source menu, own war file and URL, `--based-on`,
      create only (`--line`), summary and "Create it?"; checksum failure menu with "choose another release"
    - `dhis2-create-instance -y` from a script with `--secrets-stdin`, and `--dry-run` (nothing created)
    - `dhis2-deploy-war` interactively: source menu, summary, going back with `--force` (typed instance name), a create-only
      instance getting its first release; `-y` and `--dry-run` from a script
    - `dhis2-upgrade-setup --dry-run` on a server set up with the original scripts (nothing may change), then a run without a
      terminal with `--secrets-stdin` (Munin login, own Glowroot logins; an instance without a password is skipped with a warning)
    - `dhis2-glowroot-login` (shared and own) and `dhis2-munin-login`, interactively and with `--secrets-stdin -y`; the new
      login works after the restart
    - `dhis2-restoredb` into a running instance: tomcat stops, the restore runs, tomcat starts; with a broken dump it must
      exit non-zero and still start tomcat
    - `dhis2-delete-instance --dry-run`, then a real delete; `dhis2-delete-instance postgres` must refuse
    - `dhis2-ssl-setup --dry-run` (staging test), then a real run; without a terminal and without `-y` it must stop (exit 3)
    - 3b.17: during `dhis2-ssl-setup`, a loop of `curl` requests shows no failed request (nginx never stops); `certbot renew --dry-run`
      works; with DNS not pointing at the server the site stays up on http and the command exits 1; the rendered https
      `nginx.conf` passes `nginx -t` and `http://<fqdn>/.well-known/acme-challenge/x` is not redirected; `dhis2-upgrade-setup` on a
      server with a standalone certificate (original scripts): the challenge is added, the certificate moves to webroot and its
      test renewal passes; on a failing test renewal the old renewal config is put back
    - `dhis2-logview`: `-f`, `-r`, `-g` with quotes and `;` in the text (must only search), `-S`/`-U`, `-n`, `--json` on Tomcat 9 and 10
- [ ] 1.4 Merge `develop` into `master` and push

## Phase 2 – Install/update, lock down monitoring, modernise the base

- [~] 2.1 Proxy, postgres and monitor containers on Ubuntu 24.04 (`create_containers.sh`, `change_webserver.sh`); instances on 22.04 until phase 3
- [~] 2.2 `postgres` type: PostgreSQL 16 + `postgis-3` from Ubuntu's own packages. `postgres12` deleted
- [~] 2.3 No `apt-key` left: postgres, nginx and certbot now come from Ubuntu's own packages (no third-party repos, no snap)
- [ ] 2.5 Check that DHIS2 2.38 runs on PostgreSQL 16. If not, support a second postgres container on 14 (on the test server)
- [~] 2.6 Proxy configs: OCSP stapling and `X-XSS-Protection` removed. `listen … http2` kept, because nginx 1.24 has no `http2 on;`
- [~] 2.7 Glowroot: one version (0.14.7) for every Java version
- [~] 2.8 `chown x.y` → `x:y`
- [~] 2.9 Deleted `configs/containers.json.exampleused` and `setup/destroy` (`.DS_Store` was never in the repo)
- [~] 2.10 `containers.json.sample` defaults to nginx (the wizard follows in phase 5)
- [~] 2.12 Install into `/opt/dhis2-tools` with `dhis2-*` commands in `/usr/local/bin`. `install.sh` = first install + `dhis2-tools-update`
      (`--check` exits 2, `-y`, `--rollback`), updating from hardcoded `redmondking/dhis2-tools-ng` master
- [~] 2.13 Shared helper file `lib/dhis2-lib.sh`: prompts that never hang without a terminal, `--password-stdin`, Glowroot password hash
      (checked against Glowroot's own code)
- [~] 2.14 Glowroot login: no more anonymous admin. Shared or per-instance login, `dhis2-glowroot-login`, `-g`/`-U` on instance creation
- [~] 2.15 Munin login on `/munin` (`dhis2-munin-login`), Munin optional per instance (`-m`). `dhis2-tomcat-munin` fixed and safe to re-run
- [~] 2.16 `dhis2-upgrade-setup` for running servers:
  - replaces old copied scripts with links
  - closes open Munin/Glowroot pages
  - patches `tomcat_setup`
  - asks about all restarts at the end

Moved: 2.4 (Tomcat per instance) → 3.0; 2.11 (switch apache servers to nginx) → 8.8.

## Phase 3 – Multiple DHIS2 versions

Requirements agreed with the user on 2026-09-26.

- [~] 3.0 Tomcat per instance: `tomcat9` on 22.04 or `tomcat10` on 24.04, stored as `user.dhis2.tomcat`.
  - Every script that assumed `tomcat9` reads it instead: the service name, `/var/lib/tomcat*`, `/etc/tomcat*`, `/etc/default/tomcat*`.
    That covers `etc/tomcat_setup`, `etc/tomcat_default`, `dhis2-create-instance`, `dhis2-deploy-war`, `dhis2-logview`,
    `dhis2-tomcat-munin`, `dhis2-glowroot-login` and `upgrade_setup.sh`.
  - On existing servers, `dhis2-upgrade-setup` updates the copied `tomcat_setup` template, touching only those names.
- [~] 3.1 Shared helpers: release feed, version facts, checksum-checked download, war deploy (`lib/dhis2-lib.sh`). Labels are read/written with plain `lxc config`
- [~] 3.2 Version list, the same in `dhis2-create-instance` and `dhis2-deploy-war`:
  - It shows **every** release from the feed for 2.38 and newer, including hotfixes (e.g. `2.42.5.2`), one line per version,
    marked supported or end of support.
  - The user types the **exact** release name. `2.42` is refused; `2.42.0` is accepted. The default is the newest release.
  - Non-interactive: `-V <exact release>`.
- [~] 3.3 The version decides the container, Tomcat and Java, with no questions:
  - 2.42+ → Ubuntu 24.04, tomcat10
  - 2.38–2.41 → Ubuntu 22.04, tomcat9
  - Java from the feed's `jdk` (2.41+ → 17, 2.38–2.40 → 11)
  - `-j` is removed.
- [~] 3.4 `dhis2-create-instance` deploys the chosen release straight away (no `--no-deploy`; a backup can be restored afterwards:
      stop, restore, start). The war is downloaded and checked against the feed's sha256 **before** the container and database are created.
  - On a mismatch it retries automatically (3 attempts), then asks: 1) try again 2) stop (nothing created).
  - Without a terminal it stops with exit 1. There is never a "deploy anyway". Custom builds go through `dhis2-deploy-war -f`.
- [~] 3.5 Record `user.dhis2.version` (e.g. `2.42.6`), `user.dhis2.tomcat` and `user.dhis2.java` on the container.
- [~] 3.6 `dhis2-deploy-war`:
  - Lists only the instance's own version line, with the current release marked. `-V <exact release>` installs it, with the sha256 check.
  - A different major version (2.41 → 2.42) is always refused and points to the upgrade script (phase 9).
  - Going back within a line (2.42.5 → 2.42.3) is refused unless `--force`. Then a warning (patch releases can change the database;
    restoring a backup from that release is the safe way) must be acknowledged by typing the instance name.
    Without a terminal, `--force -y` is required.
  - `-l <url>` and `-f <file>` stay, for custom builds (no checksum), and update the version label from the war's `dhis-api-*.jar`.
- [~] 3.7 `dhis2-list-instances` shows name, version, URL, Tomcat, Java, IP, status, Glowroot and Munin, with a `--json` output.
  - URL = `https://<fqdn>/<name>` until phase 4, or `http://` if there is no certificate yet.
- [~] 3.8 (was 8.1) `dhis2-upgrade-setup` labels existing instances:
  - version from `WEB-INF/lib/dhis-api-<version>.jar` (present in 2.38–2.42 wars), or `none` if nothing is deployed
  - tomcat `tomcat9`
  - java from the instance's `java`
  - glowroot/munin from what is installed
- [~] 3.9 (was 8.3, do first) `dhis2-upgrade-setup` changes type `postgres12` → `postgres` in `containers.json` before anything reads it
- Test on the server: Glowroot 0.14.7 with Tomcat 10 and DHIS2 2.42+ (Jakarta). If it doesn't work, turn Glowroot off automatically for 2.42+.
- Checked locally: feed helpers against the live feed; a real 2.38.7 war downloaded, checksum ok, release read from it;
  every `dhis2-deploy-war` rule with a stand-in `lxc`; `dhis2-list-instances` table and `--json`.

## Phase 3b – Existing commands follow the command and flag rules

Rules: `architecture.md` section 12, "Command and flag rules". Audit done 2026-09-26. New commands follow the rules when they are built (flags listed in their phase below).

- [~] 3b.1 Shared helpers: `need_flags` (collect every missing flag, then one error with exit 3), a summary/confirm helper,
      `--secrets-stdin` reader (JSON object on stdin, keys like `glowroot_password`; see `architecture.md` section 12), and "no terminal: add -y" (exit 3)
- [~] 3b.2 `dhis2-create-instance` (also 3b.15 and 3b.16 for this command):
  - first question: 1) create and deploy DHIS2 2) create only (`--no-deploy`); create only asks the version line (`--line 2.42`)
    to choose Ubuntu/Tomcat/Java
  - "where does DHIS2 come from": 1) official release (`-V`) 2) own war file (`-f`) 3) own war at a URL (`-l`)
    - own war: its release is read from `dhis-api-*.jar` and decides Ubuntu/tomcat/java. If it can't be read, ask which version it is
      based on (`--based-on 2.41`) and record the version as `custom`. Optional `--sha256`.
    - label `user.dhis2.source` = `official` or `custom`
  - checksum failure menu: 1) try again 2) choose another release 3) stop
  - summary + "Create it?"
  - `-y` (all required flags, see `architecture.md` section 12; defaults: IP, postgres, Glowroot user `admin`, deploy)
  - `--dry-run`
  - `--ip`, `--postgres` as named flags; the positional forms keep working
  - two possible secrets (Glowroot password, and the DHIS2 admin password from 5.3): see the secrets rule in `architecture.md` section 12
- [~] 3b.3 `dhis2-deploy-war` (also 3b.16 for this command):
  - the same "where does DHIS2 come from" menu
  - `--based-on`, `--sha256`, and "choose another release" on a checksum failure
  - summary + confirm, `--dry-run`
- [~] 3b.4 `dhis2-delete-instance` (also refuses containers that are not DHIS2 instances; confirmation defaults to No): `--dry-run` (lists everything that would be removed), `--postgres`, "add -y" without a terminal, errors to stderr
- [~] 3b.5 `dhis2-restoredb` (also: a failure anywhere in the restore pipe now fails the command; the dump is checked with `gzip -t` first): summary; when the database belongs to an instance, stop its Tomcat, restore, start it again
      (shown in the summary); `--dry-run`, `--postgres` (no longer hardcoded; from phase 6 the default comes from the instance's
      `user.dhis2.postgres` label), "add -y" without a terminal
- [~] 3b.6 `dhis2-dbactivity --json`, `--postgres`
- [~] 3b.7 `dhis2-logview`: **security fix**. The `-g` text currently goes through a shell as root in the container.
      Run `journalctl` with an argument list instead. Fix `-f`/`-r` (they swallow the next argument). Add `--json` (journalctl `-o json`)
- [~] 3b.8 `dhis2-backup`: exit non-zero when any backup fails (today it always exits 0: only `gzip` after `pg_dump` counted), `--dry-run`
- [~] 3b.9 `dhis2-ssl-setup`:
  - `-y`, `--renew yes|no`, `--dry-run` (certbot's `--dry-run` against the Let's Encrypt test server)
  - **fix:** without a terminal it currently skips its "are you sure?" menu and requests the certificate
- [~] 3b.10 `dhis2-upgrade-setup --dry-run` (report what each step would change)
- [~] 3b.14 `dhis2-upgrade-setup` takes the Munin and Glowroot passwords (`--secrets-stdin`), plus `--restart`, `--renew`, `--glowroot-login`, `--glowroot-user`, `--munin-user` (agreed 2026-09-26), so automation can close
      open Munin/Glowroot pages without a terminal. Also the Glowroot login mode (`--glowroot-login shared|own`) and usernames
- [~] 3b.11 `dhis2-tools-update --check --json` → `{"current", "latest", "update_available"}`
- [~] 3b.12 `dhis2-glowroot-login` / `dhis2-munin-login`: `--dry-run`, summary + confirm; glowroot-login also `--restart yes|no` (which instances would change and restart)
- [~] 3b.13 `dhis2-tomcat-munin`: stop at the first failure and exit non-zero (names the failed step)
- [~] 3b.17 (found in 3b.9) `dhis2-ssl-setup`: stop when certbot fails. Today it carries on and switches nginx to a certificate
      that doesn't exist, which breaks the proxy. Agreed fix (2026-09-27): certbot **webroot** (the proxy never stops), https config
      only after the certificate exists, config test with rollback, and a `dhis2-upgrade-setup` step moving existing certificates
      from standalone to webroot (`architecture.md` section 4)
- [~] 3b.16 Every short flag also gets a long name, both in `-h` (`-V`/`--release`, `-g`/`--glowroot`, `-m`/`--munin`, ...)
- Order (agreed): 3b.1 helpers → 3b.2 create-instance, 3b.3 deploy-war → security fixes 3b.7 logview, 3b.9 ssl-setup → the rest.
- [~] 3b.15 `--password-stdin` → `--secrets-stdin` in `dhis2-create-instance`, `dhis2-glowroot-login`, `dhis2-munin-login`;
      `-U` → `--glowroot-user` / `--munin-user` (keep `-U` as a short form)

## Phase 4 – Hostnames and paths

- Section A (domains) discussed 2026-09-27: any hostname whose DNS points here (no base domains); `fqdn` → `default_hostname`;
  Munin's hostname a setting; a certificate email per hostname (`architecture.md` section 7). Sections B–G still to discuss.

- [ ] 4.1 nginx layout with one server block per hostname. Existing upstream files keep working under the fqdn
- [ ] 4.2 Page at each hostname root that lists its instances, regenerated whenever instances change
- [ ] 4.3 DNS check for a new subdomain: on failure, explain what to check and offer to retry (without a terminal: exit 1)
- [ ] 4.4 Certificate per subdomain, with the auto-renewal prompt (`dhis2-ssl-setup --hostname`, `--renew yes|no`)
- [ ] 4.10 Certificate failure handling (agreed 2026-09-27, `architecture.md` section 4), as shared helpers used by every hostname:
  - pre-flight checks: automatic staging test first; DNS points here; stray AAAA; CAA excluding Let's Encrypt; the proxy
    serves a test file from the challenge folder; port 80 reaches the proxy (host `ufw` + NAT)
  - plain reasons for certbot's common errors, plus the certbot log path
  - after 3 failed real attempts within an hour refuse unless `--force`; `--wait-dns`
  - new `dhis2-ssl-status` (`--json`): expiry, last renewal attempt and result, warning under 14 days (also shown by
    `dhis2-list-instances`)
  - `dhis2-ssl-setup --json`: success, failed stage, reason, retry time
- [ ] 4.5 `dhis2-create-instance` prompts:
  1. hostname (existing or new subdomain)
  2. path, validated
  3. container name [`<subdomain>-<path>`]

  Flags: `-H <hostname>`, `-p <path>` (both required with `-y`; name defaults to `<subdomain>-<path>`)
- [ ] 4.6 Quote instance names in all SQL, since names can contain `-`
- [ ] 4.7 `dhis2-delete-instance` (`--remove-hostname yes|no` for automation): remove the instance from its hostname. If it was the last one there, offer to remove the subdomain (never the fqdn)
- [ ] 4.8 `dhis2-move-instance <name> -H <hostname> [-p <path>]`: summary, `-y`, `--dry-run`
- [ ] 4.9 Glowroot at `/<path>-glowroot`

## Phase 5 – Interactive setup and instance creation

- [ ] 5.1 Setup wizard `setup.sh`: asks FQDN, email, TZ, monitoring, Glowroot defaults and login mode, backups, then writes `containers.json`
- [ ] 5.1b `setup.sh --dry-run`: check the config and print what would be set up
- [ ] 5.1a `setup.sh --config <file|->`: the same install with no prompts, for Ansible and the Nuxt app.
      Secrets are accepted in the input and stripped before saving. Update `containers.json.sample` to the full format
- [ ] 5.2 Service scripts prompt for missing arguments when run in a terminal:
  - `dhis2-deploy-war`
  - `dhis2-logview`
  - `dhis2-restoredb`
  - `dhis2-dbactivity`
  - `dhis2-delete-instance`
- [ ] 5.3 Admin login on a new instance:
  - Ask for the username [`admin`] and password [`district`].
  - If both are left as defaults, change nothing, but print a warning that the default login is publicly known.
  - If either differs, wait until DHIS2 is up and change it through the API.
  - Skip this step when the instance was restored from a backup.
- [ ] 5.4 Memory for the instance (Java heap + container limit), default based on free RAM (`--memory <size>`)
- Automation: `--dhis2-user`; the admin password is `dhis2_password` in `--secrets-stdin` (see `architecture.md` section 12)

## Phase 6 – Backups

- Where `dhis2-backup` gets its information (agreed 2026-09-26, details in `architecture.md` section 10):
  `dhis2-env` = how (server-wide settings), instance labels = what (`user.dhis2.backup`, `user.dhis2.postgres`),
  remotes files = where to copy. The old `PLAIN_BACKUPS`/`ENCRYPTED_BACKUPS` lists remain only for databases without an instance.
- [ ] 6.1 Setup wizard asks for the backup settings, each with a default. They are written to `dhis2-env` and the cron job is enabled.
  - time
  - daily backups to keep (7)
  - weekly backups to keep (3, Sunday)
  - monthly backups to keep (12, the 1st)
  - backup directory
  - optional remote rsync target
- [ ] 6.2 `dhis2-backup`: read what to back up from the labels (plus legacy list entries without an instance), dump each database from
      the container in its `user.dhis2.postgres` label, delete old monthly backups (`MONTHS_TO_KEEP`), quote names.
      A stopped instance: database still dumped; file store reported as skipped if it can't be archived (confirm when planning)
- [ ] 6.3 `dhis2-create-instance` (`--backup plain|encrypted|no`): "Back up this instance?" sets `user.dhis2.backup`, and always records
      `user.dhis2.postgres`. Nothing to clean up on delete: the labels go with the container
- [ ] 6.4 New layout: group by instance, then by date. Each run is one folder holding the database and the file store:
  ```
  /var/pgbackups/
    hmis-hmis/
      20260925_202500-daily/
        hmis-hmis.sql.gz
        hmis-hmis.files.tar.gz
      20260927_202500-weekly/
      20261001_202500-monthly/
    hmis2-hmis/
      20260925_202500-daily/
        hmis2-hmis.sql.gz.enc
        hmis2-hmis.files.tar.gz.enc
  ```
  - Retention (daily/weekly/monthly) is applied inside each instance's folder.
  - Files keep the instance name, so a copied-out file still says what it is.
- [ ] 6.5 `dhis2-backup` also backs up each instance's file store:
  - `/opt/dhis2/files` → `<name>.files.tar.gz`, next to `<name>.sql.gz` in the same run folder
  - Taken from the instance container of the same name. If no such container exists, skip it with a note.
  - Encrypted the same way as its database (`.files.tar.gz.enc`) when the instance is in `ENCRYPTED_BACKUPS`.

### Remote backups

- [ ] 6.6 `dhis2-backup-remote` with subcommands:
  - `add` (prompts, as in the example below)
  - `list` (name, type, target, mode, last success, status)
  - `test <name>`
  - `sync [name]` (send now)
  - `remove <name>` (asks first, never deletes anything on the remote)

  Any number of remotes, each stored in `/usr/local/etc/dhis/remotes/<name>`.
- [ ] 6.7 Remote types (both):
  - **SSH server** via `rsync`. `add` creates a key per remote (`/root/.ssh/dhis2-backup-<name>`), offers to install it with `ssh-copy-id`, then tests connect, write and delete.
  - **Cloud storage** via `rclone` (S3, Backblaze B2, Google Drive, Azure, ...). Install the Ubuntu package when the first cloud remote is added.
- [ ] 6.8 Mode per remote, chosen in `add`:
  - `keep` (default): never delete on the remote
  - `mirror`: delete what is deleted locally (`rsync --delete` / `rclone sync`)
- [ ] 6.9 Adding a cloud remote while some instances are backed up unencrypted:
  - Warn, naming the instances.
  - Offer to switch them to encrypted (`ENCRYPTED_BACKUPS`), creating the password file if there isn't one.
  - Remind the user to keep a copy of the password file off the server, since the backups can't be restored without it.
- [ ] 6.10 `dhis2-backup` sends to every remote after the local run.
  - A failed remote doesn't stop the others.
  - Results are logged to `/var/log/dhis2-backup.log` and shown by `list`.
- [ ] 6.11 Setup wizard asks "Add a remote backup location now? [y/N]" and runs `add`.
- [ ] 6.13 `dhis2-list-backups [instance] [--json]` (new, agreed 2026-09-26): instance, date, type, size, files archive yes/no, encrypted yes/no.
      The Nuxt app's backup screen and the restore menu (7.1) use it
- [ ] 6.14 `dhis2-backup --json`: per instance, whether the database and the file store succeeded, and where they were written
- Automation of `dhis2-backup-remote`:
  - `add` takes `--name --type ssh|cloud --host --user --path --mode keep|mirror`
  - `list --json`; `test` sets the exit code; `sync --dry-run` (rsync `-n` / rclone `--dry-run`); `remove -y`
  - SSH key install needs the remote password (`ssh-copy-id`), so without a terminal: `--install-key no` prints the public key
    for the caller to add on the remote (agreed 2026-09-26)
  - cloud credentials as secrets (see `architecture.md` section 12)
- [ ] 6.12 Later: alert on failure (e.g. email to the address in `containers.json`). No `fetch` from remotes (user decision).

Example:
```
$ sudo dhis2-backup-remote add
Name for this remote: offsite1
Type: 1) Another server over SSH  2) Cloud storage (S3, Backblaze B2, Google Drive, ...)
Server: backup.example.org
Username on that server: dhis2backup
Folder on that server [/backups/hmis.example.com]:
Old backups on the remote: 1) Keep everything  2) Mirror
Install the key on backup.example.org now? [Y/n]
Testing: connect ✓  write ✓  delete test file ✓
```

## Phase 7 – Create an instance from a backup

- [ ] 7.1 `dhis2-create-instance` asks "Restore from a backup? [y/N]":
  - Offer a menu of the backups found in `BACKUP_DIR` (instance, date, type, size), or let the user give another file path.
  - Check that the file exists and is valid gzip.
  - Ask "Which DHIS2 version is this backup from?" using the version menu.
  - Backups older than 2.38 are refused with an explanation.
- [ ] 7.2 Deploy that release as usual, then stop tomcat, restore the backup (`dhis2-restoredb -y`), and start it again
      (agreed 2026-09-26: no "create without deploying" needed for this)
- Automation: `--restore <file>`, `--restore-files yes|no`, `--backup-password-file <path>` for encrypted backups
- [ ] 7.3 Skip the admin login step (5.3), since the backup brings its own users
- [ ] 7.4 Accept encrypted backups (`.sql.gz.enc`): ask for the password file [`PASSWORD_FILE` from `dhis2-env`]. `dhis2-restoredb` gets the same support
- [ ] 7.5 If a matching `<name>.files.tar.gz[.enc]` sits next to the database backup, offer to restore it into `/opt/dhis2/files` (owned by tomcat)

## Phase 8 – Bring existing servers forward (`upgrade_setup.sh`)

- [ ] 8.1 Label existing instances with `hostname` = fqdn and `path` = container name (version/tomcat/java moved to 3.8)
- [ ] 8.2 Move proxy config to the per-hostname layout
- [ ] 8.3 (moved to 3.9)
- [ ] 8.4 Optional PostgreSQL 13 → 16 upgrade, with a checked backup first
- [ ] 8.5 Keep existing `dhis2-env` backup settings, only adding new keys (`MONTHS_TO_KEEP`)
- [ ] 8.9 Backup labels for existing instances:
  - `user.dhis2.postgres` from `connection.url` in `/opt/dhis2/dhis.conf`
  - names in `PLAIN_BACKUPS`/`ENCRYPTED_BACKUPS` with an instance container → `user.dhis2.backup` = `plain`/`encrypted`,
    and removed from the lists; names without an instance stay in the lists
  - all other instances → `user.dhis2.backup` = `no`
  - must run before the new `dhis2-backup` is used, so no backup is missed; stopped instances are labelled too (labels
    don't need the container running; `dhis.conf` does, so the postgres label waits for a running container, defaulting to `postgres`)
- [ ] 8.6 Move existing backups into the new layout: `backup<date>-<type>/<db>.sql.gz*` → `<db>/<date>-<type>/`.
      Tell the user the remote copy will receive the new layout, and that the old remote folders are left for them to remove.
- [ ] 8.7 Turn an old `REMOTE=` setting in `dhis2-env` into remote `remote1`, SSH type, mode `keep` (same behaviour as before)

- [ ] 8.8 On apache servers, offer to switch to nginx (rework `change_webserver.sh`: hardcoded 192.168.0.3 and network, per-hostname layout).
      Delete apache support (`containers/apache_proxy*`, `configs/apache-dhis2.conf`, apache branches) once that switch is tested

## Phase 9 – DHIS2 version upgrade script (last)

- [ ] 9.1 Design first. Things to handle:
  - allowed upgrade steps (one version at a time?)
  - backup of the database and the file store before starting, plus a rollback plan
  - Java change
  - **2.41 → 2.42 crosses Tomcat 9 / 22.04 → Tomcat 10 / 24.04.** This needs a new container, carrying over:
    - `dhis.conf`
    - `/opt/dhis2` (file store)
    - glowroot
    - IP
    - proxy entry
    - labels
  - follow database migrations in the log, and check health after start
  - app compatibility and analytics tables
  - downtime warning and confirmation
- [ ] 9.2 Build `dhis2-upgrade-instance`: `-V <release>`, summary, `-y`, `--dry-run`, backup first (default yes)

## Phase 10 – Docs and polish

- [ ] 10.1 Rewrite `README.md` and `docs/`, which describe Ubuntu 18.04, PostgreSQL 10 and a 2.33 war
- [ ] 10.2 Switch prompts to `whiptail` once everything above is tested

## Later

- [ ] Turn Glowroot or Munin on or off for an existing instance (e.g. `dhis2-glowroot enable <instance>`): `-y` (restart), `--dry-run`
- [ ] Alerts when a remote backup fails (6.12)
- [ ] `setup.sh --answers` replay of a previous wizard run

## Decisions

All agreed decisions are in `architecture.md` (design sections and the decisions log, section 15).
