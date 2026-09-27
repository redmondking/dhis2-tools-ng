# Changelog

Changes to dhis2-tools, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
versions follow [semantic versioning](https://semver.org/): the commands' flags and JSON output are the interface.
Work in progress goes under "Unreleased" in the same commit as the change. How a version is released: `RELEASING.md`.

## [Unreleased]

### Added
- Install and update from GitHub: the tools live in `/opt/dhis2-tools`, the commands are `dhis2-*` links in `/usr/local/bin`.
  `dhis2-tools-update` updates them (`--check`, `--check --json`, `-y`, `--rollback` to the previous install, `--relink`).
- `dhis2-upgrade-setup`: brings a server set up with the original scripts up to date (see Upgrade notes).
- `dhis2-list-instances`: name, DHIS2 version, address, Tomcat, Java, IP, status, Glowroot, Munin (`--json`).
- DHIS2 releases from the official list: `-V` takes an exact release (2.38 or newer, e.g. `2.42.0`), every download is checked
  against its published sha256, and a failed check offers another try, another release or stopping.
- Own DHIS2 wars on create and deploy: `-f <file>`, `-l <url>`, `--sha256`, `--based-on <version>`.
- `dhis2-create-instance --no-deploy --line <version>`: create the instance now, deploy DHIS2 later.
- Glowroot and Munin are optional per instance (`-g`, `-m`).
- On every command that changes something: a summary before any change, `--dry-run`, and `-y` to ask nothing. Missing
  input is listed all at once with exit code 3. Passwords come from a prompt or, for automation, `--secrets-stdin`.
- `--json` on `dhis2-dbactivity`, `dhis2-logview` and `dhis2-list-instances`; `dhis2-logview` gets `--lines`.
- `dhis2-restoredb` and `dhis2-delete-instance` take `--postgres <container>`.

### Changed
- Ubuntu 24.04 for the proxy, postgres and monitor containers, with Ubuntu's own packages: PostgreSQL 16 with PostGIS 3,
  nginx and certbot from apt.
- Each instance's container follows its DHIS2 version: 2.42+ on Ubuntu 24.04 with Tomcat 10 and Java 17, 2.41 on 22.04 with
  Tomcat 9 and Java 17, 2.38–2.40 on 22.04 with Tomcat 9 and Java 11.
- `dhis2-ssl-setup` on nginx uses certbot's webroot: the proxy keeps running while certificates are issued and renewed.
  It asks whether to renew automatically (`--renew yes|no`) and `--dry-run` tests against Let's Encrypt's staging server.
- `dhis2-deploy-war` only offers releases of the instance's own DHIS2 version; going back to an older release needs `--force`.
- `dhis2-delete-instance` asks with No as the default.

### Fixed
- `dhis2-create-instance`: `-n` was ignored, `JAVA_HOME` was written as `java-{{ 17 }}-...`, the free-IP search needed
  gawk, and name checks matched prefixes.
- `dhis2-delete-instance`: needed two arguments, damaged `/etc/hosts`, and left the instance's `pg_hba.conf` line and
  postgres firewall rule behind.
- `dhis2-ssl-setup` wrote a renewal cron job to the host; a failed certbot run could leave the proxy broken (now the https
  configuration is only switched on once the certificate exists and passes `nginx -t`, otherwise the old one is put back).
- `dhis2-backup` reported success when a database dump or the remote copy failed.
- `dhis2-restoredb` reported success when a restore step failed; it now stops the instance's Tomcat during the restore.
- The sysctl settings were misspelt, appended on every run and never applied.
- The NAT rule assumed the network `192.168.0.0/24`; the rsyslog logger had the wrong subnet and a broken config.

### Security
- Glowroot and Munin pages need a login (shared or per instance for Glowroot; one for Munin); before, they were open.
- `dhis2-logview` no longer passes its search text through a root shell.
- `dhis2-delete-instance` refuses containers that aren't DHIS2 instances.
- `dhis2-ssl-setup` no longer requests a certificate without confirmation.

### Upgrade notes
- Servers set up with the original scripts: install the tools, then run `sudo dhis2-upgrade-setup --dry-run` to see what
  it would change, and `sudo dhis2-upgrade-setup` to apply it. It asks for the Munin and Glowroot logins
  (`--secrets-stdin` for automation) and asks at the end before restarting Tomcat (`--restart yes|no`).
- `--password-stdin` on `dhis2-glowroot-login` and `dhis2-munin-login` is replaced by `--secrets-stdin`.
- Existing containers stay on their Ubuntu and PostgreSQL versions.

[Unreleased]: https://github.com/redmondking/dhis2-tools-ng/compare/a37e7db...HEAD
