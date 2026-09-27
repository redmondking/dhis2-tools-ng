# Architecture

The design of dhis2-tools-ng: what the tools do and the rules they follow. Unbuilt parts carry the version they arrive in,
e.g. `[0.3.0]`. What is built but not yet tested on a real server is tracked in `tasks.md`.

## 1. Overview

Bash tools that run DHIS2 on one Ubuntu server, each part in its own LXD container:

```
Ubuntu 24.04 host (LXD, ufw; ports 80/443 forwarded to the proxy)
├── proxy       nginx + certbot: https per hostname, routes /<path> to instances
├── postgres    PostgreSQL 16 + PostGIS, one database per instance
├── monitor     Munin (optional): graphs for the host and every container
└── <instance>  one per DHIS2 instance: Tomcat 9 or 10, DHIS2, optional Glowroot agent
```

Admins, and automation over `ssh <server> sudo <command>`, use six commands (section 2). The repo is the user's own fork
`redmondking/dhis2-tools-ng`; `bobjolliffe/dhis2-tools-ng` is kept as `upstream` only to pull fixes (push disabled).

## 2. Commands

Each is `<command> <action> [options]`; each action lives in its own file (e.g. `setup/service/instance/create`). `[0.3.0]`

| Command | Actions |
|---|---|
| `dhis2-instance` | `create`, `delete`, `edit`, `deploy`, `list`, `logs`; `upgrade` `[1.2.0]` |
| `dhis2-hostname` | `add`, `list`, `set-root`, `set-munin`, `remove`, `rebuild`, `cert` (get / retry / replace a certificate), `certs` (expiry and last renewal of all) |
| `dhis2-backup` | `run` (the nightly job), `list`, `restore`, `remote add\|list\|test\|sync\|remove` |
| `dhis2-monitoring` | `glowroot [instance]` (set a Glowroot login), `munin` (set the Munin login) |
| `dhis2-server` | `setup` (wizard), `update` (new tools), `migrate` (bring this server's setup up to the installed tools), `db-activity`; `repair` is kept free for real repairs later |
| `dhis2-run` | `follow`, `status`, `list` (background runs) `[0.2.0]` |

- `install.sh` stays separate: the one-line bootstrap before any command exists.
- Until `[0.3.0]` the code still has the old names: `dhis2-create-instance`, `dhis2-delete-instance`, `dhis2-deploy-war`,
  `dhis2-list-instances`, `dhis2-logview` (→ `dhis2-instance`); `dhis2-ssl-setup` (→ `dhis2-hostname cert`);
  `dhis2-backup`, `dhis2-restoredb` (→ `dhis2-backup`); `dhis2-glowroot-login`, `dhis2-munin-login` (→ `dhis2-monitoring`);
  `dhis2-setup`, `dhis2-upgrade-setup`, `dhis2-tools-update`, `dhis2-dbactivity` (→ `dhis2-server`). No links keep the old
  names; `dhis2-server migrate` moves old copies aside on existing servers (`/usr/local/etc/dhis/old-scripts`) and prints the
  new commands.
- `dhis2-tomcat-munin` becomes internal (`dhis2-instance edit --munin yes`).

## 3. Command rules

**Inputs**
- Every input has a flag; positional arguments only for the main subject (usually the instance), and those also get a named
  flag (e.g. `--ip`, `--postgres`). Every short flag has a long name (`-V`/`--release`, `-g`/`--glowroot`, …).
- Prompts only on a terminal, and only for values not given as flags.
- `-y` asks nothing: every required value must be a flag or a documented safe default. If anything is missing, the command
  stops before changing anything and lists **all** missing flags in one error (exit 3).
- No `-y` and no terminal: nothing can be asked, not even a confirmation: stop and say to add `-y` (exit 3).

**Secrets**
- People type passwords at a prompt (twice). Passwords are never flags: `sudo` logs full command lines to
  `/var/log/auth.log`, and they end up in shell history, `ps` and automation logs.
- Automation passes them as a JSON object on stdin with `--secrets-stdin`, keys named for their use: `glowroot_password`,
  `glowroot_passwords` (`{"<instance>": "…"}`), `munin_password`, `dhis2_password`, cloud storage keys. Unknown keys are refused.
- Usernames are normal flags: `--glowroot-user`, `--munin-user`, `--dhis2-user` (default `admin`).

**Before changing anything**
- A summary of what will happen; on a terminal a confirmation (destructive actions default to No); `-y` skips it.
- `--dry-run` on every command that changes state: check everything, show the summary, change nothing (exit 0, or the code
  the real run would give if refused).
- The riskiest actions also need `--force`, plus typing the instance name on a terminal, or `--force -y` without one.

**Output**
- Errors go to stderr through `die`; `-h`/`--help` lists every flag with its default; `--version` shows
  `dhis2-tools <version> (<channel>)`.
- `--json` on every command: stdout is one JSON object, everything else goes to stderr. List/status commands give their data;
  commands that act give `{"ok": true, "command": …, "result": {…}}` or
  `{"ok": false, "command": …, "error": {"code": …, "message": …}}`. `--dry-run --json` gives the summary with
  `"dry_run": true`. Every answer and every run log includes the tools version. `[0.2.0]` (commands reworked in `[0.3.0]` get it there)
- Error codes: `missing_input` (with `"missing": [flags]`), `refused`, `not_found`, `already_exists`, `checksum_mismatch`,
  `dns_not_pointing_here`, `rate_limited`, `config_test_failed`, `failed`.
- Live results `[0.2.0]`:
  - `--json-stream`: JSON Lines while running (`start` with the run id, `step`, `progress`); the last line is the `--json` answer.
  - Every run is logged to `/var/log/dhis2-tools/runs/<run-id>.jsonl`.
  - `--detach`: the command re-runs itself as a systemd service unit (surviving the SSH session), prints the run id and returns.
    `dhis2-run follow <id>` streams it (resumable after a dropped connection), `dhis2-run status <id> --json` gives the state
    and final answer, `dhis2-run list` recent runs.
- Automation: long commands start with `--detach`, then `dhis2-run follow` or poll `dhis2-run status --json`; previews use
  `--dry-run --json`; exit 3 means "needs more answers".

**Exit codes**: 0 success, 1 failure or refused, 2 update available (`dhis2-server update --check` only), 3 missing input.
Never 0 after a partial failure.

**State**: everything lives on the server (container labels `user.dhis2.*`, files in `/usr/local/etc/dhis`); every command is
safe to run twice. The shared helpers are in `setup/lib/dhis2-lib.sh`.

## 4. Install, update and migrate

**Repo**
- `install.sh`; `setup/lib/dhis2-lib.sh` (shared helpers); `setup/service/` (the commands); `setup/containers/<type>` (script
  piped into a new container, then `<type>_postsetup` sourced on the host); `setup/configs/*` (LXD preseed, sysctl, proxy and
  postgres configs, `containers.json.sample`); `setup/etc/*` (templates); `setup/parse_config.sh` (reads `containers.json`);
  `setup/lxd_setup.sh`, `setup/create_containers.sh`, `setup/install_scripts.sh` (host setup); `tools/release.sh`.

**On a server**
- `/opt/dhis2-tools/`: the repo's `setup/` and `install.sh`, plus `VERSION` (the release number) and `INSTALL.json` (version,
  channel, commit, install time) `[0.2.0]`. The previous install is kept in `/opt/dhis2-tools.old`.
