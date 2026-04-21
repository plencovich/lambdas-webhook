# Persistence Traceability Matrix

Documento vivo de trazabilidad funcional y tecnica para las lambdas `POST /incoming`, `POST /outgoing` y `POST /status`.

Fuentes usadas:

- DDL: `database/init_db.sql`.
- Fixtures reales: `tests/fixtures/incoming`, `tests/fixtures/outgoing`, `tests/fixtures/status`.
- Codigo: `src/handlers`, `src/services`, `src/mappers`, `src/repositories`, `src/db`, `src/utils`, `template.yaml`.

## DDL operativo

Tablas usadas hoy por los endpoints:

- `webhook_events_raw`: auditoria raw e idempotencia global por `(provider_name, external_event_key)`.
- `customers`: identidad del contacto/customer por `(provider_name, customer_external_id)`.
- `operators`: operadores humanos por `(provider_name, operator_external_id)`.
- `conversations`: estado agregado actual de conversacion por `(provider_name, conversation_external_id)`.
- `messages`: mensajes normalizados por `(provider_name, message_external_id)`.
- `conversation_snapshots`: historial append-only de snapshots de `/status`.
- `conversation_contexts`: historial append-only de contexto dinamico/promovido de `/status`.

Tabla definida pero no alimentada hoy:

- `conversation_metrics`: requiere agregaciones derivadas; ningun fixture trae metricas listas ni el codigo actual calcula agregados.

## Matriz Campo A Campo

Estado actual:

- Correcto: el campo esta alineado con DDL, mapper y repository.
- Parcial: se persiste parte de la informacion o depende de otro endpoint.
- Raw only: se conserva completo en `webhook_events_raw.raw_payload_json`.
- Context: se conserva en `conversation_contexts.context_json`.
- Ignorado: decision explicita de no promover.

### /incoming

Fixtures base: `incoming-01.json` a `incoming-26.json`. Todos los fixtures tienen `sessionId`, `customerId`, `contactId`, `chatPlatform`, `date`, `from`, `fromCustomer`, `_id_`, `queue`, `WHATSAPP_NUMBER`, `sessionCreationTime`, `operatorId`. Hay botones en `incoming-02/03/04` y audios duplicados en `incoming-24/25`.

| Endpoint | Fixture / Ejemplo | Campo payload | Ubicacion | Descripcion funcional | Modelo interno / Mapper | Tabla destino | Columna destino | Regla de persistencia | Justificacion | Estado actual | Accion recomendada | Riesgo |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| incoming | incoming-01.json | `_id_` | top-level | Identificador externo del mensaje entrante | `message.message_external_id`, `message_external_id`, `external_event_key` | `messages`; `webhook_events_raw` | `message_external_id`; `external_event_key` | Upsert mensaje; insert raw idempotente | Es la clave fuerte del evento y del mensaje | Correcto | Mantener | Alto |
| incoming | incoming-01.json | `sessionId` | top-level | Identificador externo de conversacion/sesion | `conversation_external_id`, `conversation.conversation_external_id` | `conversations`; `webhook_events_raw` | `conversation_external_id` | Upsert conversacion; raw audit | Une mensajes, snapshots y customer | Correcto | Mantener | Alto |
| incoming | incoming-01.json | `customerId` | top-level | Identificador externo del customer en Botmaker | `customer_external_id`, `customer.customer_external_id` | `customers`; `messages`; `webhook_events_raw` | `customer_external_id`; FK via `customer_id` | Upsert customer; FK en message/conversation | Fuente real de customer para mensajes | Correcto | Mantener | Alto |
| incoming | incoming-01.json | `contactId` | top-level | Identificador/contacto de plataforma | `customer.contact_external_id` | `customers` | `contact_external_id` | Upsert, `COALESCE` para no pisar con null | Permite trazabilidad por telefono/contacto | Correcto | Mantener | Medio |
| incoming | incoming-01.json | `chatPlatform` | top-level | Canal conversacional | `customer.channel`, `conversation.channel` | `customers`; `conversations` | `channel` | Upsert, valor requerido | DDL exige `channel NOT NULL` | Correcto | Mantener | Alto |
| incoming | incoming-01.json | `WHATSAPP_NUMBER` | top-level | Direccion del canal de negocio | `business_channel_address` | `customers`; `conversations` | `business_channel_address` | Upsert, `COALESCE` | Identifica numero emisor de negocio | Correcto | Mantener | Medio |
| incoming | incoming-01.json | `sessionCreationTime` | top-level | Inicio de la sesion/conversacion | `conversation.conversation_started_at` | `conversations` | `conversation_started_at` | Upsert `LEAST`, preserva inicio mas antiguo | No debe moverse hacia adelante por reintentos | Correcto | Mantener | Medio |
| incoming | incoming-01.json | `date` | top-level | Timestamp del mensaje | `message.message_at`, `first_user_message_at`, `last_message_at` | `messages`; `conversations` | `message_at`; `first_user_message_at`; `last_message_at` | Insert/upsert mensaje; `LEAST` para first; `GREATEST` para last | Base temporal de timeline | Correcto | Mantener | Alto |
| incoming | incoming-01.json | `from` | top-level | Emisor declarado por Botmaker | `sender_type` via mapper | `messages`; `conversations` | `sender_type`; `last_message_sender_type` | Normaliza `user/customer` a `customer`; update last si mensaje mas nuevo | Homogeneiza sender entre endpoints | Correcto | Mantener | Alto |
| incoming | incoming-01.json | `fromCustomer` | top-level | Flag de customer | `message.is_customer_message` | `messages` | `is_customer_message` | Upsert con `GREATEST` | Refuerza clasificacion inbound/customer | Correcto | Mantener | Medio |
| incoming | incoming-01.json | `fromName` | top-level | Nombre visible del customer | `customer_first_name`, `customer_last_name`, `message.sender_name` | `customers`; `messages` | `customer_first_name`; `customer_last_name`; `sender_name` | Split simple; upsert `COALESCE` | En incoming es la unica fuente de nombre de customer | Correcto | Mantener | Medio |
| incoming | incoming-01.json | `message` | top-level | Texto entrante | `message.message_text` | `messages` | `message_text` | Upsert `COALESCE` | Texto de conversacion para analitica | Correcto | Mantener | Alto |
| incoming | incoming-02.json | `isButton` | top-level | Indica seleccion de boton | `message.is_button` | `messages` | `is_button` | Upsert con `GREATEST` | Evita perder que fue boton ante reintentos parciales | Correcto | Mantener | Medio |
| incoming | incoming-02.json | `buttonName` | top-level | Etiqueta del boton elegido | `message.button_label`, fallback `message_text` | `messages` | `button_label`; `message_text` | Upsert `COALESCE` | Si no hay `message`, la etiqueta es contenido util | Correcto | Mantener | Medio |
| incoming | incoming-24.json | `hasAttachment` | top-level | Flag de adjunto | `message.has_attachment` | `messages` | `has_attachment` | Upsert con `GREATEST` | Marca adjuntos aunque falte URL | Correcto | Mantener | Medio |
| incoming | incoming-24.json | `audio` | top-level | URL de audio del usuario | `message.attachment_url`, `attachment_type=audio` | `messages` | `attachment_url`; `attachment_type` | Upsert `COALESCE` | Adjunto consultable sin parsear raw | Correcto | Mantener | Medio |
| incoming | incoming-01.json | `operatorId` | top-level | Operador asociado, nulo en fixtures incoming | `client_payload.incoming_message.operatorId` | `messages` | `client_payload` | Raw/client payload only | No corresponde crear operator para mensaje customer con `operatorId=null` | Correcto | Mantener | Bajo |
| incoming | incoming-01.json | Payload completo | top-level object | Evidencia completa del webhook | `raw_payload` | `webhook_events_raw` | `raw_payload_json` | Insert idempotente | Auditoria y recuperacion de campos no promovidos | Correcto | Mantener | Critico |

