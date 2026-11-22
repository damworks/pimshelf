#!/usr/bin/env bash
# Updates the application after `git pull`. Must be run on the server from the project directory.
# Usage: .docker/deploy.sh <STACK_NAME>      e.g. .docker/deploy.sh prod-pimshelf-from-scratch
set -euo pipefail

STACK_NAME="${1:?Usage: $0 <STACK_NAME>}"
PHP="${STACK_NAME}-php"
SUPERVISORD="${STACK_NAME}-supervisord"

if ! docker ps --format '{{.Names}}' | grep -qx "$PHP"; then
    echo "Error: container $PHP is not running. Did you deploy the stack in Portainer?" >&2
    exit 1
fi

if ! docker exec "$PHP" test -f composer.json; then
    echo "Error: /var/www/html in $PHP has no composer.json: APP_DIR of the stack does not point to the git clone (see README, troubleshooting)." >&2
    exit 1
fi

CONTAINER_UID="$(docker exec "$PHP" id -u)"
OWNER_UID="$(stat -c %u composer.json)"
if [ "$CONTAINER_UID" != "$OWNER_UID" ]; then
    echo "Error: $PHP runs as uid $CONTAINER_UID but the clone is owned by uid $OWNER_UID: set APP_UID/APP_GID of the stack to the clone owner and update the stack." >&2
    exit 1
fi

console() { docker exec "$PHP" php bin/console --no-interaction "$@"; }

echo ">> composer install"
docker exec "$PHP" composer install --no-dev --optimize-autoloader --no-interaction --no-progress

if ! console dbal:run-sql "SELECT 1 FROM settings_store LIMIT 1" >/dev/null 2>&1; then
    echo "Pimcore is not installed yet: run the first installation (see README), then deploy again." >&2
    exit 1
fi

echo ">> database migrations"
console doctrine:migrations:migrate --allow-no-migration

echo ">> rebuild data object classes from var/classes"
console pimcore:deployment:classes-rebuild --create-classes --delete-classes

echo ">> clear cache"
console cache:clear
console pimcore:cache:clear

echo ">> reload php-fpm (opcache) and restart supervisord (messenger workers)"
docker kill -s USR2 "$PHP" >/dev/null
docker restart "$SUPERVISORD" >/dev/null

echo ">> deployed revision $(git rev-parse --short HEAD) on $STACK_NAME"
