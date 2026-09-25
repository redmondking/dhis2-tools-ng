# dhis2-tools-ng (redmondking fork)

Bash tooling to run DHIS2 on a single Ubuntu host using LXD containers:
one proxy (nginx or apache2), one postgres, optional munin monitor, and one
tomcat container per DHIS2 instance.

- `origin`: github.com/redmondking/dhis2-tools-ng
- `upstream`: github.com/bobjolliffe/dhis2-tools-ng (fork was level with it as of 2026-09-25)

## Layout

- `setup/lxd_setup.sh` – host bootstrap: installs LXD, then runs `install_scripts.sh` and `create_containers.sh`
- `setup/parse_config.sh` – reads `/usr/local/etc/dhis/containers.json` into shell variables
- `setup/containers/<type>` – script piped into a new container; `<type>_postsetup` is then sourced on the host
- `setup/service/dhis2-*` – admin commands, copied to `/usr/local/bin`
- `setup/etc/*` – templates copied to `/usr/local/etc/dhis` (never overwritten on re-install)
- `setup/configs/*` – LXD preseed, sysctl, proxy/postgres configs, `containers.json.sample`

Scripts must run on the Ubuntu host as root with `lxc`, `jq` and `ufw` available.
Nothing here runs on macOS, so check syntax locally with `bash -n` and `shellcheck`.

## Goals

1. **Multiple DHIS2 versions.** Get version metadata from the release feed
   `https://releases.dhis2.org/v1/versions/stable.json`. Each entry gives
   `name`, `supported`, `jdk`, `latestStableUrl`, `sha256`, `patchVersions`.
   - Instance creation shows supported versions as a menu, installs the JDK the feed lists, downloads the war and checks its sha256.
   - Record the version on the container with `lxc config set <name> user.dhis2.version`.
   - `dhis2-deploy-war` handles patch updates within a version (2.41.9 → 2.41.10). Changing version is the upgrade script's job (goal 9).
   - Add a small `dhis2-list-instances` showing name, version, Java, IP and status.
   - JDK per version, from the feed on 2026-09-25: 2.41–2.43 → 17, 2.38–2.40 → 11, 2.37 → 8.
2. **Interactive.** Use plain bash for now (`read -p`, `select`).
   Move to `whiptail` only once the plain-bash version is fully tested.
   - `setup.sh` wizard asks for FQDN, email, TZ, proxy and monitoring, then writes `containers.json`.
   - A service script run without its args prompts for them with defaults (the only postgres container, the next free IP).
   - Destructive commands (delete instance, restore db) always ask for confirmation.
   - Existing flags and args keep working without prompts, so cron and scripted use still work.
