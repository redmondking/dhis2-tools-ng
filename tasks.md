# Tasks

Design and decisions are in `CLAUDE.md`. This file tracks the work.
Phases are roughly in order: each phase builds on the ones before it.

Status: `[ ]` todo, `[x]` done, `[~]` done but not tested on a real server.

## Phase 0 – Bug fixes (branch `fix/bugs`)

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
- [ ] 1.3 Fresh install from `fix/bugs`, then check each fix:
  - `-n`
  - `JAVA_HOME`
  - free-IP pick with a stopped container
  - `certbot renew --dry-run`
  - delete instance
  - restore database
  - `sysctl` values
  - `iptables -t nat -S`
  - rsyslog
- [ ] 1.4 Merge `fix/bugs` into `master` and push

## Phase 2 – Modernise the base

- [ ] 2.1 Proxy, postgres and monitor containers on Ubuntu 24.04 (`create_containers.sh`, `change_webserver.sh`)
- [ ] 2.2 `postgres` type: PostgreSQL 16 + `postgis-3` using a keyring. Delete `postgres12` and `postgres12_postsetup`
- [ ] 2.3 Replace `apt-key` with `/etc/apt/keyrings` + `signed-by` (postgres, nginx)
- [ ] 2.4 Tomcat per instance: `tomcat9` on 22.04 or `tomcat10` on 24.04, stored as `user.dhis2.tomcat`.
      Remove the hardcoded `tomcat9` from:
  - `etc/tomcat_setup`
  - `etc/tomcat_default`
  - `dhis2-create-instance`
  - `dhis2-deploy-war`
  - `dhis2-logview`
  - `dhis2-tomcat-munin`
- [ ] 2.5 Check that DHIS2 2.38 runs on PostgreSQL 16. If not, support a second postgres container on 14
- [ ] 2.6 Proxy configs:
  - remove OCSP stapling
  - `http2 on;`
  - drop `X-XSS-Protection`
- [ ] 2.7 Glowroot: one version setting instead of two hardcoded ones
- [ ] 2.8 `chown root.root` → `root:root`, `tomcat.tomcat` → `tomcat:tomcat`
- [ ] 2.9 Delete `setup/.DS_Store`, `configs/containers.json.exampleused`, `setup/destroy`
- [ ] 2.10 nginx is the only proxy for new installs: make `containers.json.sample` and the wizard default to nginx, with no apache choice
- [ ] 2.11 `upgrade_setup.sh`: on apache servers, offer to switch to nginx via `change_webserver.sh`.
      Delete apache support (`containers/apache_proxy*`, `configs/apache-dhis2.conf`, apache branches) once that switch is tested

## Phase 3 – Multiple DHIS2 versions

- [ ] 3.1 Shared helpers for the service scripts:
  - read the release feed
  - prompts with defaults (`ask`, `menu`, `confirm`)
  - read and write the `user.dhis2.*` labels
- [ ] 3.2 Version menu from the feed: versions ≥ 2.38, then the patch release (default: latest)
- [ ] 3.3 Choose Ubuntu, Tomcat and JDK from the version
- [ ] 3.4 Download the war, check its sha256, deploy it to `webapps/<path>`
- [ ] 3.5 Record `user.dhis2.version` and `user.dhis2.tomcat` on the container
- [ ] 3.6 `dhis2-deploy-war`: patch updates within the same version, with a sha256 check. For a different version, point to the upgrade script (phase 9)
- [ ] 3.7 `dhis2-list-instances`: name, address, version, status

## Phase 4 – Hostnames and paths

- [ ] 4.1 nginx layout with one server block per hostname. Existing upstream files keep working under the fqdn
- [ ] 4.2 Page at each hostname root that lists its instances, regenerated whenever instances change
- [ ] 4.3 DNS check for a new subdomain: on failure, explain what to check and offer to retry
- [ ] 4.4 Certificate per subdomain, with the auto-renewal prompt
- [ ] 4.5 `dhis2-create-instance` prompts:
  1. hostname (existing or new subdomain)
  2. path, validated
  3. container name [`<subdomain>-<path>`]

  Flags: `-H`, `-p`