- `/usr/local/bin/dhis2-*`: links to the six commands. Internal scripts get no link; `delete_all.sh` (deletes every container)
  deliberately gets none.
- `/usr/local/etc/dhis/`: this server's settings (`containers.json`, `dhis2-env`, `hostnames/`, `remotes/`, `glowroot-login`,
  templates). Updates never replace them. `setup/etc/*` templates are copied there once and may hold local edits.
- Entry scripts `cd` to their own folder (`readlink -f "$0"`), so relative paths work from anywhere.

**Install and update**
- First install: `curl -fsSL https://raw.githubusercontent.com/redmondking/dhis2-tools-ng/master/install.sh | sudo bash`
  (`--channel`), on Ubuntu 24.04. `dhis2-server update` does the same later.
- Updates come from the hardcoded repo, never a local checkout: the release's tarball is unpacked next to the install and
  swapped in; `dhis2-server migrate` then runs.
- Channels, remembered per server `[0.2.0]`: `stable` (default: the newest release) or `rc` (newest release or release candidate).
  Until then updates follow `master`.
- `--check` (exit 2 if an update exists) shows installed and newest version and the release notes in between (`--json`:
  `installed`, `channel`, `latest`, `update_available`, `major`, `releases`). `--version <x.y.z>` installs exactly that one; older
  than installed needs `--force`. A major update needs `--allow-major`, even with `-y`. `--rollback` goes back one install.
  No automatic updates.
