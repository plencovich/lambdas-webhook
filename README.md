# Botmaker Webhook Ingestion

Base serverless en Python para recibir webhooks de Botmaker y persistirlos en Aurora MySQL RDS con trazabilidad consistente.

El proyecto expone tres endpoints HTTP con AWS SAM y API Gateway:

- `POST /incoming`: mensajes entrantes del customer.
- `POST /outgoing`: mensajes salientes emitidos por operador o bot.
- `POST /status`: snapshots y cambios de estado de la conversacion.

El objetivo operativo es conservar cada webhook en crudo, normalizar las entidades principales de conversacion y mantener una base estable para auditoria, analitica y evolucion futura.

## Descripcion General

La aplicacion esta implementada como tres Lambdas independientes, una por endpoint, para desacoplar flujos que comparten infraestructura pero no necesariamente las mismas reglas de negocio. Todas reutilizan una base comun para:

- configuracion y variables de entorno
- logging estructurado
- parseo de eventos Lambda/API Gateway
- manejo de errores HTTP
- conexion a Aurora MySQL con PyMySQL
- persistencia transaccional e idempotente

La persistencia combina dos niveles:

- persistencia raw en `webhook_events_raw`
- persistencia normalizada en tablas de dominio como `customers`, `operators`, `conversations`, `messages`, `conversation_snapshots` y `conversation_contexts`

La fuente de verdad del modelo relacional es [`database/init_db.sql`](database/init_db.sql).

## Endpoints

| Endpoint | Handler | Evento procesado | Persistencia principal |
| --- | --- | --- | --- |
| `POST /incoming` | `handlers.incoming_handler.lambda_handler` | mensaje entrante de usuario/customer | `webhook_events_raw`, `customers`, `conversations`, `messages` |
| `POST /outgoing` | `handlers.outgoing_handler.lambda_handler` | mensaje saliente de operador o bot | `webhook_events_raw`, `customers`, `operators`, `conversations`, `messages` |
| `POST /status` | `handlers.status_handler.lambda_handler` | snapshot de estado conversacional y ultimo mensaje | `webhook_events_raw`, `customers`, `operators`, `conversations`, `messages`, `conversation_snapshots`, `conversation_contexts` |

Notas de alcance confirmadas en codigo:

- `/incoming` normaliza mensajes inbound y actualiza customer/conversation sin escribir snapshots ni contextos.
- `/outgoing` completa la linea de tiempo de mensajes salientes y crea o actualiza operador cuando corresponde.
- `/status` agrega historial append-only de snapshots y contexto dinamico, y tambien puede complementar el ultimo mensaje y el estado de entrega.

## Arquitectura

Arquitectura real implementada:

```text
API Gateway (regional)
-> Lambda handler
-> WebhookIngestionService
-> mapper especifico por endpoint
-> WebhookRepository
-> Aurora MySQL RDS
```

Piezas principales:

- `template.yaml`: define una API `AWS::Serverless::Api`, tres funciones `AWS::Serverless::Function`, un layer comun y configuracion opcional de VPC/security groups.
- `src/handlers/`: entrypoints Lambda por endpoint.
- `src/services/webhook_service.py`: orquesta parseo, mapeo, persistencia raw, reintentos y respuestas de negocio.
- `src/mappers/`: transforma payloads Botmaker en modelos internos.
- `src/repositories/webhook_repository.py`: ejecuta la persistencia normalizada e idempotente contra MySQL.
- `src/db/`: resuelve configuracion de base y conexion reutilizable con PyMySQL.
- `src/utils/`: configuracion, logging JSON, respuestas HTTP, parseo de payload y errores.
- `layer/requirements.txt`: dependencias compartidas del layer; hoy contiene `PyMySQL==1.1.2`.

## Flujo de Persistencia y Trazabilidad

Flujo comun confirmado en `WebhookIngestionService` y `WebhookRepository`:

1. La Lambda parsea el body JSON y arma un `WebhookEnvelope`.
2. El mapper del endpoint construye un modelo tipado con `external_event_key`.
3. Se inserta primero el payload completo en `webhook_events_raw`.
4. Si el raw ya existe con estado `processed`, la Lambda responde `duplicate_ignored`.
5. Si el raw ya existe con estado `failed`, se reintenta la normalizacion usando el mismo `raw_event_id`.
6. Si el raw es nuevo, se normalizan entidades en una transaccion MySQL.
7. El raw se marca `processed` o `failed` segun resultado.

