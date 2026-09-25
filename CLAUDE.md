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
   - `dhis2-deploy-war` doubles as the upgrade path. It switches the JDK and `JAVA_HOME` when the new version needs a different one.
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
5. **Oldest DHIS2 version: 2.38** (user decision). 2.38–2.40 need Java 11 + Tomcat 9 (22.04 container).
   Offer only versions from the feed with `name >= 2.38`.
   - Database: one shared PostgreSQL 16 container. The DHIS2 docs require ≥9.6 for 2.38/2.39 and recommend 14,
     but say nothing about 16. **Test 2.38 on PG16.** If it fails, allow a second postgres container on 14 for old versions.
6. **Admin password.** After the first war deploy, once DHIS2 is up, ask for a new password for the default `admin` / `district`
   account, offering a generated strong password as the default.
7. **Backups.**
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
   - `dhis2-backup` hardcodes the `postgres` container. Use each database's own container once there can be more than one.
4. **Upgrade path for existing servers.** `setup/upgrade_setup.sh` repairs hosts installed with the
   old scripts. Every fix that changes installed state needs a matching step there.

## Servlet container per DHIS2 version

The official Ubuntu guide (docs.dhis2.org manual-install-on-ubuntu) and a check of the war files on 2026-09-25 agree:

| DHIS2 | Java | Servlet API | Tomcat | Ubuntu package |
|---|---|---|---|---|
| 2.42, 2.43 | 17 | jakarta (Spring 6) | 10.1+ | `tomcat10` on 24.04 |
| 2.41 and older | 17 / 11 / 8 | javax (Spring 5) | 9 | `tomcat9` exists only up to 22.04 |

Decision (user, 2026-09-25): proxy, postgres and monitor containers, and instances of DHIS2 2.42+, use Ubuntu **24.04** with `tomcat10`.
Instances of DHIS2 ≤2.41 use a **22.04** container with `tomcat9`, as the official DHIS2 guide does (22.04 standard support ends April 2027).

## Roadmap

### 1. Bug fixes (done on `fix/bugs`, not yet tested on a real host)
- [x] `service/dhis2-create-instance`: `if [ $CREATEDB ]` is always true, so `-n` is ignored.
- [x] `service/dhis2-create-instance` + `etc/tomcat_default`: the template has `{{ JAVA_VERSION }}` but sed replaces only `JAVA_VERSION`, giving `java-{{ 17 }}-...`. The non-glowroot branch substitutes nothing. The path hardcodes `amd64`.
- [x] `service/dhis2-create-instance`: free-IP detection uses gawk-only `strtonum`, but Ubuntu's default awk is mawk.
- [x] `ssl_setup.sh`: the renewal cron `lxc exec proxy -- echo ... > /etc/cron.d/certbot` writes to the **host**, with a stray trailing `/`. Renewal likely never works.
- [x] `service/dhis2-delete-instance`: requires 2 args despite a postgres default. The `/etc/hosts` sed uses undefined `$N`, so it deletes any line ending in a space. No confirmation before dropdb.
- [x] `service/dhis2-restoredb`: no argument validation, and `usage` is never called.
- [x] `configs/sysctl`: typo `max_user_watchesi`. `lxd_setup.sh` appends it on every run and never applies it (`sysctl --system`).
- [x] `create_containers.sh`: NAT network hardcoded to `192.168.0.0/24` (`# FIX THIS`).
- [x] `containers/rsyslog_logger*`: wrong subnet `192.168.25.0/24`, `sed '$ a'` lines missing a file argument, `apt upgrade` without `-y`.

### 2. Modernise
- [ ] Guest OS 20.04 (EOL) → 24.04, except DHIS2 ≤2.41 instances on 22.04 (see table above).
      Scripts hardcode `tomcat9` (service name, `/var/lib/tomcat9`, `/etc/default/tomcat9`), so these become per instance.
- [ ] PostgreSQL 13 (EOL Nov 2025) and `postgres12` → a single `postgres` type with PostgreSQL 16 and `postgis-3`.
      `postgresql-13-postgis-2.5` doesn't exist on 24.04.
- [ ] Replace `apt-key` with `/etc/apt/keyrings/*.asc` and `signed-by=`.
- [ ] Java choice: derive from the release feed instead of `-j 8|11|17` with default 11.
- [ ] Glowroot: stop hardcoding 0.13.6 and 0.14.2.
- [ ] Proxy: remove OCSP stapling (Let's Encrypt shut down OCSP in 2025), use `http2 on;` instead of `listen ... http2`, drop `X-XSS-Protection`.
- [ ] Docs: they still describe Ubuntu 18.04, PostgreSQL 10 and a 2.33 war URL.
- [ ] Remove `setup/.DS_Store`, `configs/containers.json.exampleused`, `setup/destroy`.
- [x] `ssl_setup.sh` asks whether to renew automatically (enables/disables certbot's systemd timer).
- [x] `setup/upgrade_setup.sh` for servers installed with the old scripts.

### 3. Multi-version support (see Goals)
### 4. Interactive prompts and setup wizard (see Goals)

## Conventions

- Keep scripts plain bash, matching the existing style (`lxc exec $NAME -- ...`, heredocs for config files).
- Quote variables in new or changed code.
- Keep every script usable non-interactively. Prompt only when an argument is missing and stdin is a TTY (`[[ -t 0 ]]`).
