# Auditoria Tecnica Del Dump 2026-04-22

Fuente principal auditada: `database/dump.sql`.

Cruce realizado contra:

- `database/init_db.sql`
- `src/handlers`
- `src/services/webhook_service.py`
- `src/mappers`
- `src/repositories/webhook_repository.py`
- `template.yaml`
- fixtures y docs operativas del repo

## 1. Resumen Ejecutivo

El dump tiene senal suficiente para analitica operativa basica, pero no para analitica de resolucion o taxonomias de negocio. El modelo actual responde bien volumen, tiempos de primera respuesta, handoff aproximado, actores intervinientes, colas y uso de botones/adjuntos; no responde bien cierre, resolucion exacta, motivo formal de handoff ni `topic/subtopic`.

Hallazgos principales basados en el dump real:

- Hay datos en `webhook_events_raw` (1076), `customers` (28), `operators` (2), `conversations` (35), `messages` (667), `conversation_snapshots` (584) y `conversation_contexts` (584). `conversation_metrics` existe en DDL pero esta vacia.
- `status` domina la ingesta real: 584/1076 eventos raw. `incoming` aporta 314 y `outgoing` 178.
- `messages` tiene buena cobertura operativa, pero 351/667 filas conservan `client_payload` de `status` y no del webhook nativo del mensaje. En 102 mensajes con `outgoing` + `status`, el payload final quedo sobrescrito por `status`.
- `topic` y `subtopic` no tienen ninguna senal real: 0/35 conversaciones y 0/584 contextos.
- `product` tiene senal muy pobre y contaminada: 3/35 conversaciones, 50/584 contextos; aparecen valores de actividad y hasta texto libre largo.
- `activity_name` si tiene senal util: 209/584 contextos y 17/35 conversaciones con al menos una actividad observada.
- `resolved_flag` existe solo en 5/35 conversaciones. `closed_at`, `closed_by`, `handoff_reason`, `resolution_type` y `journey_stage` estan completamente vacios.
- `conversation_contexts` esta sobrecargada con ruido: 505/584 filas repiten exactamente el mismo contexto que la fila previa de su conversacion; 93 filas extra son duplicados exactos del mismo `snapshot_at`.
- Hay una brecha de minimizacion de datos: `context_json` esta guardando PII y hasta `AP_User_Password` por la captura amplia de claves `AP_*`.

Calidad/cobertura global hoy:

- Operativa: buena
- Analitica basica: usable
- Analitica de negocio estructurada: baja
- Trazabilidad raw: alta
- Higiene de datos sensibles: insuficiente

## 2. Hallazgos Por Tabla

### `webhook_events_raw`

- Volumen: 1076 filas
- Cobertura:
  - `processing_status`: 100% `processed`
  - `processing_error`: 0%
  - `source_endpoint`: `status` 584, `incoming` 314, `outgoing` 178
- Senal util:
  - idempotencia: no hay duplicados por `(provider_name, external_event_key)`
  - payload completo por endpoint
  - timestamps de recepcion
- Observaciones:
  - la tabla sirve como evidencia fuerte de cada webhook
  - guarda datos sensibles reales del payload de `status`: `AP_User_Password` 24 veces, `AP_DNITomador` 56, `Siniestro_DNIAseg` 59, nombres/apellidos/calle/localidad
  - si la politica de seguridad no permite secretos en raw, hoy hay una brecha real

### `customers`

- Volumen: 28 filas
- Cobertura real:
  - `channel`, `contact_external_id`, `business_channel_id`, `business_channel_address`, `customer_country_code`, `customer_created_at`: 100%
  - `customer_locale`, `customer_gender`: 0%
- Senal util:
  - todos los clientes observados son `whatsapp`
  - `business_channel_id` y `business_channel_address` son practicamente constantes
- Observaciones:
  - hay contaminacion semantica en nombres: 14 filas con `customer_last_name = 'null'`
  - varios nombres visibles son texto libre no confiable para analitica identitaria
  - hoy sirve para trazabilidad de contacto, no para perfilado serio del customer

