# Architecture

The design of dhis2-tools-ng (redmondking fork): what the tools do, how they are laid out, and the decisions behind them.
Work and status are tracked in `tasks.md`. `[built]` / `[planned]` mark whether a part exists yet (built parts are not yet
tested on a real server; see `tasks.md`).

## 1. Overview

Bash tools that run DHIS2 on one Ubuntu server, with each part in its own LXD container:

```
Ubuntu 24.04 host (LXD, ufw; ports 80/443 forwarded to the proxy)
├── proxy       nginx + certbot: https for the fqdn (and subdomains, phase 4), routes to instances
├── postgres    PostgreSQL 16 + PostGIS, one database per instance
├── monitor     Munin (optional): graphs for the host and every container
├── hmis        one container per DHIS2 instance: Tomcat 9 or 10, DHIS2, optional Glowroot agent
└── training    ...
```

Admins use `dhis2-*` commands on the host. Later a Nuxt management app and Ansible will drive the same commands (section 13).

## 2. Layout

**Repo**
- `install.sh`: installs or updates the tools from GitHub
- `setup/lxd_setup.sh` (`dhis2-setup`): host bootstrap (LXD, sysctl, ufw), then `install_scripts.sh` and `create_containers.sh`
- `setup/ssl_setup.sh` (`dhis2-ssl-setup`), `setup/upgrade_setup.sh` (`dhis2-upgrade-setup`)
- `setup/parse_config.sh`: reads `/usr/local/etc/dhis/containers.json` into shell variables
- `setup/containers/<type>`: script piped into a new container; `<type>_postsetup` is then sourced on the host
- `setup/service/dhis2-*`: admin commands
- `setup/lib/dhis2-lib.sh`: shared helpers (prompts, release feed, war download/deploy, Glowroot logins, ...)
- `setup/etc/*`: templates copied once to `/usr/local/etc/dhis` (never overwritten; they may hold local edits)
- `setup/configs/*`: LXD preseed, sysctl, proxy/postgres configs, `containers.json.sample`

**On a server**
- `/opt/dhis2-tools/`: the repo's `setup/` + `install.sh` + `VERSION` (commit sha, install date). Replaced by every update;
  the previous version is kept in `/opt/dhis2-tools.old`.
- `/usr/local/bin/dhis2-*`: symlinks into `/opt/dhis2-tools`: `dhis2-setup`, `dhis2-ssl-setup`, `dhis2-upgrade-setup`,
  `dhis2-tools-update`, plus every `service/*` script under its own name. Internal scripts get no link;
  `delete_all.sh` (deletes every container) deliberately gets none.
- `/usr/local/etc/dhis/`: this server's settings (`containers.json`, `dhis2-env`, templates, `glowroot-login`). Updates never replace them.
- Entry scripts `cd "$(dirname "$(readlink -f "$0")")"`, so their relative paths work from any directory.

## 3. Install and update  [built; wizard planned]

- First install: `curl -fsSL https://raw.githubusercontent.com/redmondking/dhis2-tools-ng/master/install.sh | sudo bash`.
- `dhis2-tools-update` (= `install.sh`) updates from a **hardcoded** repo, `redmondking/dhis2-tools-ng`, branch `master`
  (not from a local git checkout):
  - the latest commit comes from the GitHub API; the tarball of that commit is unpacked into `/opt/dhis2-tools.new`, then swapped in
  - `--check` reports only (exit 2 = update available), `-y`, `--rollback` (swap back one version)
  - after installing, it runs `dhis2-upgrade-setup` to apply migrations
  - testing overrides only: `DHIS2_TOOLS_BRANCH` (e.g. `develop`), `DHIS2_TOOLS_DEST`, `DHIS2_TOOLS_BIN`
- Setting up the server:
  - now: `sudo dhis2-setup [containers.json]` (the config file must exist, or be given)
  - phase 5: `setup.sh` wizard for people (plain bash prompts; `whiptail` only once everything is tested), and
    `setup.sh --config <file|->` for automation, in the same JSON format the wizard writes, asking nothing.
    Secrets may be in that input and are stripped before `/usr/local/etc/dhis/containers.json` is saved.
    `configs/containers.json.sample` is the documented example of the format, kept in sync with the wizard.
    Ansible example: template the JSON (secrets from Ansible Vault) to a root-only file, run `setup.sh --config` on it, then delete it.
  - later, maybe: the wizard saves its answers (no passwords) so `setup.sh --answers <file>` can replay them.

## 4. Containers and packages  [built]

- The proxy, postgres and monitor containers run Ubuntu **24.04**. Instance containers depend on the DHIS2 version (section 5).
- Only Ubuntu's own packages, no third-party apt repositories or snaps in containers:
  `postgresql-16` + `postgresql-16-postgis-3`, `nginx` (1.24), `certbot` (apt).