### /outgoing

Fixtures base: `outgoing-01.json` a `outgoing-13.json`. Todos los fixtures son `from=operator`; no hay fixture real de bot en `/outgoing`. Hay archivo en `outgoing-07`, audio en `outgoing-13` y duplicado real de mensaje en `outgoing-05/06`.

| Endpoint | Fixture / Ejemplo | Campo payload | Ubicacion | Descripcion funcional | Modelo interno / Mapper | Tabla destino | Columna destino | Regla de persistencia | Justificacion | Estado actual | Accion recomendada | Riesgo |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| outgoing | outgoing-01.json | `_id_` | top-level | Identificador externo del mensaje saliente | `message.message_external_id`, `message_external_id`, `external_event_key` | `messages`; `webhook_events_raw` | `message_external_id`; `external_event_key` | Upsert mensaje; insert raw idempotente | Clave fuerte a nivel mensaje | Correcto | Mantener | Alto |
| outgoing | outgoing-01.json | `sessionId` | top-level | Conversacion/sesion | `conversation_external_id` | `conversations`; `webhook_events_raw` | `conversation_external_id` | Upsert conversacion; raw audit | Une outgoing con incoming/status | Correcto | Mantener | Alto |
| outgoing | outgoing-01.json | `customerId` | top-level | Customer externo | `customer_external_id` | `customers`; `messages`; `conversations`; `webhook_events_raw` | `customer_external_id`; FK via `customer_id` | Upsert customer; FK | Necesario para FK de conversacion y mensaje | Correcto | Mantener | Alto |
| outgoing | outgoing-01.json | `contactId` | top-level | Contacto de plataforma | `customer.contact_external_id` | `customers` | `contact_external_id` | Upsert `COALESCE` | Complementa identidad de contacto | Correcto | Mantener | Medio |
| outgoing | outgoing-01.json | `chatPlatform` | top-level | Canal | `customer.channel`, `conversation.channel` | `customers`; `conversations` | `channel` | Upsert | DDL requiere canal | Correcto | Mantener | Alto |
| outgoing | outgoing-01.json | `WHATSAPP_NUMBER` | top-level | Direccion del canal negocio | `business_channel_address` | `customers`; `conversations` | `business_channel_address` | Upsert `COALESCE` | Trazabilidad de numero negocio | Correcto | Mantener | Medio |
| outgoing | outgoing-01.json | `sessionCreationTime` | top-level | Inicio de conversacion | `conversation_started_at` | `conversations` | `conversation_started_at` | Upsert `LEAST` | Preserva inicio real | Correcto | Mantener | Medio |
| outgoing | outgoing-01.json | `date` | top-level | Timestamp del mensaje | `message.message_at`, `first_human_response_at`, `last_message_at` | `messages`; `conversations` | `message_at`; `first_human_response_at`; `first_bot_response_at`; `last_message_at` | First response `LEAST`; last `GREATEST` | Mide primera respuesta y timeline | Correcto | Mantener | Alto |
| outgoing | outgoing-01.json | `from` | top-level | Tipo de emisor | `sender_type`, `direction=outbound` | `messages`; `conversations` | `sender_type`; `direction`; `last_message_sender_type` | Normaliza `operator`/`bot`; update last si mas nuevo | Diferencia humano/bot | Correcto | Mantener | Alto |
| outgoing | outgoing-01.json | `fromName` | top-level | Nombre visible del emisor | `sender_name`, fallback operator name | `messages`; `operators` | `sender_name`; `operator_name` | Upsert `COALESCE` | Completa operador si faltan campos dedicados | Correcto | Mantener | Medio |
| outgoing | outgoing-01.json | `operatorId` | top-level | Identificador externo del operador | `operator.operator_external_id`, `last_action_author_external_id` | `operators`; `messages`; `conversations` | `operator_external_id`; FK `operator_id`; `last_action_author_external_id` | Upsert operator si `sender_type=operator`; FK en message | Fuente principal de operador humano | Correcto | Mantener | Alto |
| outgoing | outgoing-01.json | `operatorName` | top-level | Nombre operador | `operator.operator_name` | `operators` | `operator_name` | Upsert `COALESCE` | Metadata estable del operador | Correcto | Mantener | Medio |
| outgoing | outgoing-01.json | `operatorEmail` | top-level | Email operador | `operator.operator_email` | `operators` | `operator_email` | Upsert `COALESCE` | Identificacion y deduplicacion secundaria | Correcto | Mantener | Medio |
| outgoing | outgoing-01.json | `queue` | top-level | Cola actual | `message.queue_name`, `conversation.current_queue_name` | `messages`; `conversations` | `queue_name`; `current_queue_name` | Message upsert; conversation update si ultimo mensaje | Cola de atencion del ultimo evento | Correcto | Mantener | Medio |
| outgoing | outgoing-01.json | `message` | top-level | Texto saliente | `message.message_text` | `messages` | `message_text` | Upsert `COALESCE` | Texto para timeline y analitica | Correcto | Mantener | Alto |
| outgoing | outgoing-07.json | `file` | top-level | URL de archivo enviado por operador | `attachment_url`, `attachment_type=file` | `messages` | `attachment_url`; `attachment_type` | Upsert `COALESCE` | Archivo debe quedar consultable normalizado | Correcto | Mantener | Medio |
| outgoing | outgoing-13.json | `audio` | top-level | URL de audio de operador | `attachment_url`, `attachment_type=audio` | `messages` | `attachment_url`; `attachment_type` | Upsert `COALESCE` | Audio debe quedar consultable normalizado | Correcto | Mantener | Medio |
| outgoing | outgoing-07.json | `hasAttachment` | top-level | Flag adjunto | `message.has_attachment` | `messages` | `has_attachment` | Upsert `GREATEST` | Conserva indicacion de adjunto | Correcto | Mantener | Medio |
| outgoing | outgoing-01.json | Payload completo | top-level object | Evidencia completa | `raw_payload` | `webhook_events_raw` | `raw_payload_json` | Insert idempotente | Auditoria y recuperacion de no promovidos | Correcto | Mantener | Critico |