### `operators`

- Volumen: 2 filas
- Cobertura real:
  - `operator_external_id`, `operator_name`, `operator_email`: 100%
  - `operator_role`: 0%
- Observaciones:
  - la tabla esta bien para el escenario actual
  - no hay evidencia para ampliar el modelo de operador todavia

### `conversations`

- Volumen: 35 filas
- Cobertura real:
  - `conversation_started_at`, `first_user_message_at`, `last_message_at`, `status_current`: casi total
  - `first_human_response_at`: 31/35
  - `first_bot_response_at`: 31/35
  - `current_queue_name`: 34/35
  - `resolved_flag`: 5/35
  - `product`: 3/35
  - `topic`, `subtopic`, `journey_stage`, `handoff_reason`, `resolution_type`, `closed_by`, `closed_at`: 0/35
- Senal util:
  - `status_current` hoy solo toma `read` y `delivered`
  - `last_message_sender_type`: `operator` 26, `customer` 6, `bot` 3
  - `current_queue_name`: `_default_` 19, `Seguros-1` 12, `siniestros-1` 3, `NULL` 1
- Observaciones:
  - sirve para SLA basico y handoff aproximado
  - no sirve para estado de negocio de la conversacion; el estado actual es estado de entrega del ultimo mensaje
  - `product` no es confiable como dimension primaria

### `messages`

- Volumen: 667 filas
- Cobertura real:
  - `message_at`, `direction`, `sender_type`, `has_attachment`, `is_button`, `is_customer_message`: 100%
  - `message_text`: 631/667
  - `queue_name`: 498/667
  - `delivery_status` y `delivery_status_at`: 352/667
  - `operator_id`: 191/667
  - `attachment_type`: 31/667
  - `attachment_url`: 22/667
  - `intent_name`: 0/667
- Senal util:
  - `sender_type`: `customer` 315, `bot` 161, `operator` 191
  - `direction`: `inbound` 315, `outbound` 352
  - botones: 86 mensajes
  - adjuntos: 35 mensajes
  - adjuntos de audio: 16; `file`: 3; `attachment` generico: 12
- Observaciones:
  - es la mejor tabla para volumen e interaccion por actor
  - hay degradacion de metadata por upsert:
    - 102 mensajes con `outgoing` + `status` terminaron con `client_payload` de `status`
    - 3 adjuntos `file` del webhook saliente terminaron como `attachment` generico
  - el dump muestra que `status` termina siendo fuente dominante de persistencia final del mensaje, no solo de su delivery status

### `conversation_snapshots`

- Volumen: 584 filas
- Cobertura real:
  - `status_current`, `snapshot_at`, `last_message_*`, `last_seen_at`, `last_user_message_received_at`: 100%
  - `last_user_message_read_at`: 480/584
  - `queue_name`: 435/584
  - `last_action_author_external_id`: 420/584
  - datos de operador: 291/584
- Observaciones:
  - aporta valor real para timeline de estados de entrega
  - hay 93 filas extra al agrupar por `(conversation_id, snapshot_at)`, pero no son duplicados exactos: suelen diferenciarse entre `delivered` y `read`
  - esta tabla si agrega senal y no parece ser el principal problema de redundancia

### `conversation_contexts`

- Volumen: 584 filas
- Cobertura real:
  - `context_json`: 358/584
  - `activity_name`: 209/584
  - `completion_message_text`: 135/584
  - `quote_external_id`, `coverage_external_id`, `quoted_total_amount`: 64/584
  - `product`: 50/584
  - `quote_description`: 28/584
  - `topic`, `subtopic`: 0/584
- Senal util:
  - `activity_name` es hoy la mejor dimension aproximada de motivo/actividad
  - hay 17 conversaciones con actividad observada
  - hay 7 conversaciones con cotizacion/cobertura observada
  - hay 15 conversaciones con `completion_message_text`