- nginx 1.24 has no `http2 on;`, so the proxy keeps `listen 443 ssl http2;`. No OCSP stapling (Let's Encrypt ended OCSP in 2025).
- **nginx is the only proxy.** Older servers with apache keep working; phase 8 offers to switch them to nginx, and apache
  support is deleted once that is tested.
- One shared PostgreSQL 16 container for all instances. The DHIS2 docs require ≥9.6 for 2.38/2.39 and recommend 14, but say
  nothing about 16, so 2.38 on 16 is on the test list. If it fails, a second postgres container on 14 for old versions.
- Certificates (agreed 2026-09-27, nginx): certbot in **webroot** mode, from the apt `certbot` package; no nginx plugin, no standalone.
  Apache servers keep standalone with stop/start hooks until phase 8 moves them to nginx.
  - The proxy serves `/.well-known/acme-challenge/` from `/var/www/letsencrypt` (`configs/nginx-acme-challenge.conf`, installed as
    `/etc/nginx/snippets/acme-challenge.conf` and included in every port-80 server block; the http→https redirect uses
    `location / { return 301 … }` so the check isn't redirected); certbot writes its check file there, so the
    proxy **never stops**, neither when a certificate is issued nor at renewals.
  - A deploy hook reloads the proxy after a renewal, so it picks up the new certificate without interrupting anyone.
  - `dhis2-ssl-setup` gets the certificate first. Only when certbot succeeded and the certificate files exist does it write
    the https config; it then **tests** it (`nginx -t` / `apache2ctl -t`) and reloads. A failed test puts the old config back.
    On any failure the site stays up on http, unchanged, and the command exits 1.
  - Renewal: certbot's own systemd timer. `dhis2-ssl-setup` asks whether to renew automatically (`--renew`, default yes).
  - Existing servers: `dhis2-upgrade-setup` adds the challenge location and moves existing certificates from standalone
    (stop/start hooks) to webroot (reload hook).
  - **Failure handling** (agreed 2026-09-27, built in phase 4 as shared helpers used by every hostname's certificate):
    1. Checks before the real request: an automatic staging test first (the real request only if it passes); DNS points
       at this server; a stray AAAA record the server can't answer on; a CAA record that excludes Let's Encrypt; the proxy
       serves a test file from the challenge folder; port 80 reaches the proxy (host `ufw` and NAT).
    2. Plain reasons for certbot's common errors (NXDOMAIN, connection timeout, answered by another server, rate limited
       with the retry time), plus the path of certbot's log for anything else.
    3. Retries: after 3 failed real attempts within an hour, refuse (with the retry time) unless `--force`; `--wait-dns`
       re-checks every minute, up to a limit, until the domain points here.
    4. Renewal failures: `dhis2-ssl-status` (`--json`) shows each certificate's expiry, last renewal attempt and result, and
       warns under 14 days; the warning also shows where people already look (e.g. `dhis2-list-instances`).
    5. `dhis2-ssl-setup --json`: success, the failed stage (dns, ipv6, caa, proxy, letsencrypt, config-test), the reason and
       the retry time.
- Existing servers keep their containers (20.04, PostgreSQL 13) until phase 8, which moves them to 24.04 and PostgreSQL 16
  in one step, optionally, with a checked backup first.

## 5. DHIS2 versions  [built]

**Release feed**: `https://releases.dhis2.org/v1/versions/stable.json`. Every release has a full `name` (`2.42.0`,
`2.42.5.2` for a hotfix), `url`, `sha256`, `hotfix`, `fileSize`; every version line has `jdk` and `supported`.

- Only **2.38 and newer** are offered.
- The list shows every release, including hotfixes, one row per version, marked supported or end of support.
- The user types the **exact** release name: `2.42` is refused, `2.42.0` is accepted. Non-interactive: `-V <release>`.
- Every war is checked against the published sha256 before use; on a mismatch the user can try again, choose another
  release, or stop. There is never a "deploy anyway". A deployed war's release is in `WEB-INF/lib/dhis-api-<release>.jar`.

**Servlet container per version** (official Ubuntu install guide + a check of the war files, 2026-09-25):

| DHIS2 | Servlet API | Tomcat | Instance container | Java (from the feed) |
|---|---|---|---|---|
| 2.42, 2.43 | jakarta (Spring 6) | 10.1 | Ubuntu 24.04, `tomcat10` | 17 |
| 2.41 | javax (Spring 5) | 9 | Ubuntu 22.04, `tomcat9` | 17 |
| 2.38–2.40 | javax (Spring 5) | 9 | Ubuntu 22.04, `tomcat9` | 11 |

Ubuntu ships `tomcat9` only up to 22.04, whose standard support ends April 2027.
The release decides Ubuntu, Tomcat and Java; there is no `-j`.

**Commands**
- `dhis2-create-instance`: asks first whether to create and deploy DHIS2, or create only (`--no-deploy`). Then where DHIS2
  comes from: 1) an official release (`-V`) 2) own war file on the server (`-f`) 3) own war at a URL (`-l`).
  The war is downloaded and checked **before** anything is created.
  - Create only still needs the version line, which decides Ubuntu/Tomcat/Java: "Which DHIS2 version will it run?"
    (`--line 2.42`). `dhis2-deploy-war` then offers only releases from that line.
- `dhis2-deploy-war`: the same source menu; for official releases it lists only the instance's own version line, with the
  current release marked.
  - Another major version (2.41 → 2.42) is always refused, and so is a release needing a different Tomcat.
  - Going back within a line (2.42.5 → 2.42.3) is refused unless `--force`; then a warning (releases can change the database;
    restoring a backup from that release is the safe way) must be acknowledged by typing the instance name, or `--force -y`
    without a terminal.
- Own wars (`-f`/`-l`): no published checksum (optional `--sha256`). Their release is read from `dhis-api-*.jar` and gets the
  same checks. If it can't be read, the user says which version it is based on (`--based-on 2.41`) and the version is
  recorded as `custom`. Label `user.dhis2.source` = `official` or `custom`.
- `dhis2-upgrade-instance` [planned, phase 9, last]: moving an instance to another major version. 2.41 → 2.42 needs a new
  container (Tomcat 9 / 22.04 → Tomcat 10 / 24.04), carrying over `dhis.conf`, `/opt/dhis2` (file store), Glowroot, IP,
  proxy entry and labels. Backup first, rollback plan, migrations followed in the log, health check after start.

## 6. Instance labels

All state about an instance lives on its container:

| Label | Values | Set by |
|---|---|---|
| `user.type` | `Tomcat server` (marks a DHIS2 instance) | create-instance |
| `user.dhis2.version` | exact release, `none`, or `custom` | create-instance, deploy-war |
| `user.dhis2.tomcat` | `tomcat9` / `tomcat10` (missing = `tomcat9`) | create-instance |
| `user.dhis2.java` | `11`, `17`, ... | create-instance |
| `user.dhis2.source` | `official` / `custom` / `none` (created without DHIS2) | create-instance, deploy-war |
| `user.dhis2.line` | the DHIS2 version line, e.g. `2.42` (so create-only instances know which releases fit) | create-instance, deploy-war |
| `user.dhis2.glowroot` | `shared` / `own` / `off` | create-instance, `dhis2-glowroot-login` |
| `user.dhis2.glowroot.user` | the Glowroot username managed by the tools | same |
| `user.dhis2.munin` | `yes` / `no` | create-instance |
| `user.dhis2.backup` | `plain` / `encrypted` / `no` | [planned, phase 6] create-instance |
| `user.dhis2.postgres` | the postgres container holding its database | [planned, phase 6] create-instance |
| `user.dhis2.hostname`, `user.dhis2.path` | [planned, phase 4] | `dhis2-instance create` / `edit` |
| `user.dhis2.description` | shown on the hostname's list page, e.g. `Production` [planned, phase 4] | `dhis2-instance create` / `edit` |

Instances made by older versions are labelled by `dhis2-upgrade-setup` (version from the deployed war's `dhis-api-*.jar`).
`dhis2-list-instances` [built] shows them: name, version, URL, Tomcat, Java, IP, status, Glowroot, Munin; `--json`.

## 7. Hostnames and paths  [planned, phase 4; design agreed 2026-09-25]

An instance's address is `https://<hostname>/<path>`. The container name is separate.

- Hostnames (changed 2026-09-27, phase 4 section A): **any hostname is allowed, as long as its DNS points at this server**
  (the DNS check when adding a hostname is the guard; a typo fails it). There is no list of allowed base domains, and the earlier
  rule "subdomains of the fqdn only" is dropped. Example on one server: `dhis2.example.com/prod`, `dhis2.example.com/test`,
  `hmis.example.com/prod`, `hmis.example.com/test`.
- `fqdn` in `containers.json` is renamed **`default_hostname`**: the hostname offered first for new instances, and Munin's
  default home. `dhis2-upgrade-setup` renames the key on existing servers; until then the scripts still read `fqdn`.
- Certificate email (agreed 2026-09-27): the server-wide `email` is the default. Adding a hostname asks
  `Email for its certificate [<default email>]` (`--email` for automation). A different email needs its own Let's Encrypt
  account (certbot only uses `-m` when it registers the account; later runs reuse it), so the tools register one per email
  (`certbot register`), remember which account belongs to which email, and request that hostname's certificate with
  `--account <id>`; certbot records the account in the renewal settings. How exactly is settled in the phase 4 plan.
- **Munin's address** (agreed 2026-09-27, phase 4 section A): a setting, `munin_hostname` in `containers.json`, defaulting to
  `default_hostname`, with Munin at `https://<munin_hostname>/munin`. It can be a hostname of its own (e.g. `monitor.example.com`, with
  its own certificate) so server-wide monitoring doesn't sit on one organisation's domain, and it can be moved later with a
  small command. `/munin` is reserved only on that hostname. Existing servers keep Munin at `<fqdn>/munin`.
- `default_hostname` can be any full hostname, including a subdomain (e.g. `hivtracker.example.com`).
- Path: unique **within a hostname**, so `hmis.example.com/hmis` and `hmis2.example.com/hmis` can both exist.
  Paths (agreed 2026-09-27, phase 4 section B): lowercase letters, digits and `-` only, 1–40 characters, not starting or ending
  with `-` (no `_`: container names can't hold it). Uppercase is refused, not changed. Hostnames are stored in lowercase.
  `/munin` is reserved on Munin's hostname (see below), and so is `/<other path>-glowroot`. No instance *at* `/`.
- The container name is also the database name and role, so scripts must quote it in SQL (`-` is not valid unquoted).
- Tomcat context = path (war unzipped to `webapps/<path>`), so the proxy never rewrites paths. Glowroot at `/<path>-glowroot`.
- `dhis2-create-instance` asks: 1) hostname (existing, each shown with its paths, or a new subdomain) 2) path 3) container name.
  Flags `-H <hostname>`, `-p <path>`, both required with `-y`.
- New subdomain: check that DNS resolves to this server; on failure stop, explain what to check, and offer to retry
  (without a terminal: exit 1). Then its own nginx server block and certificate, asking about auto-renewal.
- The hostname root (`https://<hostname>/`), chosen per hostname (agreed 2026-09-27, phase 4 section B): **a list of links to
  its instances**, or **a redirect to one of its instances** (`https://<hostname>/` → `/<path>/`; the instance stays at its
  path, so Tomcat and DHIS2 don't change). Changeable later with a command (section C).
  - When the root's instance is deleted or moved away (agreed 2026-09-27): **ask** what the root shows afterwards, listing the
    list page and every other instance on that hostname (default: the list). `--root list|<instance>` for automation; without
    it, the list.
  - Menus of instances show only that hostname's instances, numbered, and accept either the number or the path.
  - Asked **when an instance is created** on the hostname (a hostname has no instances before that):
    - first instance: "What should https://<hostname>/ show? 1) This instance 2) A list of its instances" (default 1)
    - later instances: "https://<hostname>/ currently opens /<path> (…) / shows a list. 1) Keep that 2) Open this new instance
      instead 3) Show a list" (default: keep)
  - Automation: `--root this|list|keep`; without it: `this` for the first instance on a hostname, `keep` after that.
- Container names (agreed 2026-09-27, phase 4 section B): **a short name per hostname + the path**, e.g. `moh-prod`, `ngo-test`.
  - The short name is asked once, **when the hostname is created** (`dhis2-hostname add`, or "a new hostname" while creating an
    instance, which runs the same steps): "Short name for it, used in instance names [<first part of the hostname>]".
    It must be unique on the server, so instance names can't clash.
  - The suggested container name is `<short name>-<path>`; the user can type another (`--name` for automation).
  - Existing servers: `default_hostname` gets a short name (its first part); existing instances keep their names.