### /status

Fixtures base: `status-01.json` a `status-22.json`. Todos los fixtures tienen `STATUS=delivered`. El test suite agrega un caso sintetico `read` derivado de `status-09.json` porque no hay fixture real `read`.

| Endpoint | Fixture / Ejemplo | Campo payload | Ubicacion | Descripcion funcional | Modelo interno / Mapper | Tabla destino | Columna destino | Regla de persistencia | Justificacion | Estado actual | Accion recomendada | Riesgo |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| status | status-01.json | `_id_` | top-level | Customer externo del snapshot | `customer.customer_external_id` | `customers`; `webhook_events_raw` | `customer_external_id` | Upsert customer; raw audit | En status, top-level `_id_` es customer, no message | Correcto | Mantener | Alto |
| status | status-01.json | `STATUS` | top-level | Estado del snapshot/delivery | `status_current`, `message.delivery_status` | `conversations`; `messages`; `conversation_snapshots` | `status_current`; `delivery_status` | Upsert current; append snapshot; ranked message update | Estado actual y historico del delivery | Correcto | Mantener | Alto |
| status | status-01.json | `STATUS_CHANGE_TIME` | top-level | Momento del cambio de estado | `snapshot_at`, `delivery_status_at` | `webhook_events_raw`; `messages`; `conversation_snapshots`; `conversation_contexts` | `received_at`; `delivery_status_at`; `snapshot_at` | Snapshot append; message update if status progresses | Clave temporal de idempotencia snapshot | Correcto | Mantener | Alto |
| status | status-01.json | `LAST_MESSAGE` | top-level object | Ultimo mensaje conocido en el snapshot | `last_message` source object | `webhook_events_raw`; normalized fields below | `raw_payload_json`; varias | Raw full; fields promoted selectively | El objeto completo queda en raw; campos relevantes se normalizan | Correcto | Mantener | Alto |
| status | status-01.json | `LAST_MESSAGE._id_` | nested `LAST_MESSAGE` | Message externo del ultimo mensaje | `message.message_external_id`, `snapshot.last_message_external_id` | `messages`; `conversation_snapshots` | `message_external_id`; `last_message_external_id` | Upsert message; append snapshot | Permite complementar mensaje saliente con delivery | Correcto | Mantener | Alto |
| status | status-01.json | `LAST_MESSAGE.sessionId` | nested `LAST_MESSAGE` | Conversacion externa | `conversation_external_id` | `conversations`; `webhook_events_raw` | `conversation_external_id` | Upsert conversation; raw audit | Fuente primaria en status | Correcto | Mantener | Alto |
| status | status-01.json | `LAST_MESSAGE.customerId` | nested `LAST_MESSAGE` | Customer fallback | Fallback `customer_external_id` | `customers` | `customer_external_id` | Fallback only | Top-level `_id_` manda; fallback evita perder snapshot raro | Correcto | Mantener | Medio |
| status | status-01.json | `LAST_MESSAGE.contactId` | nested `LAST_MESSAGE` | Contacto fallback | Fallback `contact_external_id` | `customers` | `contact_external_id` | Upsert `COALESCE` | Complementa `PLATFORM_CONTACT_ID` si falta | Correcto | Mantener | Medio |
| status | status-01.json | `PLATFORM_CONTACT_ID` | top-level | Contacto de plataforma | `customer.contact_external_id` | `customers` | `contact_external_id` | Upsert `COALESCE` | Fuente top-level preferida en snapshots | Correcto | Mantener | Medio |
| status | status-01.json | `LAST_MESSAGE.chatPlatform` | nested `LAST_MESSAGE` | Canal del ultimo mensaje | `channel` | `customers`; `conversations`; `messages.client_payload` | `channel`; `client_payload` | Upsert channel; client payload | Fuente preferida de canal si existe | Correcto | Mantener | Medio |
| status | status-01.json | `CHAT_PLATFORM_ID` | top-level | Canal fallback | Fallback `channel` | `customers`; `conversations` | `channel` | Fallback only | Evita `unknown` cuando no hay `LAST_MESSAGE.chatPlatform` | Correcto | Mantener | Medio |
| status | status-01.json | `chatChannelId` | top-level | Canal de negocio externo | `business_channel_id` | `customers`; `conversations` | `business_channel_id` | Upsert `COALESCE` | Identifica canal negocio en Botmaker | Correcto | Mantener | Medio |
| status | status-01.json | `WHATSAPP_NUMBER` | top-level | Direccion canal negocio | `business_channel_address` | `customers`; `conversations` | `business_channel_address` | Upsert `COALESCE` | Numero real de WhatsApp | Correcto | Mantener | Medio |
| status | status-01.json | `CREATION_TIME` | top-level | Creacion del customer/contacto | `customer.customer_created_at`, fallback `conversation_started_at` | `customers`; `conversations` | `customer_created_at`; `conversation_started_at` | Customer uses `LEAST`; conversation fallback | Metadata de contacto | Correcto | Mantener | Bajo |
| status | status-01.json | `FIRST_NAME` | top-level | Nombre customer | `customer.customer_first_name` | `customers` | `customer_first_name` | Upsert `COALESCE` | Metadata customer mas confiable que split | Correcto | Mantener | Medio |
| status | status-01.json | `LAST_NAME` | top-level | Apellido customer | `customer.customer_last_name` | `customers` | `customer_last_name` | Upsert `COALESCE` | Metadata customer | Correcto | Mantener | Bajo |
| status | status-01.json | `country` | top-level | Pais customer | `customer.customer_country_code` | `customers` | `customer_country_code` | Upsert `COALESCE` | Segmentacion por pais | Correcto | Mantener | Bajo |
| status | status-01.json | `locale` | top-level | Locale customer | `customer.customer_locale` | `customers` | `customer_locale` | Upsert `COALESCE` | Segmentacion/localizacion | Correcto | Mantener | Bajo |
| status | status-01.json | `gender` | top-level | Genero customer | `customer.customer_gender` | `customers` | `customer_gender` | Upsert `COALESCE` cuando valor no vacio | Metadata opcional | Correcto | Mantener | Bajo |
| status | status-01.json | `BOT_MUTED` | top-level | Bot silenciado | `conversation.is_bot_muted`, `snapshot.is_bot_muted` | `conversations`; `conversation_snapshots` | `is_bot_muted` | Current update; snapshot append | Estado operacional de conversacion | Correcto | Mantener | Medio |
| status | status-01.json | `PENDING_MSGS` | top-level | Mensajes pendientes | `pending_message_count` | `conversations`; `conversation_snapshots` | `pending_message_count` | Current update; snapshot append | Indicador operacional actual/historico | Correcto | Mantener | Medio |
| status | status-01.json | `LAST_SEEN` | top-level | Ultima vista del usuario | `snapshot.last_seen_at` | `conversation_snapshots` | `last_seen_at` | Append historical snapshot | DDL lo modela solo historico | Correcto | Mantener | Medio |
| status | status-01.json | `USER_LAST_MSG_RECEIVED` | top-level | Ultimo mensaje recibido por usuario | `snapshot.last_user_message_received_at` | `conversation_snapshots` | `last_user_message_received_at` | Append historical snapshot | No debe sobrescribir mensajes | Correcto | Mantener | Medio |
| status | status-01.json | `USER_LAST_MSG_READ` | top-level | Ultimo mensaje leido por usuario | `snapshot.last_user_message_read_at` | `conversation_snapshots` | `last_user_message_read_at` | Append historical snapshot | Puede venir vacio; no se fuerza normalizacion | Correcto | Mantener | Medio |
| status | status-01.json | `EXECUTED_INTENTS` | top-level array | Intents ejecutados | `snapshot.executed_intents_json` | `conversation_snapshots` | `executed_intents_json` | Append JSON | Historico de automatizacion | Correcto | Mantener | Medio |
| status | status-01.json | `QUEUE` | top-level | Cola fallback | Fallback `queue_name` | `conversations`; `messages`; `conversation_snapshots` | `current_queue_name`; `queue_name` | Fallback si falta `LAST_MESSAGE.queue` | Mantiene cola en snapshots sin queue nested | Correcto | Mantener | Medio |
| status | status-01.json | `Last action author` | top-level | Autor de ultima accion | `last_action_author_external_id` | `conversations`; `conversation_snapshots` | `last_action_author_external_id` | Current `COALESCE`; snapshot append | Trazabilidad de accion | Correcto | Mantener | Medio |
| status | status-01.json | `RespuestaAccionCompleta` | top-level | Mensaje/resultado de accion | `context.completion_message_text`; `context_json` | `conversation_contexts` | `completion_message_text`; `context_json` | Append context | Variable dinamica funcional de negocio | Correcto | Mantener | Medio |
| status | status-02.json | `PreguntarAccionCompleta` | top-level | Pregunta/accion dinamica | `context_json` | `conversation_contexts` | `context_json` | Append context JSON | No hay columna especifica en DDL | Correcto | Mantener | Bajo |
| status | status-01.json | `BUSINESS_ID` | top-level | Business tenant/id | Raw only | `webhook_events_raw` | `raw_payload_json` | Raw only | No existe columna directa en DDL; `chatChannelId` cubre canal negocio | Correcto | Documentar y no persistir | Bajo |
| status | status-01.json | `LAST_MESSAGE_CREATION_TIME` | top-level | Timestamp redundante del ultimo mensaje | Fallback `snapshot_at`; raw | `webhook_events_raw` | `raw_payload_json` | Raw/fallback only | `LAST_MESSAGE.date` alimenta message; este campo solo fallback | Correcto | Mantener | Bajo |
| status | status-01.json | `LAST_MESSAGE.date` | nested `LAST_MESSAGE` | Timestamp del ultimo mensaje | `message.message_at`, first/last response, snapshot last message | `messages`; `conversations`; `conversation_snapshots` | `message_at`; `first_*_response_at`; `last_message_at` | Message upsert; first `LEAST`; last `GREATEST`; snapshot append | Timeline de conversacion | Correcto | Mantener | Alto |
| status | status-01.json | `LAST_MESSAGE.from` | nested `LAST_MESSAGE` | Emisor del ultimo mensaje | `sender_type`, `direction` | `messages`; `conversations`; `conversation_snapshots` | `sender_type`; `direction`; `last_message_sender_type` | Normalize; update current; snapshot append | Diferencia customer/bot/operator | Correcto | Mantener | Alto |
| status | status-01.json | `LAST_MESSAGE.fromName` | nested `LAST_MESSAGE` | Nombre visible del emisor | `sender_name`, snapshot sender name | `messages`; `conversation_snapshots` | `sender_name`; `last_message_sender_name` | Upsert `COALESCE`; snapshot append | Trazabilidad de ultimo emisor | Correcto | Mantener | Medio |
| status | status-01.json | `LAST_MESSAGE.message` | nested `LAST_MESSAGE` | Texto del ultimo mensaje | `message.message_text`, `snapshot.last_message_text` | `messages`; `conversation_snapshots` | `message_text`; `last_message_text` | Upsert `COALESCE`; snapshot append | Texto visible del ultimo mensaje | Correcto | Mantener | Alto |
| status | status-09.json | `LAST_MESSAGE.operatorId` | nested `LAST_MESSAGE` | Operador del ultimo mensaje | `operator.operator_external_id`, snapshot operator | `operators`; `messages`; `conversation_snapshots` | `operator_external_id`; FK `operator_id`; `operator_external_id` | Upsert operator si existe; snapshot append | Fuente de operador en status | Correcto | Mantener | Alto |
| status | status-09.json | `LAST_MESSAGE.operatorName` | nested `LAST_MESSAGE` | Nombre operador | `operator.operator_name` | `operators`; `conversation_snapshots` | `operator_name` | Upsert `COALESCE`; snapshot append | Metadata operador historica y actual | Correcto | Mantener | Medio |
| status | status-09.json | `LAST_MESSAGE.operatorEmail` | nested `LAST_MESSAGE` | Email operador | `operator.operator_email` | `operators`; `conversation_snapshots` | `operator_email` | Upsert `COALESCE`; snapshot append | Metadata operador | Correcto | Mantener | Medio |
| status | status-01.json | `LAST_MESSAGE.queue` | nested `LAST_MESSAGE` | Cola del ultimo mensaje | `queue_name` | `messages`; `conversations`; `conversation_snapshots` | `queue_name`; `current_queue_name` | Upsert/update current; snapshot append | Fuente preferida de cola en status | Correcto | Mantener | Medio |
| status | status-15.json | `LAST_MESSAGE.file` | nested `LAST_MESSAGE` | Archivo adjunto en ultimo mensaje | `attachment_url`, `attachment_type=file`, client payload | `messages` | `attachment_url`; `attachment_type`; `client_payload` | Upsert `COALESCE` | Debe complementar el mensaje saliente como `/outgoing` | Corregido | Mantener test | Medio |
| status | status-21.json | `LAST_MESSAGE.audio` | nested `LAST_MESSAGE` | Audio adjunto en ultimo mensaje | `attachment_url`, `attachment_type=audio` | `messages` | `attachment_url`; `attachment_type` | Upsert `COALESCE` | Debe complementar el mensaje saliente | Correcto | Mantener | Medio |
| status | status-15.json | `LAST_MESSAGE.hasAttachment` | nested `LAST_MESSAGE` | Flag adjunto | `message.has_attachment` | `messages` | `has_attachment` | Upsert `GREATEST` | Conserva indicacion aunque falte URL | Correcto | Mantener | Medio |
| status | status-01.json | Payload completo | top-level object | Evidencia completa | `raw_payload` | `webhook_events_raw` | `raw_payload_json` | Insert idempotente | Auditoria y recuperacion | Correcto | Mantener | Critico |