- [ ] 4.6 Quote instance names in all SQL, since names can contain `-`
- [ ] 4.7 `dhis2-delete-instance`: remove the instance from its hostname. If it was the last one there, offer to remove the subdomain (never the fqdn)
- [ ] 4.8 `dhis2-move-instance <name> <hostname> [path]`
- [ ] 4.9 Glowroot at `/<path>-glowroot`

## Phase 5 – Interactive setup and instance creation

- [ ] 5.1 Setup wizard: asks FQDN, email, TZ, proxy, monitoring, APM, then writes `containers.json`
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
- [ ] 5.4 Memory for the instance (Java heap + container limit), default based on free RAM

## Phase 6 – Backups

- [ ] 6.1 Setup wizard asks for the backup settings, each with a default. They are written to `dhis2-env` and the cron job is enabled.
  - time
  - daily backups to keep (7)
  - weekly backups to keep (3, Sunday)
  - monthly backups to keep (12, the 1st)
  - backup directory
  - optional remote rsync target
- [ ] 6.2 `dhis2-backup`: delete old monthly backups, use each database's own container, quote names
- [ ] 6.3 `dhis2-create-instance`: "Back up this instance? [Y/n]" adds it to `PLAIN_BACKUPS`. `dhis2-delete-instance` removes it
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
- [ ] 7.2 Restore into the new database **before** DHIS2 first starts, deploying the war for that version (reuses `dhis2-restoredb -y`)
- [ ] 7.3 Skip the admin login step (5.3), since the backup brings its own users
- [ ] 7.4 Accept encrypted backups (`.sql.gz.enc`): ask for the password file [`PASSWORD_FILE` from `dhis2-env`]. `dhis2-restoredb` gets the same support
- [ ] 7.5 If a matching `<name>.files.tar.gz[.enc]` sits next to the database backup, offer to restore it into `/opt/dhis2/files` (owned by tomcat)

## Phase 8 – Bring existing servers forward (`upgrade_setup.sh`)

- [ ] 8.1 Label existing instances:
  - `hostname` = fqdn
  - `path` = container name
  - `version` = read from the deployed war
  - `tomcat` = `tomcat9`
- [ ] 8.2 Move proxy config to the per-hostname layout
- [ ] 8.3 `containers.json` type `postgres12` → `postgres`
- [ ] 8.4 Optional PostgreSQL 13 → 16 upgrade, with a checked backup first
- [ ] 8.5 Keep existing `dhis2-env` backup settings, only adding new keys
- [ ] 8.6 Move existing backups into the new layout: `backup<date>-<type>/<db>.sql.gz*` → `<db>/<date>-<type>/`.
      Tell the user the remote copy will receive the new layout, and that the old remote folders are left for them to remove.
- [ ] 8.7 Turn an old `REMOTE=` setting in `dhis2-env` into remote `remote1`, SSH type, mode `keep` (same behaviour as before)

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
- [ ] 9.2 Build `dhis2-upgrade-instance`

## Phase 10 – Docs and polish

- [ ] 10.1 Rewrite `README.md` and `docs/`, which describe Ubuntu 18.04, PostgreSQL 10 and a 2.33 war
- [ ] 10.2 Switch prompts to `whiptail` once everything above is tested

## Decisions from the open questions (2026-09-25)

- Host OS: Ubuntu 24.04 for new installs. `upgrade_setup.sh` also runs on existing 20.04/22.04 hosts.
- Proxy: **nginx only** (see 2.10, 2.11).
- The fork is the user's own project. Nothing is contributed back to `bobjolliffe/dhis2-tools-ng`. `upstream` stays as a remote, to pull fixes.
- One shared PostgreSQL 16 container (2.5 checks 2.38 on it).
- PostgreSQL 13 → 16 upgrade on existing servers: optional, with a checked backup (8.4).
- Memory per instance: asked, with a default based on free RAM (5.4).
- Munin and Glowroot: yes/no in the wizard, both defaulting to yes (5.1).