- Testing overrides: `DHIS2_TOOLS_BRANCH` (e.g. `release/0.1.0`), `DHIS2_TOOLS_DEST`, `DHIS2_TOOLS_BIN`.

**Setting up** (`dhis2-server setup`)
- Now: `dhis2-setup [containers.json]` reads a config file.
- Wizard `[0.4.0]`: plain bash prompts (`whiptail` later); `--config <file|->` does the same with no prompts, in the format the
  wizard writes (`configs/containers.json.sample`, kept complete and in sync with the wizard); secrets may be in it and are
  stripped before `containers.json` is saved.
  Automation writes the JSON to a root-only file, runs `--config` on it, then deletes it. Asks `default_hostname`, email,
  `public_ip`, TZ, Munin, Glowroot, backup settings.

**Migrate** (`dhis2-server migrate`)
- Brings a server set up with older tools (including the original scripts, on 20.04, 22.04 or 24.04 hosts) up to the installed
  tools. **Every change to installed state or to an `etc/*` template ships with a step here**, patching only known lines.
- Safe to re-run; `--dry-run` reports every change. Without a terminal it behaves as `-y`; password steps use
  `--secrets-stdin` or are skipped with a warning. Flags for its questions: `--renew`, `--glowroot-login`, `--glowroot-user`,
  `--munin-user`, `--restart` (Tomcat restarts are collected and done only with `--restart yes` or a yes at the end).

## 5. Containers and packages

- The proxy, postgres and monitor containers run Ubuntu 24.04; instance containers depend on the DHIS2 version (section 6).
- Only Ubuntu's own packages, no third-party repositories or snaps: `postgresql-16` + `postgresql-16-postgis-3`, `nginx` 1.24
  (so `listen 443 ssl http2;`, not `http2 on;`), `certbot` (apt). No OCSP stapling.
- **nginx is the only proxy.** Older servers with apache keep working until `dhis2-server migrate` moves them to nginx `[0.6.0]`;
  apache support is then deleted.
- One shared PostgreSQL 16 container. DHIS2 2.38 on 16 is on the test list; if it fails, a second postgres container on 14.
- Existing servers keep their containers (20.04, PostgreSQL 13) until `migrate` moves them to 24.04 and PostgreSQL 16 in one
  optional step, with a checked backup first `[0.6.0]`.
- `public_ip` in `containers.json`: the address the hostnames' DNS must point to (the host often only sees a private address).
  The wizard suggests it from an outside "what's my IP" lookup; the admin confirms. `[0.3.0]`

## 6. DHIS2 versions

- Release feed `https://releases.dhis2.org/v1/versions/stable.json`: every release has a full `name` (`2.42.0`, hotfix
  `2.42.5.2`), `url`, `sha256`; every version line has `jdk` and `supported`.
- Only **2.38 and newer**. The list shows every release incl. hotfixes, one row per version, marked supported / end of support.
  Release names are typed **exactly** (`2.42` refused, `2.42.0` accepted); `-V <release>`.
- The release decides the container, Tomcat and Java:

  | DHIS2 | Servlet API | Container | Java |
  |---|---|---|---|
  | 2.42+ | jakarta | Ubuntu 24.04, `tomcat10` | 17 |
  | 2.41 | javax | Ubuntu 22.04, `tomcat9` | 17 |
  | 2.38–2.40 | javax | Ubuntu 22.04, `tomcat9` | 11 |

  (`tomcat9` exists only up to Ubuntu 22.04, whose standard support ends April 2027.)
- Every official war is checked against its sha256 **before** anything is created or changed. On a mismatch: try again,
  choose another release, or stop; never "deploy anyway". A war's release is read from `WEB-INF/lib/dhis-api-<release>.jar`.
- Where DHIS2 comes from (create and deploy): an official release (`-V`), an own war file (`-f`) or URL (`-l`). Own wars have
  no published checksum (`--sha256` optional); their release is read from the war, or given with `--based-on <version>` and
  recorded as `custom`.
- `dhis2-instance deploy`: offers only the instance's own version line, current release marked. Another version line, or a
  release needing another Tomcat, is refused. Going back within a line needs `--force` plus the typed instance name (or
  `--force -y`), after a warning that releases can change the database.