## Cobertura Por Entidad

### `webhook_events_raw`

- Endpoints: `incoming`, `outgoing`, `status`.
- Campos: provider, endpoint, event type, external event key, conversation id, customer id, received/processed timestamps, status/error y payload JSON completo.
- Columnas usadas: todas salvo `created_at` que la completa MySQL.
- Regla: insert idempotente por `(provider_name, external_event_key)`. `processed` se ignora; `failed` se reintenta con el mismo `raw_event_id`.
- Evaluacion: suficiente para auditoria y replay logico. No guarda headers; estan en el modelo interno pero no en DDL.

### `customers`

- Endpoints: `incoming`, `outgoing`, `status`.
- Campos: `customerId` en mensajes; `_id_` top-level en status; `contactId`/`PLATFORM_CONTACT_ID`; `chatPlatform`; `WHATSAPP_NUMBER`; nombre/apellido/pais/locale/genero/creation time desde status.
- Columnas sin uso por fixtures puntuales de mensajes: `customer_country_code`, `customer_locale`, `customer_gender`, `customer_created_at` solo llegan desde `/status`.
- Regla: upsert por `(provider_name, customer_external_id)`, preservando no nulos con `COALESCE` y fecha de creacion mas antigua.
- Evaluacion: correcta. `/status` es la fuente mas rica de customer.

