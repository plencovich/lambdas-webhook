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
3. Si el raw ya existe y esta `processed`, respuesta 200 con
   `duplicate_ignored`. Si existe en `failed`, se reintenta la normalizacion
   usando el mismo `raw_event_id`.
4. Normalizacion transaccional en tablas de dominio.
5. Marcado del raw como `processed`; si falla la normalizacion, se marca
   `failed` con `processing_error`.

Cuando `/status` complementa `messages.delivery_status`, conserva la progresion
de estado (`queued`/`sent` -> `delivered` -> `read` -> `failed`) para evitar que
un snapshot tardio degrade un mensaje ya marcado como leido.

Las variables dinamicas de negocio (`AP_*`, `Actividad*`, `IssueResuelto`,
`PreguntarAccionCompleta`, `RespuestaAccionCompleta`, `typeDate`, etc.) se
guardan en `conversation_contexts.context_json`. Las variables sensibles obvias
como `AP_MailTomador` y `AP_TipoDocumentoTomador` no se expanden en el contexto
normalizado; el raw conserva el payload completo.

## Endpoint `POST /incoming`

`/incoming` recibe eventos puntuales de mensaje entrante enviados por Botmaker.
A diferencia de `/status`, no representa un snapshot global de conversacion ni
de delivery status. El foco de normalizacion es el mensaje, manteniendo la
trazabilidad minima de customer y conversacion para que luego `/status` pueda
complementar metadata.

El payload completo se guarda primero en `webhook_events_raw` con
`PROVIDER_NAME=botmaker`, `source_endpoint=incoming` y
`event_type=incoming_message`. Si el raw ya existe, la Lambda responde 200 con
`duplicate_ignored` y no vuelve a insertar entidades normalizadas.

Mapeo principal confirmado contra `database/init_db.sql` y los fixtures reales:

- `message_external_id`: `_id_`.
- `conversation_external_id`: `sessionId`.
- `customer_external_id`: `customerId`.
- `contact_external_id`: `contactId`.
- `conversation_started_at`: `sessionCreationTime`.
- `message_at`: `date`.
- `channel`: `chatPlatform`.
- `business_channel_address`: `WHATSAPP_NUMBER`.
- `direction`: `inbound` cuando `from=user/customer` o `fromCustomer=true`.
- `sender_type`: `customer` para los mensajes actuales de usuario.
- `message_text`: `message`.
- `is_button` y `button_label`: `isButton` y `buttonName`.
- `queue_name` y `current_queue_name`: `queue`.

La clave de idempotencia se calcula a nivel mensaje como:

```text
incoming:v1:{provider_name}:message:{_id_}
```

Si en el futuro Botmaker enviara un evento sin `_id_`, el mapper genera un
fallback deterministico con `sessionId`, `customerId`, `date`, `contactId` y
contenido del mensaje. Ese fallback permite conservar idempotencia sin mezclar
eventos de `/incoming` con snapshots de `/status`.

Persistencia normalizada:

1. Insert idempotente del raw con estado `processing`.
2. Upsert de `customers`, conservando datos existentes cuando el payload trae
   nulos.
3. Upsert acotado de `conversations`: customer, canal, direccion de canal,
   inicio de conversacion, primer mensaje de usuario, ultimo mensaje y cola.
   No actualiza `status_current`, contexto, resolucion, pendientes ni flags de
   bot porque esos datos pertenecen al flujo `/status`.
4. Upsert de `messages` con el `_id_` del mensaje como clave externa.
5. Marcado del raw como `processed`; ante error de normalizacion queda `failed`
   con `processing_error`.

Fixtures reales del webhook entrante quedaron en `tests/fixtures/incoming`.

## Endpoint `POST /outgoing`

`/outgoing` recibe eventos puntuales de mensaje saliente enviados por Botmaker.
Completa la linea de tiempo que arman `/incoming` y `/status`: el primero
registra mensajes del usuario, `/outgoing` registra mensajes emitidos desde
Botmaker hacia el contacto, y `/status` agrega snapshots y estados posteriores.

El payload completo se guarda primero en `webhook_events_raw` con
`PROVIDER_NAME=botmaker`, `source_endpoint=outgoing` y
`event_type=outgoing_message`. Si el raw ya existe, la Lambda responde 200 con
`duplicate_ignored` y no vuelve a normalizar entidades.

Mapeo principal confirmado contra `database/init_db.sql` y los 13 fixtures
reales de `tests/fixtures/outgoing`:

- `message_external_id`: `_id_`.
- `conversation_external_id`: `sessionId`.
- `customer_external_id`: `customerId`.
- `contact_external_id`: `contactId`.
- `operator_external_id`: `operatorId` cuando `from=operator`.
- `operator_name`: `operatorName`, con fallback a `fromName`.
- `operator_email`: `operatorEmail`.
- `conversation_started_at`: `sessionCreationTime`.
- `message_at`: `date`.
- `channel`: `chatPlatform`.
- `business_channel_address`: `WHATSAPP_NUMBER`.
- `direction`: siempre `outbound` para este endpoint.
- `sender_type`: `operator` para los fixtures actuales. El mapper tambien
  acepta `bot` si Botmaker lo envia explicitamente.
- `message_text`: `message`.
- `queue_name` y `current_queue_name`: `queue`.
- Adjuntos: `audio` se guarda como `attachment_type=audio`; `file` se guarda
  como `attachment_type=file`.

Los fixtures actuales muestran solo mensajes salientes de operador humano. No
hay fixtures reales con `from=bot` en `/outgoing`; el mapper lo soporta de forma
tolerante sin crear operador.

La clave de idempotencia se calcula a nivel mensaje como:

```text
outgoing:v1:{provider_name}:message:{_id_}
```

Si Botmaker enviara un evento sin `_id_`, el mapper genera un fallback
deterministico con `sessionId`, `customerId`, `date`, `from`, `operatorId`,
contenido del mensaje y adjunto. En los fixtures reales `outgoing-05.json` y
`outgoing-06.json` tienen el mismo `_id_`, por lo que se resuelven como el mismo
evento idempotente.

Persistencia normalizada:

1. Insert idempotente del raw con estado `processing`.
2. Upsert de `customers`, conservando datos existentes cuando el payload no
   trae informacion mas completa.
3. Upsert de `operators` solo cuando el sender es operador y existe identificador
   o metadata suficiente.
4. Upsert acotado de `conversations`: customer, canal, direccion de canal,
   inicio de conversacion, primera respuesta bot/humana segun `sender_type`,
   ultimo mensaje, ultima cola y ultimo autor cuando aplica. No actualiza
   `status_current`, contexto, resolucion, pendientes ni flags de bot.
5. Upsert de `messages` con `_id_` como clave externa, `direction=outbound` y
   `operator_id` asociado cuando corresponde.
6. Marcado del raw como `processed`; ante error de normalizacion queda `failed`
   con `processing_error`.

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
  --data-binary @tests/fixtures/incoming/incoming-01.json
```

Ejemplo con `/status` usando un fixture real:

```bash
curl -X POST http://127.0.0.1:3000/status \
  -H "Content-Type: application/json" \
  --data-binary @tests/fixtures/status/status-13.json
```

Ejemplo con `/incoming` usando otro fixture real:

```bash
curl -X POST http://127.0.0.1:3000/incoming \
  -H "Content-Type: application/json" \
  --data-binary @tests/fixtures/incoming/incoming-02.json
```

Ejemplo con `/outgoing` usando un fixture real:

```bash
curl -X POST http://127.0.0.1:3000/outgoing \
  -H "Content-Type: application/json" \
  --data-binary @tests/fixtures/outgoing/outgoing-01.json
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
sam build

sam deploy --parameter-overrides \
  --template-file .aws-sam/build/template.yaml \
  Environment=dev \
  LogLevel=INFO \
  DbHost=mecubrochatdev-dc1f5878.ct5618n6bomg.us-east-1.rds.amazonaws.com \
  DbPort=3306 \
  DbName=mecubrochatdev \
  DbUser=admin \
  DbPassword='--------------' \
  LambdaSubnetIds='subnet-0227e23f3483b5066,subnet-0e2ef6f846e56d35e,subnet-00e22d5c6f0406810' \
  LambdaSecurityGroupIds='sg-0f7dcb59deaf75f34'
```

Si RDS esta en subnets privadas, pasar `LambdaSubnetIds` con subnets privadas
de la misma VPC de RDS. Con `LambdaVpcId`, el stack crea un security group para
las Lambdas. Con `RdsSecurityGroupId1` y opcionalmente `RdsSecurityGroupId2`, el
stack agrega reglas inbound MySQL/Aurora `TCP 3306` desde el security group de
Lambda hacia los security groups de RDS.

Para usar un security group de Lambda ya existente, pasar `LambdaSecurityGroupIds`
en lugar de `LambdaVpcId`. En ese caso, configurar manualmente el inbound de RDS.

Ejecutar `sam build` antes de `sam deploy` es necesario para que SAM instale las
dependencias de `layer/requirements.txt` dentro del Lambda Layer. Si se despliega
sin build, el layer sube solo con el archivo `requirements.txt` y la funcion falla
con `ModuleNotFoundError` para `pymysql`.

## Estado actual

`/status`, `/incoming` y `/outgoing` implementan persistencia real e
idempotente contra el DDL de `database/init_db.sql`. `/outgoing` normaliza raw,
customer, operator, conversation y message sin invadir las tablas de snapshot y
contexto propias de `/status`.