- `dhis2-instance upgrade` `[1.2.0]`: another version line. 2.41 → 2.42 needs a new container (Tomcat 9 / 22.04 → Tomcat 10 /
  24.04), carrying over `dhis.conf`, `/opt/dhis2`, Glowroot, IP, proxy entry and labels; backup first, rollback plan,
  migrations followed in the log, health check after start.

## 7. Instances

**Labels** (all state about an instance is on its container)

| Label | Values |
|---|---|
| `user.type` | `Tomcat server` (marks a DHIS2 instance) |
| `user.dhis2.version` | exact release, `none` (created without DHIS2) or `custom` |
| `user.dhis2.line` | version line, e.g. `2.42` |
| `user.dhis2.source` | `official`, `custom` or `none` |
| `user.dhis2.tomcat` | `tomcat9` (also when missing) or `tomcat10` |
| `user.dhis2.java` | `11`, `17`, … |
| `user.dhis2.glowroot`, `user.dhis2.glowroot.user` | `shared` / `own` / `off`; the Glowroot user the tools manage |
| `user.dhis2.munin` | `yes` / `no` |
| `user.dhis2.hostname`, `user.dhis2.path`, `user.dhis2.description` `[0.3.0]` | its address and list-page text |
| `user.dhis2.backup`, `user.dhis2.postgres` `[0.5.0]` | `plain` / `encrypted` / `no`; its postgres container |

`migrate` labels instances made by older tools (version from the deployed war). `dhis2-instance list` shows name, version,
address, Tomcat, Java, IP, status, Glowroot, Munin (`--json`).

**Names and addresses** `[0.3.0]`
- The container name is also the database name and database user; all SQL quotes it (`"hmis-prod"`).
- Suggested name: `<short name of the hostname>-<path>`, e.g. `moh-prod`; `--name` to choose another.
- Automatic IPs: free ones in `.10`–`.19` first, then `.100`–`.249` (proxy `.2`, postgres `.20`, Munin `.30`); `--ip`.

**`dhis2-instance create`**, in order: hostname (menu of existing ones with their paths and certificate status, or a new one:
section 8; default `default_hostname`; a hostname with a pending certificate gets a plain-http warning) → path → name →
description (optional) → create and deploy, or create only (`--no-deploy`, then `--line <version>` decides the container) →
source and release (section 6) → Glowroot, Munin → what the hostname's root shows → summary → confirm. `[0.4.0]` adds the DHIS2
admin login and memory, `[0.5.0]` the backup question.
- Flags: `-H/--hostname`, `-p/--path`, `--name`, `--description`, `--root this|list|keep`, `-n/--no-database`, `--ip`,
  `--postgres`, and for a new hostname `--short-name`, `--email`, `--cert`.
- With `-y`, required: `-H` and `-p` `[0.3.0]` (until then the name), a source (`-V`/`-f`/`-l`, or `--no-deploy` + `--line`),
  `--based-on` if an own war's version can't be read, `-g`, `-m` if Munin is installed, the Glowroot password if needed. Safe
  defaults: IP, postgres container (`postgres`), Glowroot user (`admin`), name, root (`this` for a hostname's first instance,
  `keep` after that).

**`dhis2-instance delete`**: a summary of what exists (container, database and user, proxy entries, database access line, hosts
line), confirm (default No). Refuses containers that aren't instances. Its backups are kept. If the hostname's root opened it:
ask what the root shows next (`--root list|<instance>`; default the list). If it was the hostname's last instance: ask whether to remove the hostname too, with **no
default** (`--remove-hostname yes|no` required without a terminal); never for `default_hostname`.

**`dhis2-instance edit`** `[0.3.0]`: `--hostname`, `--path`, `--description` / `--clear-description`; `--glowroot`, `--munin`
later.
- Moving (hostname and/or path) **renames** the instance to `<short name>-<path>` (asked, `--name`): container, database and user
  (with a new random database password written to `dhis.conf`), `pg_hba.conf` line, labels, hosts line, Munin node and backup
  folder. DHIS2 is down for a few minutes; a failed step undoes the earlier ones.
- Both hostnames' roots are handled as on create and delete.
- The old address: asked each move, explaining what it means in practice (browsers and bookmarks keep working; the DHIS2
  Android app and integrations must be reconfigured either way; the old path stays taken). **No**: the old path is removed.
  **Yes**: a redirect (307, keeping the rest of the address) stays until removed with `dhis2-hostname`. `--redirect yes|no`.