Consideraciones implementadas hoy:

- La idempotencia existe en los tres endpoints.
- `/incoming` y `/outgoing` usan una clave a nivel mensaje.
- `/status` usa una clave hash estable que incluye proveedor, endpoint, conversacion, mensaje, estado y timestamp de cambio.
- La tabla `messages` actualiza `delivery_status` con una logica de progresion para no degradar estados posteriores como `read`.

## Estructura del Proyecto

```text
src/
  handlers/
  services/
  mappers/
  repositories/
  db/
  models/
  utils/
database/
  init_db.sql
  migrations/
  query_packs/
docs/
events/
layer/
tests/
  fixtures/
template.yaml
samconfig.toml
Dockerfile
docker-compose.yml
```

Referencias utiles del repo:

- [`database/init_db.sql`](database/init_db.sql): DDL inicial del esquema.
- [`database/migrations/`](database/migrations/): cambios incrementales orientados a capa analitica/Grafana.
- [`database/query_packs/`](database/query_packs/): consultas de validacion y reconciliacion.
- [`docs/persistence-traceability-matrix.md`](docs/persistence-traceability-matrix.md): matriz campo a campo entre fixtures, mappers, repository y DDL.
- [`docs/grafana-analytics-gap-analysis.md`](docs/grafana-analytics-gap-analysis.md): analisis de brechas para la capa analitica.
- [`docs/grafana-analytics-ddl-proposal.md`](docs/grafana-analytics-ddl-proposal.md): propuesta DDL complementaria para analitica.
- [`events/`](events/): eventos API Gateway listos para `sam local invoke`.

## Base de Datos

El proyecto persiste en Aurora MySQL RDS. La conexion se implementa en `src/db/connection.py` con cache de conexion por runtime Lambda y validacion de reuso mediante `ping(reconnect=False)`.

El archivo [`database/init_db.sql`](database/init_db.sql) es la referencia principal del modelo de datos. Hoy define al menos estas tablas:

- `webhook_events_raw`
- `customers`
- `operators`
- `conversations`
- `messages`
- `conversation_snapshots`
- `conversation_contexts`
- `conversation_metrics`

Estado actual de uso:

- Los endpoints escriben hoy en las primeras siete tablas de la lista.
- `conversation_metrics` existe en el DDL, pero la persistencia actual no la alimenta desde los webhooks.

## Fixtures Reales

El repositorio incluye payloads reales para desarrollo, regresion y validacion de mapping:

- [`tests/fixtures/incoming/`](tests/fixtures/incoming/): 26 fixtures de mensajes entrantes.
- [`tests/fixtures/outgoing/`](tests/fixtures/outgoing/): 13 fixtures de mensajes salientes.
- [`tests/fixtures/status/`](tests/fixtures/status/): 22 fixtures de snapshots y estados.

Estos fixtures se usan para:

- validar mappers contra datos reales
- probar regresiones de idempotencia
- levantar `sam local start-api` y enviar payloads reales con `curl`
- contrastar el comportamiento implementado con el DDL y la matriz de trazabilidad

## Variables de Entorno

Variables realmente consumidas por el codigo, definidas desde `template.yaml`:

| Variable | Uso |
| --- | --- |
| `APP_ENV` | ambiente de aplicacion |
| `ENVIRONMENT` | fallback de ambiente para compatibilidad con SAM |
| `LOG_LEVEL` | nivel de logging |
| `PROVIDER_NAME` | proveedor logico de eventos; por defecto `botmaker` |
| `DB_HOST` | host de Aurora/RDS |
| `DB_PORT` | puerto MySQL |
| `DB_NAME` | nombre de base |
| `DB_USER` | usuario de base |
| `DB_PASSWORD` | password de base |
| `DB_CONNECT_TIMEOUT_SECONDS` | timeout de conexion MySQL |

Notas:

- `APP_ENV` tiene prioridad sobre `ENVIRONMENT`.
- La conexion a base requiere `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` y `DB_PASSWORD`.
- `samconfig.toml` incluye configuracion default de build/deploy/local, pero no versiona `DbPassword`.

## Parametros SAM Relevantes

Ademas de las variables de entorno, `template.yaml` expone parametros de despliegue para infraestructura:

- `Environment`
- `LogLevel`
- `LambdaRoleName`
- `ManageLambdaVpcAccessPolicy`
- `DbHost`
- `DbPort`
- `DbName`
- `DbUser`
- `DbPassword`
- `LambdaSubnetIds`
- `LambdaSecurityGroupIds`
- `LambdaVpcId`
- `RdsSecurityGroupId1`
- `RdsSecurityGroupId2`

Si la Lambda necesita acceder a RDS dentro de subredes privadas, el template soporta VPC config y, opcionalmente, crear un security group administrado para la Lambda y reglas inbound hacia RDS.

## Ejecucion Local

Build del proyecto:

```bash
sam build
```

`samconfig.toml` deja configurado `use_container = true` para el build default. Ejecutar `sam build` antes de invocar o desplegar es importante porque el layer instala `PyMySQL` desde `layer/requirements.txt`.

Invocacion local de cada Lambda con eventos API Gateway del repo:

```bash
sam local invoke IncomingWebhookFunction --event events/incoming_event.json
sam local invoke OutgoingWebhookFunction --event events/outgoing_event.json
sam local invoke StatusWebhookFunction --event events/status_event.json
```

Levantar la API local:

```bash
sam local start-api
```

Luego se pueden enviar fixtures reales directamente al endpoint local:

```bash
curl -X POST http://127.0.0.1:3000/incoming \
  -H "Content-Type: application/json" \
  --data-binary @tests/fixtures/incoming/incoming-01.json

curl -X POST http://127.0.0.1:3000/outgoing \
  -H "Content-Type: application/json" \
  --data-binary @tests/fixtures/outgoing/outgoing-01.json

curl -X POST http://127.0.0.1:3000/status \
  -H "Content-Type: application/json" \
  --data-binary @tests/fixtures/status/status-13.json
```

Importante:

- Para validar persistencia end-to-end hace falta una base MySQL/Aurora accesible y las variables `DB_*` resueltas.
- Si solo se quiere validar mapping y contratos sin base, la suite de tests actual no necesita conectarse a RDS.

## Pruebas

Suite actual:

```bash
python -m unittest discover -s tests
```

Cobertura hoy:

- `tests/test_incoming_mapper.py`: mapeo e idempotencia de `/incoming` usando fixtures reales.
- `tests/test_outgoing_mapper.py`: mapeo e idempotencia de `/outgoing` usando fixtures reales.
- `tests/test_persistence_contract.py`: valida que los `INSERT` del repository esten alineados con las columnas declaradas en `database/init_db.sql`.

Observacion honesta sobre el estado actual:

- No hay un test unitario dedicado a `status_mapper` en `tests/`.
- La trazabilidad funcional de `/status` esta documentada en `docs/persistence-traceability-matrix.md` y soportada por fixtures reales bajo `tests/fixtures/status/`.

## Despliegue

Comandos confirmados en el repo:

```bash
sam deploy --guided
```

`samconfig.toml` define configuracion default para:

- `build`
- `validate`
- `deploy`
- `local_start_api`

El stack default es `botmaker-webhook-ingestion`. El template expone outputs para la URL base del API y para cada path:

- `WebhookApiUrl`
- `IncomingWebhookPath`
- `OutgoingWebhookPath`
- `StatusWebhookPath`

## Buenas Practicas para Seguir Desarrollando

- Reutilizar `src/utils/`, `src/db/` y `src/repositories/base.py` antes de agregar helpers nuevos.
- Mantener `database/init_db.sql` como fuente de verdad del esquema y contrastar cambios con `tests/test_persistence_contract.py`.
- No duplicar logica de parseo, respuesta HTTP o configuracion dentro de handlers.
- Tratar `tests/fixtures/` como insumo de regresion; si aparece un payload nuevo de Botmaker, agregar fixture antes de ajustar el mapper.
- Mantener el mismo criterio de idempotencia por endpoint al extender reglas de persistencia.
- Evitar que `/incoming` o `/outgoing` invadan responsabilidades de snapshots/contexto propias de `/status`.
- Si se agregan columnas o tablas nuevas para analitica, dejar claro si pasan a poblarse en tiempo de webhook o por procesos posteriores.

## Estado Actual

El proyecto ya tiene persistencia implementada para `incoming`, `outgoing` y `status` sobre el esquema base definido en `database/init_db.sql`. La base comun de configuracion, conexion, logging, errores y repositorios ya existe y es el punto correcto para extender el sistema sin romper consistencia entre endpoints.