### `operators`

- Endpoints: `outgoing`, `status`.
- Campos: `operatorId`, `operatorName`, `operatorEmail` cuando `sender_type=operator`.
- Columnas sin uso: `operator_role`.
- Regla: upsert por `(provider_name, operator_external_id)`, solo si hay operador.
- Evaluacion: correcta. `/incoming` no crea operador porque sus fixtures son customer messages con `operatorId=null`.

### `conversations`

- Endpoints: `incoming`, `outgoing`, `status`.
- Campos: `sessionId`/`LAST_MESSAGE.sessionId`, customer FK, canal, canal negocio, inicio, first user/bot/human response, last message, queue, bot muted, pending messages, status, topic/subtopic/product.
- Columnas sin uso real en fixtures: `journey_stage`, `handoff_reason`, `resolution_type`, `closed_by`, `closed_at`. `resolved_flag` solo se alimentaria si llega `IssueResuelto`, no presente en fixtures actuales.
- Regla: upsert por `(provider_name, conversation_external_id)`. First timestamps usan menor fecha; last timestamp usa mayor fecha; `/incoming` y `/outgoing` no pisan `status_current`.
- Evaluacion: correcta y conservadora. Con datos reales actuales, `product` no debe llenarse desde `AP_Actividad`; esa variable describe actividad/oficio y no producto estable.