- A reminder to check DHIS2's own "server base URL" setting.

**DHIS2 admin login** `[0.4.0]`: username [`admin`] and password [`district`] are asked; only if either differs is it changed
through the API once DHIS2 is up. Keeping the defaults prints a warning. Skipped for an instance restored from a backup.
`--dhis2-user`, `dhis2_password` in `--secrets-stdin`.

**Memory** `[0.4.0]`: asked, default based on free RAM, setting Java's heap and the container limit (`--memory`).

## 8. Hostnames and certificates

**Hostnames** `[0.3.0]`
- Any hostname is allowed if its DNS points at `public_ip`; hostnames are stored in lowercase.
- `default_hostname` in `containers.json` (was `fqdn`; `migrate` renames it, and the scripts read `fqdn` until then): offered
  first for new instances. Any full hostname, including a subdomain.
- An instance's address is `https://<hostname>/<path>`. Paths: lowercase letters, digits and `-`, 1–40 characters, not starting
  or ending with `-`; unique per hostname; never `/` itself. Reserved: `/munin` on Munin's hostname, `/<path>-glowroot` of each
  instance. Tomcat serves DHIS2 at the same path (`webapps/<path>`), so the proxy never rewrites paths.
- Existing instances: `migrate` labels them hostname = `default_hostname`, path = their name, and gives `default_hostname` a
  short name (its first part). Nothing is renamed.
