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
- [ ] Guest OS 20.04 (EOL) → 22.04. 22.04 still ships `tomcat9` and openjdk 8/11/17.
      24.04 has **no tomcat9 package**, so moving to it means installing Tomcat from a tarball.
- [ ] PostgreSQL 13 (EOL Nov 2025) and `postgres12` → a single `postgres` type with PostgreSQL 16 and `postgis-3`.
      `postgresql-13-postgis-2.5` doesn't exist on 22.04 and newer.
- [ ] Replace `apt-key` with `/etc/apt/keyrings/*.asc` and `signed-by=`.
- [ ] Java choice: derive from the release feed instead of `-j 8|11|17` with default 11.
- [ ] Glowroot: stop hardcoding 0.13.6 and 0.14.2.
- [ ] Proxy: remove OCSP stapling (Let's Encrypt shut down OCSP in 2025), use `http2 on;` instead of `listen ... http2`, drop `X-XSS-Protection`.
- [ ] Docs: they still describe Ubuntu 18.04, PostgreSQL 10 and a 2.33 war URL.
- [ ] Remove `setup/.DS_Store`, `configs/containers.json.exampleused`, `setup/destroy`.
- [ ] Open question: does DHIS2 2.43 still run on Tomcat 9, or does it need Tomcat 10 (Jakarta)? Check before touching the Tomcat setup.

### 3. Multi-version support (see Goals)
### 4. Interactive prompts and setup wizard (see Goals)

## Conventions

- Keep scripts plain bash, matching the existing style (`lxc exec $NAME -- ...`, heredocs for config files).
- Quote variables in new or changed code.
- Keep every script usable non-interactively. Prompt only when an argument is missing and stdin is a TTY (`[[ -t 0 ]]`).
