# Pla de desplegament — OpenProject a Azure

**Estat:** Desplegat i verificat (2026-09-04). Web i worker `Healthy`, seed executat, email de prova via ACS enviat amb èxit.

## 1. Context
- App: OpenProject (Rails, aquest repo), per a ~20 usuaris.
- Subscripció: "Gencat DGIA Sandbox" (`40e1d617-d4f7-428d-a158-0b09105282ea`), tenant Generalitat de Catalunya.
- Restricció confirmada per l'usuari: **no es poden crear rols ni assignar permisos (RBAC)** en aquesta subscripció. Sense Key Vault amb accés per identitat. Per la resta, subscripció lliure.
- Terraform no instal·lat a la màquina local → s'utilitza **Bicep** (fallback explícitament autoritzat per l'usuari) desplegat via `az deployment group create`.
- Mode: MODIFY (infra nova + petit pegat de codi a l'app existent).

## 2. Resource Group
- Nom: `rg_openproject`
- Regió: `westeurope` (assumpció; es pot canviar si cal)

## 3. Arquitectura

| Component | Servei Azure | Notes |
|---|---|---|
| Compute web | Container App `web` | Consumption, 1 rèplica, ingress extern HTTPS, port 8080, health probe `/health_checks/default` |
| Compute worker | Container App `worker` | Consumption, 1 rèplica, sense ingress, `good_job` |
| Migració/seed | Container Apps Job `seeder` | Manual trigger, idempotent (`./docker/prod/seeder`), es llança un cop després de cada desplegament d'imatge |
| Base de dades | Azure Database for PostgreSQL Flexible Server | Burstable B1ms, PG 17, auth natiu usuari/contrasenya, firewall "Allow Azure services" |
| Adjunts | Storage Account + Azure Files (share) | Muntat com a volum a `/var/openproject/assets` a web+worker+seeder |
| Cache | Cap (file_store) | 1 sola rèplica de cada servei → no cal Redis/Memcached |
| Email | Azure Communication Services + Email Communication Service (domini gestionat per Azure `*.azurecomm.net`) | Via **REST API amb access key** (connection string), NO via SMTP (veure secció 6) |
| Registre de contenidors | Azure Container Registry (admin user habilitat) | Necessari per la imatge customitzada (secció 6); auth per usuari/contrasenya, sense RBAC |
| Secrets | Secrets natius de Container Apps | DB password, SECRET_KEY_BASE, ACS key com a secrets de la Container App (no Key Vault) |

## 4. Base d'imatge
- `openproject/openproject:17-slim` (Docker Hub, oficial) com a base.
- Comandaments oficials confirmats al `docker/prod/`: `web`, `worker`, `seeder` (idempotent: `db:structure:load`/`db:migrate` + `db:seed`).
- Variables clau (confirmades a `docker/prod/Dockerfile` i al `docker-compose.yml` oficial d'`opf/openproject-docker-compose`): `SECRET_KEY_BASE`, `DATABASE_URL`, `OPENPROJECT_HOST__NAME`, `OPENPROJECT_HTTPS`, `OPENPROJECT_RAILS__CACHE__STORE=file_store`, `RAILS_MIN_THREADS`/`RAILS_MAX_THREADS`.

## 5. Fora d'abast (v1)
- Hocuspocus (edició col·laborativa en temps real): desactivat.
- IMAP/cron (recepció de correu): desactivat (`IMAP_ENABLED=false`).
- Alta disponibilitat / múltiples rèpliques: no (20 usuaris).

## 6. PIVOT CRÍTIC — Email: SMTP d'ACS descartat, integració nativa necessària

Investigació feta contra la documentació oficial de Microsoft:
- El relay SMTP d'Azure Communication Services **requereix obligatòriament** una app d'Entra ID amb client secret **i una assignació de rol RBAC** (`Communication and Email Service Owner` o rol custom) sobre el recurs ACS. Això **no es pot fer en aquesta subscripció**.
- En canvi, l'**API REST d'ACS Email admet autenticació per access key/connection string** (com una storage account key), que **no requereix cap assignació RBAC** — només cal poder llegir la clau del recurs (`az communication list-key`), cosa que sí és possible.

**Conclusió:** cal implementar la integració nativa amb ACS que ja es va confirmar viable (patch localitzat, sense acoblament estructural a SMTP):
1. Classe Ruby que faci `deliver!(message)` cridant l'API REST d'ACS Email (HMAC-signat amb l'access key, o via una petita crida HTTP directa).
2. `ActionMailer::Base.add_delivery_method(:acs, ...)` en un initializer.
3. Branca `when :acs` a `app/models/setting/mail_settings.rb` si cal exposar config (endpoint/from-address) més enllà de variables d'entorn.
4. Aquest patch viu al codi de l'app → **cal una imatge Docker pròpia** (basada en `docker/prod/Dockerfile`, target `slim`) en lloc de la imatge pública. Es construirà amb `az acr build` (build al núvol, no cal Docker local) i es publicarà a un ACR amb admin user habilitat (sense RBAC).

## 7. Ordre d'execució
1. Patch Ruby (delivery method ACS) + test unitari mínim.
2. Bicep: RG, ACR (admin), Storage+Files, PostgreSQL Flexible Server, Communication Services + Email, Container Apps Environment, Container Apps (web, worker), Container Apps Job (seeder).
3. `az acr build` de la imatge amb el patch.
4. `az deployment group create` amb els Bicep.
5. Executar el job `seeder` un cop.
6. Verificar: HTTPS accessible, login, enviament d'un email de prova via ACS.

## 8. Sortides
- Bicep + scripts: `/home/ubuntu/dev/openproject/azure/`
- Aquest pla: `/home/ubuntu/dev/openproject/.azure/deployment-plan.md`