3. **Hostnames and paths** (final design agreed with user 2026-09-25, not built).
   An instance's address is `https://<hostname>/<path>`. The container name is separate.
   - Hostnames: the `fqdn` from `containers.json`, plus any number of **subdomains of the fqdn only**.
   - Path: unique **within a hostname**, so `hmis.example.com/hmis` and `hmis2.example.com/hmis` can both exist.
     Allowed characters: `[a-z0-9_-]`. `/munin` is reserved on the fqdn, and so is `/<other path>-glowroot`. No instance at the root `/`.
   - Container name defaults to `<subdomain>-<path>` (`hmis2.example.com/hmis` → `hmis2-hmis`), and the user can override it.
     It is also the database name and role, so scripts must quote it in SQL (`-` is not valid unquoted).
   - Stored on the container: `user.dhis2.hostname`, `user.dhis2.path`.
   - Tomcat context = path (war unzipped to `webapps/<path>`), so the proxy never rewrites paths. Glowroot is at `/<path>-glowroot`.
   - `dhis2-create-instance` prompts:
     1. Pick a hostname (the menu shows each hostname's paths) or enter a new subdomain.
     2. Path.
     3. Container name [generated].
     Non-interactive: `-H <hostname> -p <path> [name]`.
   - New subdomain: check that DNS resolves to this server. On failure, stop, explain what to check, and offer to retry.
     Then create its nginx server block / apache VirtualHost and its own certificate, asking about auto-renewal.
   - The hostname root (`https://<hostname>/`) always shows a list of links to its instances.
   - Deleting the last instance on a subdomain asks whether to remove the subdomain's proxy config and certificate. Never removes the fqdn.
   - `dhis2-move-instance <name> <hostname> [path]` moves an instance to another hostname and/or path.
   - `dhis2-list-instances` shows name, address, version, status.
   - Existing instances: the upgrade script labels them hostname=fqdn, path=container name. No renames.
4. **Oldest DHIS2 version: 2.38** (user decision). 2.38–2.40 need Java 11 + Tomcat 9 (22.04 container).
   Offer only versions from the feed with `name >= 2.38`.
   - Database: one shared PostgreSQL 16 container. The DHIS2 docs require ≥9.6 for 2.38/2.39 and recommend 14,
     but say nothing about 16. **Test 2.38 on PG16.** If it fails, allow a second postgres container on 14 for old versions.
5. **Admin login.** `dhis2-create-instance` asks for the admin username [`admin`] and password [`district`].
   - Pressing Enter keeps DHIS2's defaults.
   - The change-credentials step runs only if either value differs from the default: wait for DHIS2 to be up, then change it via the API.
   - Keeping the defaults prints a warning, since `admin`/`district` is publicly known.
   - Skipped when the instance was created from a backup, which brings its own users.
6. **Backups.**
   - The install/setup wizard asks for the backup settings, each with a default:
     - time of the nightly run (`/etc/cron.d/dhis`)
     - daily backups to keep (7)
     - weekly backups to keep (3, taken on Sunday)
     - monthly backups to keep (12, taken on the 1st; monthly deletion is new, it was never implemented)
     - backup dir (`/var/pgbackups`)
     - optional remote rsync target
     These are written to `/usr/local/etc/dhis/dhis2-env` and the cron job is enabled.
   - `dhis2-create-instance` asks "Back up this instance? [Y/n]" and adds its database to `PLAIN_BACKUPS`.
     `dhis2-delete-instance` removes it.
   - Layout: grouped by instance, then by date: `BACKUP_DIR/<instance>/<date>-<daily|weekly|monthly>/` holding
     `<instance>.sql.gz[.enc]` and `<instance>.files.tar.gz[.enc]`.
   - `dhis2-backup` also archives each instance's `/opt/dhis2/files` (the DHIS2 file store, which is not in the database dump),
     encrypted when its database is.
   - `dhis2-backup` hardcodes the `postgres` container. Use each database's own container once there can be more than one.
7. **Upgrade path for existing servers.** `setup/upgrade_setup.sh` repairs hosts installed with the
   old scripts. Every fix that changes installed state needs a matching step there.
8. **Create an instance from a backup.** `dhis2-create-instance` asks whether there is a backup to restore, and which DHIS2 version it is from.
   - It restores the backup before DHIS2 first starts, then deploys that version's war.
   - Versions older than 2.38 are refused.
   - Accepts encrypted backups (asks for the password file), and restores the matching file-store archive if one is present.
9. **DHIS2 version upgrade script** (`dhis2-upgrade-instance`). To be built **last**, because it has many variables (see tasks.md phase 9).
   In particular, 2.41 → 2.42 moves from a Tomcat 9 / 22.04 container to a Tomcat 10 / 24.04 one.

## Servlet container per DHIS2 version

The official Ubuntu guide (docs.dhis2.org manual-install-on-ubuntu) and a check of the war files on 2026-09-25 agree:

| DHIS2 | Java | Servlet API | Tomcat | Ubuntu package |
|---|---|---|---|---|
| 2.42, 2.43 | 17 | jakarta (Spring 6) | 10.1+ | `tomcat10` on 24.04 |
| 2.41 and older | 17 / 11 / 8 | javax (Spring 5) | 9 | `tomcat9` exists only up to 22.04 |

Decision (user, 2026-09-25): proxy, postgres and monitor containers, and instances of DHIS2 2.42+, use Ubuntu **24.04** with `tomcat10`.
Instances of DHIS2 ≤2.41 use a **22.04** container with `tomcat9`, as the official DHIS2 guide does (22.04 standard support ends April 2027).

## Tasks

Tracked in `tasks.md`, which also lists the open questions. Update it as work is done: `[~]` means done but not tested on a real server.

## Conventions

- Keep scripts plain bash, matching the existing style (`lxc exec $NAME -- ...`, heredocs for config files).
- Quote variables in new or changed code.
- Keep every script usable non-interactively. Prompt only when an argument is missing and stdin is a TTY (`[[ -t 0 ]]`).
