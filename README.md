# Botmaker Webhook Ingestion

Base serverless en Python con AWS SAM para recibir webhooks de Botmaker y
persistirlos en AWS RDS MySQL.

## Arquitectura

El proyecto usa una arquitectura en capas simple para procesamiento tipo ETL:

```text
API Gateway
-> Lambda handler
-> service
-> mapper
-> repository
-> RDS MySQL
```

La estructura evita una arquitectura hexagonal completa y mantiene separadas las
responsabilidades principales:

```text
src/
  handlers/       Entrypoints Lambda por endpoint
  services/       Orquestacion del flujo de ingesta
  mappers/        Transformacion inicial de eventos
  repositories/   Acceso futuro a RDS y base comun de persistencia
  db/             Configuracion y conexion reutilizable
  models/         Tipos simples del dominio tecnico
  utils/          Config, logging, errores, HTTP y parsing
layer/
  requirements.txt
events/
tests/
database/
template.yaml
samconfig.toml
```

## Endpoints

El template SAM define tres funciones Lambda separadas, expuestas por API
Gateway:

- `POST /incoming`
- `POST /outgoing`
- `POST /status`

Se eligio una Lambda por endpoint para mantener bajo acoplamiento entre flujos
que pueden evolucionar con reglas, permisos, metricas y errores distintos. La
logica compartida queda centralizada en services, mappers, repositories y utils.

## Endpoint `POST /status`

`/status` recibe snapshots de estado de conversacion/contacto enviados por
Botmaker. No se modela solo como delivery status de un mensaje: el payload se
guarda completo en `webhook_events_raw` y luego se normaliza hacia:

- `customers`
- `operators`
- `conversations`
- `messages`
- `conversation_snapshots`
- `conversation_contexts`

El mapeo usa `PROVIDER_NAME=botmaker`, `source_endpoint=status` y
`event_type=message_status_snapshot`.

Decisiones de identificacion usadas para los payloads reales recibidos:

- `customer_external_id`: top-level `_id_`, con fallback a
  `LAST_MESSAGE.customerId`.
- `conversation_external_id`: `LAST_MESSAGE.sessionId`. Si Botmaker envia un
  snapshot sin `LAST_MESSAGE`, se usa `conversationId`/`sessionId` si existe y,
  como ultimo fallback, el customer id para no perder raw/contexto.
- `contact_external_id`: `PLATFORM_CONTACT_ID` o `LAST_MESSAGE.contactId`.
- `conversation_started_at`: `LAST_MESSAGE.sessionCreationTime`, con fallback a
  `CREATION_TIME`.
- `snapshot_at`: `STATUS_CHANGE_TIME`, con fallback a `LAST_MESSAGE.date`.

La clave de idempotencia `external_event_key` se calcula con hash estable de:
proveedor, endpoint, conversacion, ultimo mensaje, `STATUS`,
`STATUS_CHANGE_TIME`/`snapshot_at` y customer. Esto permite persistir como
eventos distintos `delivered` y `read` para el mismo mensaje, pero ignorar el
mismo snapshot repetido.

La persistencia sigue este flujo:

1. Parseo y validacion basica del body JSON.
2. Insert idempotente en `webhook_events_raw` con estado `processing`.
3. Si el raw ya existe, respuesta 200 con `duplicate_ignored`.
4. Normalizacion transaccional en tablas de dominio.
5. Marcado del raw como `processed`; si falla la normalizacion, se marca
   `failed` con `processing_error`.

Las variables dinamicas de negocio (`AP_*`, `Actividad*`, `IssueResuelto`,
`PreguntarAccionCompleta`, `RespuestaAccionCompleta`, `typeDate`, etc.) se
guardan en `conversation_contexts.context_json`. Las variables sensibles obvias
como `AP_MailTomador` y `AP_TipoDocumentoTomador` no se expanden en el contexto
normalizado; el raw conserva el payload completo.

## Dependencias

Las dependencias compartidas viven en `layer/requirements.txt`. Por ahora solo
incluye `PyMySQL`, porque las tres Lambdas van a compartir la misma conexion a
RDS. AWS SAM construye el layer con `BuildMethod: python3.13`.

## Variables de entorno

Las funciones esperan estas variables, definidas desde `template.yaml`:

- `APP_ENV`
- `ENVIRONMENT`
- `LOG_LEVEL`
- `PROVIDER_NAME`
- `DB_HOST`
- `DB_PORT`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`
- `DB_CONNECT_TIMEOUT_SECONDS`

No hay credenciales hardcodeadas. Para despliegues reales, pasar los parametros
de base de datos con `sam deploy --parameter-overrides` o mediante el pipeline.

`APP_ENV` es la variable principal para el ambiente de aplicacion. `ENVIRONMENT`
queda disponible por compatibilidad con el parametro `Environment` de SAM.

## Modulos comunes

La configuracion tecnica compartida queda centralizada en estos modulos:

- `src/utils/config.py`: resuelve y valida variables de entorno. Expone
  `get_app_config()` y `get_database_config()`.
- `src/db/connection.py`: crea y reutiliza una conexion PyMySQL a Aurora MySQL.
  Valida que la conexion cacheada siga viva antes de reutilizarla y expone
  helpers para cursor y transacciones.
- `src/utils/log.py`: configura logging JSON estructurado para CloudWatch, con
  `get_logger()` y `log_exception()`.
- `src/utils/exceptions.py`: define excepciones base del proyecto para errores
  de configuracion, validacion, base de datos y procesamiento.
- `src/utils/http.py`: estandariza respuestas Lambda/API Gateway de exito y
  error.
- `src/repositories/base.py`: ofrece una base reutilizable para queries
  parametrizadas, inserts simples y transacciones.
- `src/utils/events.py`: contiene helpers compartidos para datos comunes del
  evento Lambda, como `request_id`.

Las futuras lambdas no deberian leer variables de entorno, crear conexiones ni
armar respuestas HTTP por su cuenta. Esas responsabilidades deben pasar por los
modulos comunes.

## Conexion a Aurora RDS

La conexion usa `PyMySQL`, incluido en el Lambda Layer. La funcion
`get_connection()` mantiene una conexion cacheada a nivel de modulo para
aprovechar la reutilizacion del runtime de Lambda entre invocaciones. Antes de
devolver la conexion cacheada ejecuta `ping(reconnect=False)`; si ya no sirve,
la descarta y crea una nueva.

Para operaciones que requieran multiples escrituras, usar la base transaccional
desde repositories:

```python
from repositories.base import BaseRepository


class ExampleRepository(BaseRepository):
    def save_many(self, rows):
        with self.transaction() as connection:
            with connection.cursor() as cursor:
                for row in rows:
                    cursor.execute(
                        "INSERT INTO example_table (name) VALUES (%s)",
                        (row["name"],),
                    )
```

Para operaciones simples se puede usar `execute()`, `fetch_one()`, `fetch_all()`
o `insert_one()` desde `BaseRepository`.

## Build

```bash
sam build
```

## Ejecucion local

Invocar una funcion con un evento de ejemplo:

```bash
sam local invoke IncomingWebhookFunction --event events/incoming_event.json
sam local invoke OutgoingWebhookFunction --event events/outgoing_event.json
sam local invoke StatusWebhookFunction --event events/status_event.json
```

Levantar API Gateway local:

```bash
sam local start-api
```

Luego probar:

```bash
curl -X POST http://127.0.0.1:3000/incoming \
  -H "Content-Type: application/json" \
  -d '{"type":"incoming_message","eventId":"local-001"}'
```

Ejemplo con `/status` usando un fixture real:

```bash
curl -X POST http://127.0.0.1:3000/status \
  -H "Content-Type: application/json" \
  --data-binary @tests/fixtures/status/response-13.json
```

Para ejecutar tests unitarios:

```bash
python -m unittest discover -s tests
```

## Deploy

Primer despliegue guiado:

```bash
sam deploy --guided
```

Despliegue no interactivo de ejemplo:

```bash
sam deploy \
  --parameter-overrides \
    Environment=dev \
    LogLevel=INFO \
    DbHost=example.cluster-xxxxx.us-east-1.rds.amazonaws.com \
    DbPort=3306 \
    DbName=botmaker \
    DbUser=app_user \
    DbPassword='change-me'
```

Si RDS esta en subnets privadas, agregar `VpcConfig` a las funciones con los
subnets y security groups correspondientes antes del despliegue productivo.

## Estado actual

`/status` ya implementa persistencia real e idempotente contra el DDL de
`database/init_db.sql`. `/incoming` y `/outgoing` conservan el flujo base y
persisten raw events con la misma capa comun, listos para sumar normalizacion
especifica por endpoint.
