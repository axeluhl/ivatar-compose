#!/bin/sh
# Update the ivatar image to the build of the latest commit on ivatar's master branch.
# Usage: ./update-ivatar.sh [--dry-run]
set -eu
cd "$(dirname "$0")"

API=https://git.linux-kernel.at/api/v4/projects/oliver%2Fivatar
REGISTRY_REPO_ID=64
IMAGE=registry.linux-kernel.at/oliver/ivatar
BACKUP_DIR=${BACKUP_DIR:-./backups}
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

current=$(sed -n "s|^ *image: $IMAGE:\(.*\)$|\1|p" docker-compose.yml)
latest=$(curl -fsS "$API/repository/commits?ref_name=master&per_page=1" | json 'd[0]["short_id"]')

if [ "$current" = "$latest" ]; then
    echo "ivatar is up to date ($current)"
    exit 0
fi
if ! curl -fsS -o /dev/null "$API/registry/repositories/$REGISTRY_REPO_ID/tags/$latest"; then
    echo "master is at $latest, but no image has been built for it yet; try again later"
    exit 0
fi
echo "updating ivatar: $current -> $latest"
$DRY_RUN && exit 0

mkdir -p "$BACKUP_DIR"
backup="$BACKUP_DIR/ivatar-$(date +%F-%H%M)-before-$latest.dump"
umask 077; docker-compose exec -T postgres pg_dump -U ivatar -Fc ivatar > "$backup"
echo "database backed up to $backup"

sed -i "s|image: $IMAGE:$current|image: $IMAGE:$latest|" docker-compose.yml
docker-compose pull -q ivatar
docker-compose up -d ivatar

host=$(sed -n 's/^IVATAR_HOSTNAME=//p' .env)
port=$(sed -n 's/^HTTP_PORT=//p' .env); port=${port:-18080}
for i in $(seq 1 30); do
    sleep 5
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" "http://localhost:$port/") || true
    if [ "$code" = 200 ]; then
        git add docker-compose.yml
        git commit -q -m "update ivatar image to $latest" docker-compose.yml
        echo "ivatar $latest is up and committed"
        exit 0
    fi
done

echo "ivatar $latest did not come up (last HTTP status: $code); rolling back to $current" >&2
sed -i "s|image: $IMAGE:$latest|image: $IMAGE:$current|" docker-compose.yml
docker-compose up -d ivatar
echo "If the new version changed the database schema, restore it with:" >&2
echo "  docker-compose exec -T postgres pg_restore -U ivatar -d ivatar --clean --if-exists < $backup" >&2
exit 1