- Observaciones:
  - la tabla esta muy redundante: 505/584 filas repiten exactamente el contexto previo de la misma conversacion
  - 93 filas extra son duplicados exactos en mismo `snapshot_at`
  - contiene PII que no deberia vivir en una tabla analitica derivada: `AP_User_Password` 24, `AP_DNITomador` 56, `AP_User_Nombre` 56, `AP_User_Apellido` 56, datos de direccion/localidad
  - `product` esta contaminado historicamente; `activity_name` tiene mucha mas senal real que `product`

### `conversation_metrics`

- Volumen: 0 filas
- Observaciones:
  - el DDL la define, pero la ingesta real no la usa
  - no hay evidencia para llenarla transaccionalmente desde Lambda
  - si se usa, deberia poblarse por proceso derivado o vista materializada

## 3. Hallazgos Sobre El Codigo

### Cambio inmediato 1: evitar fuga de PII a `conversation_contexts`

Evidencia del dump:

- `context_json` contiene `AP_User_Password` 24 veces y multiples claves de identidad/domicilio

Codigo impactado:

- `src/mappers/status_mapper.py:348-355`

Problema:

- `_dynamic_context()` mete cualquier clave con prefijo `AP_`, `Actividad`, `BusquedaActividad`, `IssueResuelto`, `Preguntar`, `Respuesta`, `typeDate`
- eso arrastra claves analiticamente utiles y tambien PII/secrets

Cambio recomendado:

- pasar de regla por prefijos a allowlist explicita de claves analiticas
- como minimo excluir:
  - `AP_User_Password`
  - DNI/documento
  - nombre/apellido
  - calle/localidad/provincia/CP
  - emails

### Cambio inmediato 2: no degradar `messages` cuando llega `status`

Evidencia del dump:

- 102 mensajes con `outgoing` + `status` quedaron con `client_payload` final de `status`
- 3 archivos enviados por `outgoing` terminaron persistidos como `attachment` generico

Codigo impactado:

- `src/repositories/webhook_repository.py:677-708`
- `src/mappers/status_mapper.py:378-395`

Problema:

- `client_payload = COALESCE(VALUES(client_payload), client_payload)` sobrescribe siempre con el payload nuevo si no es null
- `attachment_type = COALESCE(VALUES(attachment_type), attachment_type)` tambien puede degradar `file` a `attachment`

Cambio recomendado:

- definir prioridad de fuentes: `incoming/outgoing` > `status` para payload y metadatos ricos
- si el mensaje ya existe y la nueva fuente es `status`, no sobrescribir `client_payload` si ya hay `incoming_message` u `outgoing_message`
- no degradar `attachment_type` cuando el valor existente es mas especifico que el nuevo

### Cambio inmediato 3: no insertar `conversation_contexts` redundantes

Evidencia del dump:

- 505/584 filas repiten exactamente el contexto anterior de la misma conversacion
- 93 filas extra son duplicados exactos por mismo `snapshot_at`

Codigo impactado:

- `src/repositories/webhook_repository.py:797-842`

Problema:

- `_insert_context()` inserta siempre, aunque no haya cambio de contexto

Cambio recomendado:

- antes de insertar, comparar contra el ultimo contexto de la conversacion y omitir si no cambia
- opcionalmente agregar hash de contexto o unique/index auxiliar para dedupe

### Cambio recomendado 4: normalizar strings basura tipo `'null'`

Evidencia del dump:

- `customers.customer_last_name = 'null'` en 14 filas

Codigo impactado:

- `src/mappers/status_mapper.py:398-403`
- `src/mappers/incoming_mapper.py:298-313`

Problema:

- `_text()` considera `'null'` como valor valido
- `_split_name()` separa nombres crudos sin sanear

Cambio recomendado:

- tratar `'null'`, `'none'`, `'undefined'` y equivalentes como `None`
- aplicar esa normalizacion antes de poblar nombres

### Cambio recomendado 5: agregar tests de mapper/status y merge rules

Evidencia del repo:

- no existe `tests/test_status_mapper.py`

Cambio recomendado:

- agregar tests para:
  - exclusion de PII en `_dynamic_context`
  - no sobreescritura de `client_payload` rico por `status`
  - no degradacion de `attachment_type`
  - dedupe de contextos
  - normalizacion de strings `'null'`