- Each hostname has a **short name** (asked when the hostname is created, default its first part, unique on the server).
- **The root** (`https://<hostname>/`) shows a list page or redirects (302) to one of its instances:
  - asked when an instance is created on it (first instance: "this instance or a list", default this; later: "keep, this
    instance, or a list", default keep; `--root this|list|keep`)
  - asked again when the root's instance is deleted or moved (the list page and its other instances; default the list)
  - changed any time with `dhis2-hostname set-root` (`--list` / `--instance <name>`)
  - menus list only that hostname's instances and accept the number or the path
- **The list page**: the hostname as title, a link per instance with its description (HTML-escaped); no versions or other details.
- **Settings and proxy config**: `/usr/local/etc/dhis/hostnames/<hostname>.json` (short name, certificate choice, email and
  account, root, redirects). The nginx config is always built from these settings plus the instance labels, then tested
  (`nginx -t`) and reloaded; a failed test puts the old config back. Files in the proxy: `/etc/nginx/sites/<hostname>.conf`,
  `/etc/nginx/upstream/<hostname>/<path>.conf`, `/var/www/hostnames/<hostname>/index.html`.
- **Adding** (`dhis2-hostname add`, or "a new hostname" in `dhis2-instance create`): valid and new → short name → certificate
  email [the server's] → DNS check against `public_ip` (on failure: what it points at and what to create; retry, `--wait-dns`,
  or cancel; exit 1 without a terminal) → certificate → settings, nginx config, reload → report. Before its certificate a
  hostname is served over http; after it, https with http redirected (except Let's Encrypt's check).
- **`dhis2-hostname`**: `add`; `list [<hostname>] [--json]` (short name, instances, root, redirects, certificate status and
  expiry, email); `set-root`; `set-munin` (move the Munin pages); `remove` (refused while instances use it; asks about the
  certificate; never `default_hostname`); `rebuild [<hostname>]` (from the settings, for repairs); `cert`; `certs`. Short names
  and emails can't be changed, and hostnames aren't renamed (add, move the instances, remove).

**Certificates**
- Per hostname, one of (`--cert letsencrypt|own|none`) `[0.3.0]`:
  - **Let's Encrypt** (default).
  - **Own**: certificate and key files (`--cert-file`, `--key-file`), checked (key matches, hostname covered, not expired),
    installed, tested; renewed by the admin running `dhis2-hostname cert` again with new files.
  - **None**: plain http only (e.g. an internal server), warned every time.
- If Let's Encrypt fails, the hostname stays **http only, certificate pending** (shown by `list`, `certs` and `dhis2-instance
  create`); `dhis2-hostname cert <hostname>` finishes it. `[0.3.0]`
- Let's Encrypt uses certbot **webroot** (not standalone, not the nginx plugin): the proxy serves `/.well-known/acme-challenge/`
  from `/var/www/letsencrypt` (`configs/nginx-acme-challenge.conf`, installed as `/etc/nginx/snippets/acme-challenge.conf` in every
  port-80 server block; the http → https redirect is `location / { return 301 … }` so the check isn't redirected). The proxy
  never stops; renewals run from certbot's systemd timer and a deploy hook reloads nginx. Asked whether to renew automatically
  (`--renew`, default yes).
- Getting a certificate switches to https only once certbot succeeded, the files exist and the new config passes `nginx -t`;
  otherwise the old config stays and the site keeps working on http (exit 1). `--dry-run` tests against Let's Encrypt's staging
  server.
- Email: the server's `email` by default, another per hostname if asked. certbot uses `-m` only when it registers an account, so
  each email gets its own account (`certbot register`), and the hostname's certificate uses it (`--account <id>`). `[0.3.0]`
- Failure handling `[0.3.0]`:
  1. Before the real request: an automatic staging test first; DNS points here; no stray AAAA record; no CAA record excluding
     Let's Encrypt; the proxy serves a test file from the challenge folder; port 80 reaches the proxy (host `ufw`, NAT).
  2. Plain reasons for certbot's common errors (NXDOMAIN, timeout, another server answered, rate limited with the retry time),
     plus the path of certbot's log.
  3. After 3 failed real attempts within an hour, refused (with the retry time) unless `--force`. `--wait-dns` re-checks
     every minute, up to a limit.
  4. `dhis2-hostname certs` (`--json`): expiry, last renewal attempt and result per certificate, warning under 14 days; the
     warning also shows in `dhis2-instance list`.
  5. `--json`: success, the failed stage (dns, ipv6, caa, proxy, letsencrypt, config-test), the reason, the retry time.
- Apache servers keep standalone certbot with stop/start hooks until migrated to nginx.

## 9. Monitoring

- **Munin** (optional; asked in the wizard): a `monitor` container, and munin-node on the host, proxy, postgres and each
  instance that says yes (`-m`). Its pages are at `https://<munin_hostname>/munin`; `munin_hostname` in `containers.json`
  defaults to `default_hostname` and can be a hostname of its own (`dhis2-hostname set-munin`) `[0.3.0]`. Login: nginx basic auth,
  one server-wide login, SHA-512 hash (`openssl passwd -6`) on the proxy; `/munin` stays closed until it is set
  (`dhis2-monitoring munin`).
- **Glowroot** (optional per instance, `-g`; default from `apm` in `containers.json`): a Java agent inside the instance's Tomcat,
  version 0.14.7, port 4000, published at `/<path>-glowroot` on the instance's hostname.
  - Its own login: `admin.json` users with `passwordHash` = PBKDF2-HMAC-SHA1, 16-byte key and salt, 500000 iterations,
    `b64(hash):b64(salt):500000` (unpadded base64; exactly 500000), made with host `python3` from the password on stdin.
    No `anonymous` user. Users added in Glowroot itself are kept; only the managed login is replaced.
  - Login mode `glowroot_login` in `containers.json`: `shared` (one login for all; hash in `/usr/local/etc/dhis/glowroot-login`,
    root only) or `own` (per instance).
  - `dhis2-monitoring glowroot [instance]`: the shared login everywhere, or one instance's own. Glowroot reads `admin.json` only
    at startup, so it asks before restarting (`--restart yes|no`; with `-y`: yes).
  - Glowroot on Tomcat 10 (2.42+) is on the test list; if it fails there, it is turned off for 2.42+.
- Munin and Glowroot logins are separate; passwords are always typed (or `--secrets-stdin`), never defaulted or generated.
- Later: turning Glowroot or Munin on or off for an existing instance (`dhis2-instance edit`).

## 10. Backups  `[0.5.0]`

- `dhis2-backup run` reads:
  - **how**, from `/usr/local/etc/dhis/dhis2-env`: `BACKUP_DIR` (`/var/pgbackups`), `DAYS_TO_KEEP` (7), `WEEKS_TO_KEEP` (3,
    Sundays: `DAY_OF_WEEK_TO_KEEP`), `MONTHS_TO_KEEP` (12, on the 1st), `CIPHER`, `PASSWORD_FILE`, `EXCLUDED`
  - **what**, from each instance's labels: `user.dhis2.backup` and `user.dhis2.postgres` (instance name = database name)
  - **where to copy**, from `/usr/local/etc/dhis/remotes/<name>`
  - databases still in the old `PLAIN_BACKUPS` / `ENCRYPTED_BACKUPS` lists with no instance container are still dumped
- The time of the run is the cron line in `/etc/cron.d/dhis`. The wizard asks all of these with defaults and enables cron.
- Layout, per instance then per run:
  `BACKUP_DIR/<instance>/<date>-<daily|weekly|monthly>/<instance>.sql.gz[.enc]` and `<instance>.files.tar.gz[.enc]`
  (`/opt/dhis2/files`, the file store, encrypted when the database is). Retention applies per instance folder.
- A stopped instance: its database is still dumped; a file store that can't be archived is reported as skipped.
- Exits non-zero if anything failed; `--dry-run`, `--json`. (Today's `dhis2-backup` already fails on any failed dump.)
- `dhis2-instance create` asks "Back up this instance?" (`--backup plain|encrypted|no`). Delete drops the database; the backups stay.
- `dhis2-backup list [instance] [--json]`: instance, date, type, size, file store, encrypted.
- `dhis2-backup restore`: summary, confirm (default No); if the database belongs to an instance its Tomcat is stopped and
  started again afterwards (also after a failed restore); any failed step fails the command.
- **Remotes** (`dhis2-backup remote add|list|test|sync|remove`), any number:
  - SSH server (`rsync`, one key per remote; `ssh-copy-id` offered, or `--install-key no` prints the key for the caller to add)
    or cloud storage (`rclone`; credentials in `--secrets-stdin`)
  - mode per remote: `keep` (default, never delete there) or `mirror`
  - a cloud remote while some instances are unencrypted: warn, offer to encrypt, remind to keep the password file elsewhere
  - one failed remote doesn't stop the others; results in the log and `remote list`; no fetching back; failure alerts later
- `migrate` `[0.5.0]`: turns instances in the old lists into labels (others `no`), sets `user.dhis2.postgres` from
  `connection.url` in `dhis.conf`, adds `MONTHS_TO_KEEP`, moves old backups into the new layout, and turns an old `REMOTE=`
  into remote `remote1` (`keep`).
- **Create an instance from a backup** `[1.1.0]`: `dhis2-instance create` asks "Restore from a backup?" (a menu from
  `dhis2-backup list`, or a file) and which release it is from (2.38+); deploys that release, stops Tomcat, restores, starts it;
  encrypted backups ask for the password file (default `PASSWORD_FILE`); a matching file-store archive is offered; the admin
  login step is skipped. `--restore <file>`, `--restore-files yes|no`, `--backup-password-file <path>`.

## 11. Versions and releases of the tools

- **Semantic versioning** `MAJOR.MINOR.PATCH`: patch = fixes, minor = new features, major = something works differently. The
  flags and JSON output are the interface: changing or removing one means a major version; adding one, a minor.
- `0.x` milestones until `1.0.0` (breaking changes allowed): 0.1.0 = phases 0–3b, then one minor per tested phase (see
  `tasks.md`). `1.0.0` = phases 0–6 and 8, plus the docs rewrite. Phases 7 and 9, and whiptail prompts, follow in `1.x`.
- Release candidates `x.y.z-rc.N` go to the test server (`rc` channel) before each release.
- The version is in `VERSION` at the repo root (`x.y.z-dev` while being built; a test install shows `x.y.z-dev+<commit>`).
- `CHANGELOG.md`: an "Unreleased" section kept up in the same commits as the work (Added / Changed / Fixed / Security /
  Upgrade notes).
- **Branches**: work happens on `release/<x.y.z>` (now `release/0.1.0`), one version at a time until `1.0.0`; `master` holds
  released code only.
- **A release**: everything tested and approved → `tools/release.sh <version>` (in the repo, never on servers) checks the number,
  updates `VERSION` and `CHANGELOG.md`, commits and tags `v<version>` locally, and prints the push, `gh release create` and branch
  delete commands; `master` fast-forwards to the tested commit (with the user's yes); the user pushes and publishes the GitHub
  Release (release candidates as pre-releases). `RELEASING.md` describes it. `[0.1.0]`
- **Fixes**: only the newest release gets them (whether to also fix the previous major for a while is decided after `1.0.0`), on a `hotfix/<x.y.z>` branch started from its tag, tested, tagged, `master`
  fast-forwarded, merged into the current release branch.
- Finished `release/` and `hotfix/` branches are deleted; **tags are never deleted or moved**.