- Deleting the last instance on a subdomain asks whether to remove the subdomain's proxy config and certificate
  (`--remove-hostname yes|no`). The fqdn is never removed.
- **`dhis2-instance`** (agreed 2026-09-27, built in phase 4): one command for everything done *to* an instance, like
  `dhis2-hostname`, replacing `dhis2-create-instance`, `dhis2-delete-instance`, `dhis2-deploy-war`, `dhis2-list-instances` and
  the planned move/describe commands:
  - `create`, `delete`, `edit` (hostname, path, description; later Glowroot/Munin on or off), `deploy`, `list`
  - a small dispatcher; each action stays in its own file (`setup/service/instance/<action>`), so no single huge script
  - shared options (`-y`, `--dry-run`, `--json`, `--json-stream`, `--detach`) handled once
  - **no links under the old names** (the tools haven't been launched, so nothing depends on them). Existing servers still
    have copies of the original scripts in `/usr/local/bin`: `dhis2-upgrade-setup` moves those retired names aside
    (`/usr/local/etc/dhis/old-scripts`) and prints the new commands, so no stale original can be run by mistake.
  - Logs, monitoring and backups stay separate commands.
- Moving an instance to another hostname and/or path: `dhis2-instance edit <name> --hostname <h> [--path <p>]`.
- **Proxy layout** (agreed 2026-09-27, phase 4 section C):
  - Each hostname has a settings file on the host, `/usr/local/etc/dhis/hostnames/<hostname>.json` (short name, certificate
    email/account, what the root shows). With the instances' labels (hostname, path, description) that is everything needed
    to build the proxy config.
  - One helper builds a hostname's nginx config from those settings. Every change updates the settings, rebuilds that
    hostname's config, runs `nginx -t` and reloads, putting the old config back if the test fails. `dhis2-hostname rebuild`
    rebuilds from the settings for repairs.
  - Files in the proxy: `/etc/nginx/sites/<hostname>.conf` (its server blocks), `/etc/nginx/upstream/<hostname>/<path>.conf`
    (one location per instance), `/var/www/hostnames/<hostname>/index.html` (the list page, when the root shows a list).
  - Before its certificate a hostname is served over http on port 80 (with Let's Encrypt's check); after it, https on 443
    and port 80 redirects to it (except the check). Munin's location is only in Munin's hostname.
  - The list page: the hostname as title and a link per instance (`/prod`) with its **description** (e.g. "Production"),
    no DHIS2 versions or other details (the page is public). Descriptions are HTML-escaped. The description is a label on
    the instance (`user.dhis2.description`), asked when it is created (`--description`, optional), and changed later with
    `dhis2-instance edit <instance> --description "<text>"` (`--clear-description`), which rebuilds that hostname's list page.
  - The root redirect is temporary (302), so a change takes effect at once for everyone.
- **`dhis2-hostname`** (agreed 2026-09-27), with the usual `-y`, `--dry-run`, `-h`:
  - `add <hostname>`: DNS check (retry), short name, certificate email, certificate (section D), nginx config; root starts as the
    (empty) list
  - `list [<hostname>] [--json]`: short name, instances, what the root shows, certificate status and expiry, email
  - `set-root <hostname>`: menu of the list page and that hostname's instances (number or path), summary, confirm;
    `--list` / `--instance <name>` for automation; takes effect at once (nginx reload, 302 redirect)
  - `set-munin <hostname>`: move the Munin pages
  - `remove <hostname>`: refused while an instance uses it; removes its nginx config and settings, asks about its certificate;
    never the default hostname
  - `rebuild [<hostname>]`: regenerate nginx config from the saved settings, tested with `nginx -t`, rolled back on failure
  - not included (for now): changing a hostname's short name or certificate email; renaming a hostname (add + move + remove)
- Existing instances are labelled hostname = fqdn, path = container name. No renames.

## 8. Monitoring  [built]

Background: the original setup gave Glowroot's `anonymous` user the Administrator role, and every
`https://<fqdn>/<instance>-glowroot` was public, exposing SQL, thread dumps and heap dumps. `/munin` was public too.

- **Munin**: optional (asked in the wizard).
  - No: no `monitor` container and no munin-node anywhere.
  - Yes: `monitor` container; the host, proxy and postgres are monitored; each instance asks "Monitor with Munin?" (`-m`).
  - Login: nginx basic auth on `/munin`, one server-wide login; the SHA-512 hash (`openssl passwd -6`) lives on the proxy.
    `/munin` stays closed until a login is set. Change it with `dhis2-munin-login`.
- **Glowroot**: a Java agent inside each instance's Tomcat (port 4000, published as `/<path>-glowroot`), not a container.
  One version (0.14.7) for every Java version. Optional per instance (`-g`), default from the wizard (`apm` in `containers.json`).
  - Glowroot's **own** login: `admin.json` users with `passwordHash` = PBKDF2-HMAC-SHA1, 16-byte key, 16-byte salt,
    500000 iterations, formatted `b64(hash):b64(salt):500000` (unpadded base64; the count must be exactly 500000; checked
    against Glowroot's own code). Made with host `python3`, the password on stdin. No `anonymous` user.
  - Login mode (`glowroot_login` in `containers.json`): **shared** (one login for all instances; hash in
    `/usr/local/etc/dhis/glowroot-login`, root only) or **own** (asked per instance).
  - Users added in Glowroot's own screens are kept; only the login managed by the tools is replaced.
  - `dhis2-glowroot-login [instance]`: no instance changes the shared login everywhere; with one, sets its own login.
    Glowroot reads `admin.json` only at startup, so it asks before restarting (`--restart yes|no`; with `-y`: yes).
  - Glowroot on Tomcat 10 (2.42+, Jakarta) is on the test list; if it doesn't work, it is turned off for 2.42+.
- Munin and Glowroot logins are always separate. Passwords are typed by the user (twice); no defaults, nothing generated.
- Later: turning Glowroot or Munin on or off for an existing instance.

## 9. DHIS2 admin login  [planned, phase 5]

- `dhis2-create-instance` asks for the admin username [`admin`] and password [`district`]; Enter keeps DHIS2's defaults.
- Only if either differs: wait for DHIS2 to be up, then change it through the API.
- Keeping the defaults prints a warning, since `admin`/`district` is publicly known.
- Skipped when the instance was restored from a backup (it brings its own users).
- Automation: `--dhis2-user`, and `dhis2_password` in `--secrets-stdin`.

## 10. Backups  [planned, phase 6; bug fixes built]

- **Where `dhis2-backup` gets its information** (agreed 2026-09-26):
  1. `/usr/local/etc/dhis/dhis2-env`: **how**, the same for the whole server: `BACKUP_DIR`, `DAYS_TO_KEEP`,
     `WEEKS_TO_KEEP`, `DAY_OF_WEEK_TO_KEEP`, `MONTHS_TO_KEEP` (new), `CIPHER`, `PASSWORD_FILE`, `EXCLUDED`.
  2. Labels on each instance container: **what**. `user.dhis2.backup` = `plain` / `encrypted` / `no`, and
     `user.dhis2.postgres` = the postgres container holding its database. The instance name is the database name; the instance
     container holds `/opt/dhis2/files`. One `lxc list` call reads them all.
  3. `/usr/local/etc/dhis/remotes/<name>`: **where to send copies** after the local run.
  - Legacy: databases still named in `PLAIN_BACKUPS` / `ENCRYPTED_BACKUPS` in `dhis2-env` that have **no** instance container
    are still dumped (database only, from `postgres`), so nothing backed up today silently stops.
  - Not in `dhis2-env`: which instances are backed up (labels), the remotes (own files), the time of the run (`/etc/cron.d/dhis`).
  - Other readers of `dhis2-env`: `dhis2-list-backups` (`BACKUP_DIR`), restore (`BACKUP_DIR`, `PASSWORD_FILE`),
    `dhis2-backup-remote add` (`PASSWORD_FILE`, for the unencrypted-instances warning). The wizard / `setup.sh --config` write it.
- Settings asked in the wizard, each with a default, written to `dhis2-env`, cron enabled:
  time of the nightly run, daily backups to keep (7), weekly (3, Sundays), monthly (12, on the 1st), backup dir
  (`/var/pgbackups`).
- `dhis2-create-instance` asks "Back up this instance? [Y/n]" (`--backup yes|no`; encrypted or plain) and sets the labels.
  Deleting an instance drops its database; its label goes with the container, and its existing backups are kept.
- A stopped instance: its database is still dumped (postgres runs separately); if its file store can't be archived, the run
  reports that as skipped (to confirm when planning phase 6).
- Layout, grouped by instance, then by date:
  ```
  /var/pgbackups/<instance>/<date>-<daily|weekly|monthly>/<instance>.sql.gz[.enc]
                                                         /<instance>.files.tar.gz[.enc]
  ```
  `*.files.tar.gz` is the instance's `/opt/dhis2/files` (the DHIS2 file store, not in the database dump), encrypted when its
  database is. Retention applies inside each instance's folder.
- `dhis2-backup` uses each database's own postgres container, exits non-zero when anything failed, `--dry-run`, `--json`.
- `dhis2-list-backups [instance] [--json]`: instance, date, type, size, file store yes/no, encrypted yes/no.
- **Remote copies**: `dhis2-backup-remote add|list|test|sync|remove`, any number of remotes (`/usr/local/etc/dhis/remotes/<name>`).
  - Types: SSH server (`rsync`, one key per remote, `ssh-copy-id` offered) or cloud storage (`rclone`: S3, Backblaze B2,
    Google Drive, Azure, ...).
  - Mode per remote: `keep` (default, never delete on the remote) or `mirror`.
  - Adding a cloud remote while some instances are backed up unencrypted: warn, offer to encrypt them, remind to keep the
    password file off the server.
  - A failed remote doesn't stop the others; results are logged and shown by `list`.
  - Without a terminal the SSH key can't be installed (it needs the remote password): `--install-key no` prints the public key
    for the caller to add. Cloud credentials come in `--secrets-stdin`.
  - No fetch from remotes. Failure alerts (e.g. email) come later.
- Existing servers (`dhis2-upgrade-setup`):
  - instances named in `PLAIN_BACKUPS` / `ENCRYPTED_BACKUPS` get `user.dhis2.backup` = `plain` / `encrypted` and are removed
    from the lists; names with no instance container stay in the lists (legacy)
  - every instance gets `user.dhis2.postgres`, read from `connection.url` in its `/opt/dhis2/dhis.conf`
    (`jdbc:postgresql://<container>/<db>`); other instances get `user.dhis2.backup` = `no`
  - `MONTHS_TO_KEEP` is added to `dhis2-env` if missing; existing values are kept
  - old backups are moved into the new layout; an old `REMOTE=` becomes remote `remote1` in `keep` mode

## 11. Create an instance from a backup  [planned, phase 7]

- `dhis2-create-instance` asks "Restore from a backup?": a menu of backups found in `BACKUP_DIR` (from `dhis2-list-backups`),
  or another file path; then which DHIS2 release the backup is from (older than 2.38 is refused).
- It deploys that release as usual, then stops Tomcat, restores the database (`dhis2-restoredb -y`) and starts it again.
- Encrypted backups: asks for the password file (default `PASSWORD_FILE` from `dhis2-env`).
- A matching file-store archive next to the database backup is offered for restore into `/opt/dhis2/files`.
- The admin login step is skipped.
- Automation: `--restore <file>`, `--restore-files yes|no`, `--backup-password-file <path>`.

## 12. Command and flag rules (every `dhis2-*` command)

Agreed 2026-09-26. Existing commands are brought in line in phase 3b; new commands follow them from the start.

**Inputs**
- Every input has a flag. Positional arguments are only for the main subject (usually the instance name); any other
  positional argument also gets a named flag (e.g. `--ip`, `--postgres`).
- Prompts appear only on a terminal, and only for values not given as flags.
- `-y` means nothing is asked at all. Every required answer must come from a flag, or a default documented as safe.
  If anything is missing, the command stops **before changing anything** and lists **all** missing flags in one error (exit 3).
- Without `-y` and without a terminal nothing can be asked, including a confirmation: the command stops and says to add `-y`
  (exit 3). Automation therefore always passes `-y`, and nothing ever hangs.
- Every short flag also has a long name, both shown in `-h` (e.g. `-V`/`--release`, `-g`/`--glowroot`, `-m`/`--munin`,
  `-n`/`--no-database`, `-U`/`--glowroot-user`), so automation scripts read clearly.
- Example, `dhis2-create-instance` with `-y`: required: name, `-V`/`-f`/`-l` (unless `--no-deploy`), `--based-on` (only if an
  own war's version can't be read), `-g`, `-m` (if Munin is installed), the Glowroot password (if needed). Safe defaults:
  IP (next free), postgres container (`postgres`), Glowroot user (`admin`), create and deploy.

**Secrets**
- **People** are asked for passwords interactively on a terminal (typed twice). Passwords are never flags.
- **Automation** passes them as a JSON object on stdin with `--secrets-stdin`, keys named after what they are for:
  `glowroot_password`, `munin_password`, `dhis2_password` (later e.g. cloud storage keys). The same for single-secret commands.
  Example: `echo '{"glowroot_password": "…"}' | sudo dhis2-glowroot-login --secrets-stdin -y`
- Never in argv: `sudo` logs full command lines to `/var/log/auth.log`, and they end up in shell history, `ps` and automation logs.
- Install: secrets go inside the `--config` JSON.
- Usernames are normal flags: `--glowroot-user`, `--munin-user`, `--dhis2-user` (default `admin`).

**Before changing anything**
- A command that changes things shows a **summary** of what it will do; on a terminal it asks to confirm; `-y` skips that.
- `--dry-run` on every command that changes state: check everything, print the summary (what would change, and whether it
  would be refused), change nothing. Exit 0, or the code the real run would give if refused (1 or 3).
- Destructive or risky actions need confirmation. The riskiest (e.g. going back to an older release) also need `--force`,
  plus typing the instance name on a terminal, or `--force -y` without one.

**Output**
- `--json` on **every** command (agreed 2026-09-27). With `--json`, stdout is one JSON object and nothing else; progress and
  prompts go to stderr. List/status commands keep their current JSON; commands that do something answer:
  - success: `{"ok": true, "command": "<name>", "result": {…command-specific…}}` (e.g. create-instance: name, hostname, path,
    url, ip, release, tomcat, java, glowroot, munin)
  - failure: `{"ok": false, "command": "<name>", "error": {"code": "<code>", "message": "…", …}}`, e.g. `"missing": [flags]` for
    `missing_input`. Stable codes the caller can switch on: `missing_input` (exit 3), `refused`, `not_found`, `already_exists`,
    `checksum_mismatch`, `dns_not_pointing_here`, `rate_limited`, `config_test_failed`, `failed`. Exit codes are unchanged.
  - `--dry-run --json`: the summary as data, with `"dry_run": true` and whether it would be refused.
  - Built into the shared helpers (`die`, `check_missing`, `summary`, `confirm_summary`); each command adds its `result`.
  - When: commands reworked in phase 4 get it there; the rest in a short phase 3c (deploy-war, restoredb, the login commands,
    upgrade-setup, backup).
- **Live results** (agreed 2026-09-27, built in phase 3c, on **every** command; phase 4 commands use the same helpers):
  1. `--json-stream`: one JSON object per line (JSON Lines) on stdout while the command runs: `start` (with the run id),
     `step` (started/done, message), `progress` (percent, e.g. downloads), and a last line `{"type": "result", …}` that is the
     same object `--json` gives (ok/result or ok/error). Plain `--json` stays: one object at the end.
  2. Every run also writes its lines to `/var/log/dhis2-tools/runs/<run-id>.jsonl`; the run id is printed first. A caller
     whose connection dropped reads on from the file; past runs stay as a record.
  3. `--detach`: the command starts itself as a background job (a systemd service unit, so it survives the SSH session
     ending), prints its run id and returns at once. New command `dhis2-run`: `follow <id>` (stream the lines, resumable),
     `status <id> [--json]` (running / succeeded / failed + the final result), `list` (recent runs).
  - Nuxt: start with `--detach`, show progress with `dhis2-run follow`, reconnect the same way. Ansible: start with
    `--detach`, poll `dhis2-run status <id> --json`.
  - Built into the shared helpers: `step` / `progress` calls replace the progress messages commands print today, so human
    output and the stream come from the same place.
- Errors go to stderr through `die` (`setup/lib/dhis2-lib.sh`).
- `-h`/`--help` lists every flag with its default, and exits 0.

**Exit codes**: 0 success (also `--dry-run`), 1 failure or refused, 2 update available (`dhis2-tools-update --check` only),
3 missing input. A command never exits 0 after a partial failure.

**State**: all state lives on the server (labels `user.dhis2.*`, files in `/usr/local/etc/dhis`); re-running a command is safe.

## 12a. Versions and releases of the tools  [being discussed 2026-09-27]

- **Version numbers** (agreed, R1): semantic versioning, `MAJOR.MINOR.PATCH`:
  - PATCH: fixes only; MINOR: new features, nothing existing breaks; MAJOR: something works differently and admins or
    automation must adapt.
  - The flags and the JSON output (section 12) are the interface: changing or removing a flag or a JSON field means a new
    MAJOR version; adding one needs only a MINOR.
  - The first public release is `1.0.0`, launched after testing on the test server. Test versions before a release are
    release candidates: `1.0.0-rc.1`, `1.0.0-rc.2`, …
  - The version is kept in one file in the repo (`VERSION` at the root, e.g. `1.0.0`), so the scripts can show it without git.
- **Making a release** (agreed, R2):
  - `CHANGELOG.md` is kept up as work happens: an "Unreleased" section, and every task that changes behaviour adds a line in
    the same commit, under Added / Changed / Fixed / Security / Upgrade notes (what `dhis2-upgrade-setup` does, and anything
    an admin must do by hand).
  - Steps: everything in the release tested and approved (`[x]`) → set `VERSION`, turn "Unreleased" into `## <version> (<date>)`
    → merge `develop` into `master` (only with the user's yes) → tag `v<version>` on `master` → the user pushes `master` and the
    tag → GitHub Release `v<version>` with that changelog section as notes (release candidates marked pre-release).
  - `tools/release.sh <version>` (in the repo, never installed on servers) checks the number is valid and newer, updates
    `VERSION` and `CHANGELOG.md`, commits and tags locally, and prints the push and `gh release create` commands. It never pushes.
  - `RELEASING.md` in the repo describes the process.
- **Numbering until 1.0.0** (agreed 2026-09-27): `0.x` milestones. A `0.x` version may still change in breaking ways.
  - Phases 0–3b, once tested on the test server: **`0.1.0`**. Phase 3c: `0.2.0`. Phase 4: `0.3.0`. And so on, one minor version
    per tested chunk.
  - **`1.0.0` contains phases 0–6 and 8**: everything a new or an existing server needs day to day. Then `1.0.0-rc.N` on the test
    server, then `1.0.0`.
  - After `1.0.0`: phase 7 (create from a backup), phase 9 (DHIS2 upgrades) and phase 10 (docs, whiptail) as `1.x` releases.
- **What servers install** (agreed, R3). This replaces "updates follow `master`" (section 3):
  - Channels, chosen per server and remembered: `stable` (default: the newest release) and `rc` (the newest release or release
    candidate: the test server, early testers). `install.sh --channel <name>`; `dhis2-tools-update --channel <name>` switches it.
    (A `develop` channel was dropped on 2026-09-27 with the `develop` branch; the `DHIS2_TOOLS_BRANCH` testing override stays
    for testing unreleased work on a release branch.)
  - `dhis2-tools-update --version <x.y.z>` installs exactly that release. An older version than the installed one is refused
    unless `--force` (with a warning: `dhis2-upgrade-setup` only migrates forward). `--rollback` stays for emergencies.
  - A major update (e.g. `1.x` → `2.0.0`) is never silent: even with `-y` it needs `--allow-major`, otherwise it stops and
    shows what's new. Minor and patch updates go ahead as normal.
  - No automatic updates for now: a server updates only when someone runs `dhis2-tools-update` (automatic updates: later).
- **Seeing versions** (agreed, R4):
  - Every command answers `--version` (`dhis2-tools 1.2.0 (stable)`), from the shared helpers; every `--json` answer and every
    run log includes the tools version.
  - On the server: `/opt/dhis2-tools/VERSION` holds the release number (e.g. `1.2.0`); `/opt/dhis2-tools/INSTALL.json` holds
    version, channel, commit and install time. On a release branch, the repo's `VERSION` names the version being built with
    `-dev` (e.g. `1.3.0-dev`); a server installed from it for testing shows `1.3.0-dev+<short commit>`.
  - `dhis2-tools-update --check` shows the installed version and channel, the newest available, and the release notes of every
    release in between (from GitHub Releases); `--check --json` gives the same as `installed`, `channel`, `latest`,
    `update_available`, `major`, `releases: [{version, date, notes}]`.
- **Branches** (R5, partly agreed):
  - `master` holds **released code only**: it moves only when a release is made (with the user's yes), so it always equals the
    newest release.
  - Work happens on **a branch per upcoming version**, `release/<x.y.z>` (e.g. `release/0.2.0`). The former `develop` branch was
    renamed `release/0.1.0` on 2026-09-27; there is no `develop` branch any more.
  - One version at a time until `1.0.0`: the next version's branch starts from `master` after the previous release.
  - Release candidates are tagged on the release branch (`v0.2.0-rc.1`); when one passes, that commit gets the release tag and
    `master` fast-forwards to it, so what was tested is exactly what is released.
  - Urgent fixes to a released version: a short-lived `hotfix/<x.y.z>` branch from that release's tag; the fix is released from
    it and merged back into the work branch.

## 13. Management app and automation

The user will build a Nuxt web app to manage servers (deploy instances on existing servers, manage backups, ...). It, and
Ansible, will drive these commands over `ssh <server> sudo <command>`, which is why section 12 exists. Useful for it:
`dhis2-list-instances --json`, `dhis2-list-backups --json`, `dhis2-tools-update --check --json`, `--dry-run` for preview
screens, exit code 3 for "needs more answers".

## 14. Existing servers

`dhis2-upgrade-setup` repairs and migrates servers installed with the original scripts, and `dhis2-tools-update` runs it after
every update. **Every change to installed state or to an `etc/*` template ships with a step there** (templates are never
overwritten and may hold local edits, so only known lines are patched). It is safe to re-run, and `--dry-run` reports what each
step would change without changing anything. Without a terminal it behaves as `-y`; the password steps then use
`--secrets-stdin` (`munin_password`, `glowroot_password`, `glowroot_passwords` per instance) or are skipped with a warning.
Its questions have flags: `--renew`, `--glowroot-login`, `--glowroot-user`, `--munin-user`, `--restart`. Tomcat restarts are
collected and done only with `--restart yes` or a yes at the end (default no).

## 15. Decisions log

- 2026-09-25: the fork (`redmondking/dhis2-tools-ng`) is the user's own project; nothing is contributed back to
  `bobjolliffe/dhis2-tools-ng`, which stays as the `upstream` remote (push disabled) to pull fixes.
- 2026-09-25: host Ubuntu 24.04 for new installs; `dhis2-upgrade-setup` also runs on existing 20.04/22.04 hosts.
- 2026-09-25: containers on 24.04; DHIS2 ≤2.41 instances on 22.04 with tomcat9 (section 5).
- 2026-09-25: nginx only.
- 2026-09-25: oldest DHIS2 version 2.38; one shared PostgreSQL 16 container.
- 2026-09-25: PostgreSQL 13 → 16 upgrade on existing servers: optional, with a checked backup (phase 8).
- 2026-09-25: memory per instance asked, with a default based on free RAM (phase 5).
- 2026-09-25: Munin and Glowroot optional; separate logins; passwords always typed by the user.
- 2026-09-25: hostnames and paths design (section 7); backups grouped by instance, then date; file store backed up;
  encrypted backups restorable; remotes SSH + cloud, keep or mirror per remote.
- 2026-09-25: prompts in plain bash first, `whiptail` only once everything is tested.
- 2026-09-26: installs automatable (`setup.sh --config`) as well as interactive.
- 2026-09-26: updates from the hardcoded repo's `master`; tools installed to `/opt/dhis2-tools` with links in `/usr/local/bin`.
- 2026-09-26: exact release names; `-y` needs every required flag; `--dry-run`; exit 3 for missing input; command and flag rules.
- 2026-09-26: secrets interactive for people, `--secrets-stdin` JSON for automation.
- 2026-09-26: create-instance asks create-and-deploy vs create-only, shows a summary to confirm; own wars supported.
- 2026-09-26: restoring after deploying (stop, restore, start) instead of a "restore before first start".
- 2026-09-26: `--install-key no` for remotes; new `dhis2-list-backups`; `dhis2-upgrade-setup` takes passwords via `--secrets-stdin`.
- 2026-09-26 (phase 3b plan): labels `user.dhis2.line` (create-only instances need it) and `user.dhis2.source`; `dhis2-upgrade-setup`
  takes per-instance Glowroot passwords as `glowroot_passwords` = `{"<instance>": "…"}` in `--secrets-stdin` (own mode).
- 2026-09-26 (phase 3b): create-only asks the version line (`--line`); `dhis2-restoredb` stops the instance's Tomcat, restores and
  starts it again when the database belongs to an instance; every short flag gets a long name; 3b order: helpers, create-instance
  and deploy-war, the security fixes (logview, ssl-setup), then the rest, one commit per command.
- 2026-09-27: nginx only re-confirmed (the user asked whether forcing nginx is a problem for organisations using apache; the proxy
  is a container these tools manage, and supporting both would double every proxy feature).
- 2026-09-27: `--json` on every command (ok/result or ok/error with stable error codes); phase 4 for the commands it reworks,
  phase 3c for the rest.
- 2026-09-27: branches: `release/<x.y.z>` per version (develop renamed `release/0.1.0`), one version at a time until 1.0.0,
  `master` = released code only, `develop` channel dropped.
- 2026-09-27: `--version` on every command; `VERSION` + `INSTALL.json` on servers; `--check` shows release notes (also in JSON).
- 2026-09-27: channels stable / rc / develop; `--version`; `--allow-major` for major updates; no automatic updates yet.
- 2026-09-27: `0.x` milestones before `1.0.0` (phases 0–3b = `0.1.0` once tested); `1.0.0` = phases 0–6 and 8; 7, 9, 10 in `1.x`.
- 2026-09-27: releases: changelog kept up as work happens; tag + GitHub Release; `tools/release.sh` prepares locally, the user
  pushes; `RELEASING.md`.
- 2026-09-27: the tools get versions: semantic versioning, flags and JSON output count as the interface, release candidates
  (`-rc.N`) before releases, first public release `1.0.0`.
- 2026-09-27 (phase 4 C): one `dhis2-instance` command (create, delete, edit, deploy, list; separate files inside), no links
  under the old names; `dhis2-upgrade-setup` retires the original copies on existing servers.
- 2026-09-27 (phase 4 C): hostname settings files, proxy config always rebuilt from settings; list page with a description
  per instance; 302 root redirect.
- 2026-09-27: live results on every command: `--json-stream` (JSON Lines), run log files, `--detach` + `dhis2-run`; built in 3c.
- 2026-09-27 (phase 4 B): paths `[a-z0-9-]`, 1–40 characters; each hostname's root is a list page or a redirect to a chosen
  instance, asked when an instance is created on it; container names = a short name per hostname (default its first part) +
  the path. Corrected the same day: the short name is asked when the hostname is created, not at its first instance.
- 2026-09-27 (phase 4 A): `fqdn` renamed `default_hostname`; any hostname whose DNS points here is allowed (no base domains;
  replaces "subdomains of the fqdn only"); a certificate email per hostname, defaulting to the server's email.
- 2026-09-27 (phase 4 A): Munin's address is a setting (`munin_hostname`, default the `fqdn`), not tied to the main domain.
- 2026-09-27: certificate failure handling (pre-flight checks with an automatic staging test, plain reasons, retry limits and
  `--wait-dns`, `dhis2-ssl-status` for renewals, `--json`), built in phase 4.
- 2026-09-27: certificates via certbot webroot (the proxy never stops); `dhis2-ssl-setup` only switches to https once the
  certificate exists and the new config passes its test, otherwise the old config stays (3b.17).
- 2026-09-26: `dhis2-backup` reads how from `dhis2-env`, what from instance labels (`user.dhis2.backup`, `user.dhis2.postgres`),
  and where to copy from the remotes files; the old lists stay only for databases without an instance.