### `messages`

- Endpoints: `incoming`, `outgoing`, `status`.
- Campos: ids de mensaje, conversation/customer/operator FK, timestamp, direction, sender type/name, texto, boton, adjunto, queue, delivery status, client payload.
- Columnas sin uso: `intent_name` no tiene fuente directa en fixtures; queda para futuros payloads.
- Regla: upsert por `(provider_name, message_external_id)`. Delivery status se actualiza por progresion para no degradar `read` a `delivered`.
- Evaluacion: corregido para `LAST_MESSAGE.file` en `/status`.

### `conversation_snapshots`

- Endpoints: `status`.
- Campos: status, bot muted, pending, seen/read/received timestamps, action author, queue, intents, ultimo mensaje y operador.
- Columnas usadas: todas salvo `created_at` automatico.
- Regla: append historical snapshot; no unique key en DDL.
- Evaluacion: correcta como historico. La idempotencia se controla antes por raw event key.

### `conversation_contexts`

- Endpoints: `status`.
- Campos: product/topic/subtopic si llegan como claves dedicadas reales; `activity_name` desde `ActividadName` o `AP_Actividad`; quote/coverage/precio si llegan; `RespuestaAccionCompleta`; contexto dinamico por prefijos.
- Columnas subutilizadas en fixtures actuales: quote/coverage/precio/topic/product/subtopic no aparecen en los fixtures observados. `activity_name` si aparece y hoy es la mejor columna estructurada para actividad/motivo operativo.
- Regla: append historical context por snapshot. Variables sensibles obvias excluidas de `context_json`; el raw conserva payload completo.
- Evaluacion: correcta y extensible. `BusquedaActividad` queda en `context_json`; no debe promoverse a `topic`, `subtopic` ni `product` porque en datos reales opera como flag/binario, no como clasificacion de negocio.

