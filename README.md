# ivatar (Libravatar server) with docker-compose

Self-hosted [Libravatar](https://www.libravatar.org/) avatar service, running the
[ivatar](https://git.linux-kernel.at/oliver/ivatar) server software via docker-compose
on a Docker host, published as `https://avatars.example.com` through an Apache reverse
proxy running on a separate host. Replace `avatars.example.com`, `docker-host` and
`example.com` below with your own names.

Libravatar is API-compatible with Gravatar (`/avatar/<md5-or-sha256-of-email>?s=…&d=…`),
so clients like Grafana or WordPress can use it instead of gravatar.com.

## Architecture

```
Internet ──HTTPS──> proxy host: Apache (Let's Encrypt, avatars.example.com)
                     │  HTTP, X-Forwarded-Proto: https
                     v
                    docker-host:18080
                     └─ web (Caddy) ── /static/* served from shared volume
                          └─ ivatar (Django/gunicorn, port 8081)
                               ├─ postgres (PostgreSQL 17, data in /var/lib/ivatar/pgdata)
                               └─ memcached
```

| Service     | Image                                              | Purpose |
|-------------|----------------------------------------------------|---------|
| `postgres`  | `postgres:17`                                      | Database; also stores the uploaded avatar images |
| `memcached` | `memcached:1.6-alpine`                             | Cache (64 MB) |
| `ivatar`    | `registry.linux-kernel.at/oliver/ivatar:<commit>`  | The application (official image from the maintainer's GitLab CI) |
| `web`       | `caddy:2-alpine`                                   | Serves static files (Django doesn't with `DEBUG = False`) and proxies the rest to ivatar |

All containers use `restart: unless-stopped`; since the Docker daemon is enabled at boot,
the stack comes back up automatically after a reboot (unless it was stopped manually).
ivatar may fail once at boot if PostgreSQL isn't ready yet; Docker restarts it.

## Files

| File                 | Tracked | Purpose |
|----------------------|---------|---------|
| `docker-compose.yml` | yes     | Service definitions |
| `config_local.py`    | yes     | ivatar settings overrides, mounted to `/app/config_local.py` (loaded last by ivatar's `config.py`). Reads values from environment variables. |
| `Caddyfile`          | yes     | Caddy config. `trusted_proxies static private_ranges` is required so the `X-Forwarded-Proto: https` header from the reverse proxy reaches Django; otherwise Django treats requests as plain HTTP. |
| `.env`               | **no**  | Secrets and site-specific settings (keep `chmod 600`, never commit) |
| `update-ivatar.sh`   | yes     | Updates the pinned ivatar image to the newest `master` build (see below) |
| `backups/`           | **no**  | Database dumps written by `update-ivatar.sh` |

### `.env` variables

| Variable              | Meaning |
|-----------------------|---------|
| `IVATAR_HOSTNAME`     | Public host name (e.g. `avatars.example.com`). Used for `ALLOWED_HOSTS`, CSRF trusted origins, and the avatar base URLs. Requests with another `Host` header get HTTP 400. |
| `POSTGRES_PASSWORD`   | Password of DB user `ivatar`. Only used when the database directory is first initialised; changing it later requires `ALTER USER` in PostgreSQL too. |
| `SECRET_KEY`          | Django signing key (sessions, CSRF, password-reset/confirmation links). Must be random and stay stable; changing it logs everyone out. Generate with `python3 -c 'import secrets; print(secrets.token_urlsafe(50))'`. ivatar ships a public default key, so this must be set. |
| `DEFAULT_FROM_EMAIL`  | Sender address for confirmation/reset mails (also used as `SERVER_EMAIL`) |
| `EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`, `EMAIL_USE_TLS` | SMTP settings |
| `HTTP_PORT`           | Host port Caddy listens on (default `18080`) |
| `SITE_NAME`           | Optional; site name shown in the UI (default `libravatar`) |

Docker's `.env` format: one `KEY=value` per line, no spaces around `=`, **no quotes**
(they would become part of the value).

### Settings in `config_local.py` worth knowing

- `DEBUG = False` (ivatar's default is `True`).
- `DEFAULT_GRAVATARPROXY = False`, `DEFAULT_GRAVATARREDIRECT = False`: for unknown
  addresses ivatar would otherwise fetch from or redirect to gravatar.com. With these
  settings it never contacts Gravatar and returns the requested default image
  (`d=retro`, `identicon`, `404`, …) itself.
- Cache points to the `memcached` service.

## Operations

All commands run in the directory containing `docker-compose.yml`. They use the
standalone `docker-compose` (v1); with Compose v2 write `docker compose` instead.
The compose project name defaults to the directory name.

```sh
docker-compose up -d                 # start / apply changes to compose file or .env
docker-compose ps                    # status
docker-compose logs -f ivatar        # application logs
docker-compose restart ivatar        # after editing config_local.py
docker-compose restart web           # after editing Caddyfile
docker-compose down                  # stop (data is kept)
```

On every start the `ivatar` container copies its static files into the shared
`static` volume and runs the Django database migrations.

### Data locations

- `/var/lib/ivatar/pgdata` (bind mount): the PostgreSQL data directory with all accounts,
  email addresses and uploaded photos (photos are stored in the database). Create it before
  the first start (`sudo mkdir -p /var/lib/ivatar/pgdata`); the postgres container takes
  ownership (uid 999, which may show under some other user name on the host). Don't back it
  up by copying files while PostgreSQL runs; use `pg_dump` (see below).
- Docker volume `static`: CSS, JavaScript, fonts and default images copied from the image
  on every start. No user data; it can be deleted at any time.

To move an existing `pgdata` Docker volume to the host directory: `docker-compose stop
ivatar postgres`, copy it with `docker run --rm -v <project>_pgdata:/from -v
/var/lib/ivatar/pgdata:/to alpine cp -a /from/. /to/`, then `docker-compose up -d`.

### Upgrading ivatar

The image is pinned to a commit tag of the maintainer's registry; the `latest` tag there is
not kept current, and the registry also holds builds of the `devel` branch. Use
`update-ivatar.sh` to move to the build of the newest commit on ivatar's `master` branch:

```sh
./update-ivatar.sh --dry-run   # only report what would be done
./update-ivatar.sh
```

The script exits if already up to date or if no image exists yet for the newest `master`
commit. Otherwise it backs up the database to `./backups/`, switches the tag in
`docker-compose.yml`, pulls and restarts `ivatar`, and waits for the site to answer. On
success it commits the changed `docker-compose.yml`; on failure it switches back to the
previous tag and prints the command to restore the backup (needed only if the new version
had already migrated the database schema).

To run it weekly, e.g. via `crontab -e`:

```
30 4 * * 1  cd /path/to/this/directory && ./update-ivatar.sh >> backups/update.log 2>&1
```

The registry has a cleanup policy that deletes old tags, so a pinned tag may later become
unavailable for download; the locally pulled image keeps working.

### Backup and restore

Everything that matters, including the uploaded images, is in PostgreSQL:

```sh
docker-compose exec -T postgres pg_dump -U ivatar -Fc ivatar > ivatar-$(date +%F).dump
```

Restore into a running (empty or existing) database:

```sh
docker-compose exec -T postgres pg_restore -U ivatar -d ivatar --clean --if-exists < ivatar-YYYY-MM-DD.dump
docker-compose restart ivatar
```

Also keep a copy of `.env` (in particular `SECRET_KEY` and `POSTGRES_PASSWORD`) somewhere safe.

## Using the site

- **Create a user account:** `https://avatars.example.com/accounts/new/`
  (login: `/accounts/login/`). After logging in, add email addresses (each is confirmed
  via a mail link, so SMTP must work), upload a photo, and assign it to the addresses.
- **Django admin** (manage users, emails, photos):
  create a superuser once, then log in at `https://avatars.example.com/admin/`
  ```sh
  docker-compose exec ivatar python manage.py createsuperuser
  ```
- **Quick test** (should return a PNG):
  `https://avatars.example.com/avatar/$(echo -n you@example.com | md5sum | cut -d' ' -f1)?s=80&d=retro`

## Reverse proxy (Apache)

An Apache instance with Let's Encrypt certificates (managed by certbot) on another host
forwards to `docker-host:18080`. The host name `avatars.example.com` must resolve to the
proxy host (e.g. via a wildcard DNS entry). Required modules: `proxy`, `proxy_http`,
`headers`, `rewrite`, `ssl`.

`/etc/apache2/sites-available/008-ivatar.conf`:

```apache
<VirtualHost *:80>
    ServerName avatars.example.com
    ServerAdmin webmaster@example.com
    ProxyPass "/" "http://docker-host:18080/" nocanon
    ProxyPassReverse / http://docker-host:18080/
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    ErrorLog /var/log/apache2/ivatar-error.log
    CustomLog /var/log/apache2/ivatar-access.log common
    RewriteEngine on
    RewriteCond %{HTTP:X-Forwarded-Proto} !https
    RewriteCond %{HTTPS} off
    RewriteRule ^.*$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301,NE]
</VirtualHost>
```

Set up with `a2ensite 008-ivatar && systemctl reload apache2`, then
`certbot --apache -d avatars.example.com` (choose "no redirect", the vhost already
redirects), which generates `008-ivatar-le-ssl.conf` including the `RequestHeader` line.
Renewal is handled by certbot's cron job or systemd timer.

The `trusted_proxies static private_ranges` setting in the `Caddyfile` assumes the proxy
host reaches the Docker host via a private (RFC 1918) address; otherwise list its address
explicitly.

`ProxyPreserveHost On` is required (ivatar checks the `Host` header against
`IVATAR_HOSTNAME`), and so is `RequestHeader set X-Forwarded-Proto "https"` (together with
`trusted_proxies` in the `Caddyfile`), so that Django knows requests arrived via HTTPS.

## Clients

### Grafana

Grafana fetches avatars server-side from `[security] gravatar_url` (default
`https://secure.gravatar.com/avatar`). That setting exists from **Grafana 13.1** on;
Grafana 12.x has the Gravatar URL hard-coded.

```ini
[security]
disable_gravatar = false
gravatar_url = https://avatars.example.com/avatar
```

### WordPress

No maintained plugin is needed (the "Libravatar" plugin on wordpress.org is from 2011).
Add a filter, e.g. in a small must-use plugin:

```php
add_filter('get_avatar_url', fn($url) => str_replace(
    ['secure.gravatar.com', 'www.gravatar.com', '0.gravatar.com', '1.gravatar.com', '2.gravatar.com'],
    'avatars.example.com', $url));
```

### Federation (optional)

Other Libravatar clients look up the avatar server for an email domain via DNS SRV records.
To make addresses `@example.com` resolve to this server, add:

```
_avatars-sec._tcp.example.com. SRV 0 0 443 avatars.example.com.
```

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| HTTP 400 "Bad Request" | `Host` header doesn't match `IVATAR_HOSTNAME` (e.g. accessing `docker-host:18080` directly) |
| Generated links or redirects use `http://` | `X-Forwarded-Proto` missing in Apache or `trusted_proxies` missing in the `Caddyfile` |
| Page without styling | Static files not served; check the `web` container and the `static` volume |
| No confirmation mails | Check the `EMAIL_*` settings in `.env`, then `docker-compose logs ivatar` |

## Background / decisions

- **Why a dedicated PostgreSQL container instead of an existing MySQL server?** The Django
  framework ivatar uses requires at least MySQL 8.0.11 (Django 4.2), and the current
  Django release requires MySQL 8.4; older MySQL servers (e.g. 5.5) don't work. ivatar's
  image also lacks the `mysqlclient` driver, while PostgreSQL works out of the box.
- **Why not Gravatar?** Gravatar (Automattic) identifies users by unsalted hashes of their
  email addresses, which can be enumerated and used to link people across sites.
