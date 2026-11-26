#!/bin/bash
# deploy/config/postgres/init-db.sh — cree les bases et les utilisateurs separes.
# Execute par l'image postgres au PREMIER demarrage seulement (volume vide) : il ne rejoue
# jamais sur un volume existant. Changer un mot de passe ensuite = ALTER USER ... PASSWORD.
set -euo pipefail

: "${N8N_DB_PASSWORD:?N8N_DB_PASSWORD manquant (lu depuis .env par le compose)}"
: "${NOCODB_DB_PASSWORD:?NOCODB_DB_PASSWORD manquant (lu depuis .env par le compose)}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    CREATE USER n8n WITH ENCRYPTED PASSWORD '${N8N_DB_PASSWORD}';
    CREATE DATABASE n8n OWNER n8n;

    CREATE USER nocodb WITH ENCRYPTED PASSWORD '${NOCODB_DB_PASSWORD}';
    CREATE DATABASE nocodb OWNER nocodb;
EOSQL