### `conversation_metrics`

- Endpoints: ninguno actualmente.
- Evaluacion: tabla disponible para procesos agregados futuros. No se debe alimentar desde webhooks puntuales sin definicion de metricas.

## Cobertura Por Endpoint

### `/incoming`

- Campos detectados: `_id_`, `date`, `from`, `fromCustomer`, `fromName`, `message`, `isButton`, `buttonName`, `hasAttachment`, `audio`, `operatorId`, `queue`, `sessionId`, `sessionCreationTime`, `customerId`, `contactId`, `chatPlatform`, `WHATSAPP_NUMBER`.
- Persistidos: raw completo, customer basico, conversation basica, message inbound.
- No persistidos como columnas dedicadas: `operatorId` nulo, headers, payload completo fuera de raw.
- Solo raw/client payload: subconjunto del evento en `messages.client_payload`, payload completo en raw.
- Debe actualizar: customer, conversation first/last user message, message inbound.
- Evaluacion: consistente.

### `/outgoing`

- Campos detectados: `_id_`, `date`, `from`, `fromName`, `message`, `hasAttachment`, `file`, `audio`, `operatorId`, `operatorName`, `operatorEmail`, `queue`, `sessionId`, `sessionCreationTime`, `customerId`, `contactId`, `chatPlatform`, `WHATSAPP_NUMBER`.
- Sender types reales: todos `operator` en fixtures. El mapper soporta `bot`, pero no hay fixture real de `/outgoing` con bot.
- Persistidos: raw, customer, operator si aplica, conversation first human/bot response, message outbound.
- No debe actualizar: `status_current`, snapshots ni contexts.
- Evaluacion: consistente.

### `/status`

- Campos top-level detectados: `STATUS`, `STATUS_CHANGE_TIME`, `_id_`, `LAST_MESSAGE`, `PLATFORM_CONTACT_ID`, `CHAT_PLATFORM_ID`, `chatChannelId`, `WHATSAPP_NUMBER`, `CREATION_TIME`, `FIRST_NAME`, `LAST_NAME`, `country`, `locale`, `gender`, `BOT_MUTED`, `PENDING_MSGS`, `LAST_SEEN`, `USER_LAST_MSG_RECEIVED`, `USER_LAST_MSG_READ`, `EXECUTED_INTENTS`, `QUEUE`, `Last action author`, `RespuestaAccionCompleta`, `PreguntarAccionCompleta`, `BUSINESS_ID`, `LAST_MESSAGE_CREATION_TIME`.
- Campos nested en `LAST_MESSAGE`: `_id_`, `date`, `chatPlatform`, `contactId`, `customerId`, `sessionId`, `sessionCreationTime`, `from`, `fromName`, `message`, `operatorId`, `operatorName`, `operatorEmail`, `queue`, `hasAttachment`, `file`, `audio`.
- Va a snapshot: status, muted, pending, seen/read/received, action author, queue, intents, ultimo mensaje, operador.
- Va a conversation: estado actual, bot muted, pending, first/last timestamps, queue, topic/subtopic/product solo si existen como claves dedicadas reales.
- Va a message: ultimo mensaje y delivery status.
- Va a context_json: variables dinamicas de negocio sin columna especifica, incluyendo `BusquedaActividad` y otras claves `AP_*`.
- Va solo a raw: `BUSINESS_ID`, payload completo, campos no promovidos.
- Evaluacion: corregido para `LAST_MESSAGE.file`.

## Reglas De Decision Explicitas

- `conversation_external_id`:
  - `/incoming` y `/outgoing`: `sessionId`.
  - `/status`: `LAST_MESSAGE.sessionId`; fallback `conversationId`/`sessionId`; ultimo fallback `customer_external_id`.

- `customer_external_id`:
  - `/incoming` y `/outgoing`: `customerId`.
  - `/status`: top-level `_id_`; fallback `LAST_MESSAGE.customerId`.

- `contact_external_id`:
  - `/incoming` y `/outgoing`: `contactId`.
  - `/status`: `PLATFORM_CONTACT_ID`; fallback `LAST_MESSAGE.contactId`.

- `external_event_key`:
  - `/incoming`: `incoming:v1:{provider}:message:{_id_}`; fallback hash deterministico si falta `_id_`.
  - `/outgoing`: `outgoing:v1:{provider}:message:{_id_}`; fallback hash deterministico si falta `_id_`.
  - `/status`: `status:v1:{sha256(provider, endpoint, conversation, message, STATUS, STATUS_CHANGE_TIME)}`.