### Cambio que NO haria ahora

- no reintroducir mapeo de `AP_Actividad` a `product`
- no poblar `conversation_metrics` desde las Lambdas
- no inventar `closed_at`, `closed_by`, `handoff_reason` o `journey_stage`
- no modelar `topic/subtopic` adicional mientras sigan en 0% de cobertura real

Nota relevante:

- el codigo actual en `src/mappers/status_mapper.py:331-338` ya no mapea `AP_Actividad` a `product`; el dump trae contaminacion historica. Ahi corresponde reconciliar datos historicos y agregar prueba de no regresion, no volver a tocar el mapper para ese punto.

## 4. Queries Estadisticas Posibles Hoy

Se pueden responder hoy, con limitaciones conocidas:

- conversaciones por periodo
- mensajes entrantes/salientes por periodo y actor
- conversaciones con intervencion humana, bot o mixta
- tiempo a primera respuesta humana y del bot
- duracion operativa de la conversacion
- colas mas usadas
- operadores con mas interacciones
- distribucion por canal
- uso de botones
- uso de adjuntos/audio
- handoff aproximado a humano
- cobertura real de `activity_name`, `product`, `topic`, `subtopic`
- conversaciones con quote/cobertura
- duplicados/redundancias de contexto
- calidad de timeline y outliers basicos

SQL generado:

- `database/query_packs/20260422_dump_analysis_queries.sql`

Limitaciones:

- `status_current` hoy es delivery status (`read` / `delivered`), no estado de negocio
- `handoff` solo puede ser aproximado
- `resolved_flag` sirve solo cuando viene `IssueResuelto`
- `product` no es una dimension confiable
- `topic/subtopic` no tienen cobertura

## 5. Preguntas Que Aun No Se Pueden Responder Bien

Con el dump y codigo actual no se responde bien:

- quien cerro la conversacion
- cuando se cerro exactamente
- tiempo real de resolucion
- motivo formal del handoff
- taxonomia estable `topic/subtopic`
- journey stage/outcome del flujo
- producto de negocio confiable

Lo que falta:

- campos fuente explicitos en payload
- o persistencia derivada que capture esos eventos cuando existan

## 6. Recomendaciones Para El Avance Del Proyecto

### Corto plazo

1. Corregir minimizacion de datos en `status_mapper` y limpiar historico de `conversation_contexts`.
2. Corregir merge de `messages` para que `status` no degrade payload ni tipo de adjunto.
3. Dejar consultas base para reporting y auditoria usando tablas actuales.

### Mediano plazo

1. Dedupe o insercion condicional de `conversation_contexts`.
2. Crear vistas base para reporting estable:
   - latest context por conversacion
   - message rollup por conversacion
   - context coverage / quote coverage
3. Agregar tests de regresion para status mapper y reglas de upsert.

### Opcionales

1. Promover `ActividadCode` a columna dedicada si el negocio lo va a usar como dimension estable.
2. Materializar una tabla resumen diaria o por conversacion solo fuera del camino transaccional.
3. Revisar si `webhook_events_raw` debe guardar payload crudo completo o version sanitizada/encriptada para secretos.

## 7. Prioridad De Roadmap

### Primero

- higiene de datos sensibles y merge correcto de `messages`

Impacto:

- evita guardar passwords/PII en capa derivada
- mejora trazabilidad real de mensajes
- corrige degradacion de metadata ya visible en dump

### Segundo

- dedupe de `conversation_contexts` y base SQL de reporting

Impacto:

- baja ruido analitico
- simplifica queries
- evita sobreestimar actividad/contextos

### Tercero

- enriquecimiento de modelo solo con evidencia nueva

Impacto:

- permitiria mejores metricas de negocio sin inventar taxonomias
- incluye `activity_code` o cierre/handoff explicitos solo si el proveedor realmente los expone

## 8. Artefactos Generados

- `docs/dump-audit-20260422.md`
- `database/query_packs/20260422_dump_analysis_queries.sql`