- `operator`:
  - Se crea/actualiza solo para `sender_type=operator` o si `/status` trae operador en `LAST_MESSAGE`.
  - Identidad: `operatorId`; fallback email; fallback nombre solo cuando el sender es operator.

- `context_json`:
  - Solo `/status`.
  - Entran claves con prefijos `AP_`, `Actividad`, `BusquedaActividad`, `DeathAmount`, `IssueResuelto`, `Preguntar`, `Respuesta`, `typeDate`.
  - Se excluyen claves sensibles conocidas: `AP_MailTomador`, `AP_TipoDocumentoTomador`.

- `activity_name` / `motivo_consulta_aprox` / `product`:
  - `activity_name` se llena desde `ActividadName`; si no existe, usa `AP_Actividad`.
  - `product` se llena solo desde claves dedicadas de producto: `product`, `PRODUCT`, `Producto`.
  - `AP_Actividad` no debe poblar `product`.
  - `BusquedaActividad` queda solo en `context_json` como flag operativo.
  - La capa analitica puede derivar `motivo_consulta_aprox` a partir de `subtopic`, `topic`, `activity_name` y, en ultimo termino, `product`.

- Raw only:
  - Payload completo siempre queda en `webhook_events_raw.raw_payload_json`.
  - Campos sin columna real o sin decision funcional, como `BUSINESS_ID`, quedan solo en raw.

- Preservacion en upserts:
  - Datos descriptivos no nulos usan `COALESCE`.
  - Fechas first usan `LEAST`.
  - Fechas last usan `GREATEST`.
  - Flags booleanos de mensaje usan `GREATEST` cuando representan presencia.
  - `status_current` lo maneja `/status`; `/incoming` y `/outgoing` no lo pisan.

- `sender_type`:
  - `user`/`customer` -> `customer`.
  - `operator` -> `operator`.
  - `bot` -> `bot`.
  - `fromCustomer=true` refuerza `customer`.
  - Presencia de `operatorId`/`operatorEmail` permite inferir `operator`.

- `direction`:
  - `/incoming`: `inbound` si `sender_type=customer`; otros casos quedan como outbound por consistencia historica del mapper.
  - `/outgoing`: siempre `outbound`.
  - `/status`: `inbound` si ultimo mensaje es customer; si no, `outbound`.

- First/last message timestamps:
  - `first_user_message_at`: mensajes customer.
  - `first_bot_response_at`: mensajes bot.
  - `first_human_response_at`: mensajes operator.
  - `last_message_at`: timestamp del mensaje mas nuevo visto.

- Snapshots/context:
  - `/status` inserta snapshots y contexts historicos.
  - La no duplicacion depende de `webhook_events_raw.external_event_key`.

## Auditoria Contra Codigo Actual

Hallazgos:

1. `LAST_MESSAGE.file` en `status-15.json` no se promovia a `messages.attachment_url`.
   - Impacto: medio. Se perdia el archivo normalizado cuando el complemento venia por `/status`.
   - Accion: corregido en `StatusPayloadMapper`.

2. Raws duplicados en estado `failed` se descartaban.
   - Impacto: alto. Un fallo transitorio podia dejar raw sin normalizacion.
   - Accion: corregido en `WebhookIngestionService`; `failed` se reintenta.

3. Delivery status podia degradarse por snapshots tardios.
   - Impacto: medio/alto. `read` podia volver a `delivered`.
   - Accion: corregido en `WebhookRepository` con ranking SQL.

4. `conversation_metrics` no se alimenta.
   - Impacto: bajo por ahora. No hay definicion funcional ni fixtures de metricas.
   - Accion: documentar y no alimentar desde webhooks puntuales.

5. Columnas sin fuente real en fixtures actuales:
   - `operators.operator_role`.
   - `messages.intent_name`.
   - `conversations.journey_stage`, `handoff_reason`, `resolution_type`, `closed_by`, `closed_at`.
   - Varias columnas de quote/topic/subtopic/product solo si aparecen variables dedicadas reales; `AP_Actividad` queda en `activity_name`.
   - Accion: mantener sin inventar mapeos.

6. `product` estaba sobrecargado con actividad en datos reales.
   - Impacto: medio. Distorsiona breakdowns analiticos y mezcla producto con oficio/motivo.
   - Evidencia: `AP_Actividad` trae valores como `Fotografía`, `Trabajo en altura 30 metros`, `Construcciones`.
   - Accion: corregido en `StatusPayloadMapper`; `AP_Actividad` ahora alimenta `activity_name` y no `product`. La capa analitica expone `motivo_consulta_aprox` por separado. Para datos historicos ya cargados, usar `database/query_packs/20260421_activity_product_reconciliation.sql`.

## Tests De Contrato

- `tests/test_persistence_contract.py` valida que los inserts del repositorio apunten a tablas/columnas reales del DDL.
- Tests de mappers cubren todos los fixtures reales.
- Tests de servicio cubren duplicados `processed` y reintentos `failed`.
- Tests de status cubren `delivered` vs `read` y adjuntos `audio`/`file`.
