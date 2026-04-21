# Grafana Analytics DDL Proposal

## Resumen Ejecutivo

El esquema actual ya tiene una base suficiente para una primera capa analitica de Grafana sin poblar `conversation_metrics` ni crear tablas nuevas. La estrategia recomendada es:

1. Mantener las tablas actuales como capa normalizada operacional/auditoria.
2. Agregar indices compuestos orientados a dashboards.
3. Crear vistas SQL para Grafana separando:
   - estado actual de conversaciones;
   - snapshots historicos de `/status`;
   - contexto ultimo y breakdown por topic/product;
   - intents expandidos desde JSON;
   - volumen de mensajes desde `messages`;
   - metricas aproximadas claramente marcadas con `_aprox`.
4. No poblar `conversation_metrics` todavia. Usarla mas adelante como tabla derivada/materializada si las vistas se vuelven costosas o si se define un job de recalculo confiable.

Archivo SQL propuesto:

- `database/migrations/20260420_grafana_analytics_layer.sql`

## Entendimiento Del Modelo Actual

Fuentes revisadas:

- `docs/persistence-traceability-matrix.md`
- `database/init_db.sql`
- fixtures reales de `tests/fixtures/incoming`, `tests/fixtures/outgoing`, `tests/fixtures/status`
- mappers y repositorio actuales

Tablas actuales:

- `webhook_events_raw`: auditoria raw e idempotencia.
- `customers`: identidad del customer/contacto.
- `operators`: operadores humanos.
- `conversations`: estado agregado actual de cada conversacion.
- `messages`: timeline normalizado de mensajes observados.
- `conversation_snapshots`: snapshots historicos de `/status`.
- `conversation_contexts`: contexto historico/promovido de `/status`.
- `conversation_metrics`: tabla derivada disponible, pero sin poblacion actual.

Lectura funcional clave:

- `/incoming` y `/outgoing` son eventos puntuales de mensaje.
- `/status` es snapshot de conversacion/contexto y tambien puede complementar el ultimo mensaje.
- Con `/status` solo, algunas metricas de conversacion son aproximadas porque no se observa necesariamente todo el timeline.
- Con `/incoming` y `/outgoing` activos y completos, `messages` pasa a ser la fuente fuerte para conteos, intervencion por actor y primeras respuestas.

## Hallazgos Del Esquema Actual

### Lo Que Ya Sirve Para Analitica

- `conversations` sirve para dashboards de estado actual por canal, cola, status, bot muted, pending messages y dimensiones declaradas si llegan.
- `conversation_snapshots` sirve para evolucion temporal de estados, pending messages, bot muted e intents.
- `conversation_contexts` sirve para contexto de negocio, activity/topic/product/subtopic, quotes y variables dinamicas.
- `messages` sirve para volumen por actor, operador, cola, adjuntos y tiempos de primera respuesta cuando el timeline este completo.
- `webhook_events_raw` sirve para health de ingesta y auditoria de errores/reintentos.

### Tablas Que Deberian Poblarse Ya

Aunque inicialmente se use mas `/status`, conviene poblar siempre:

- `webhook_events_raw`: obligatorio para idempotencia y auditoria.
- `customers`: necesario para FK y segmentacion.
- `conversations`: estado agregado actual.
- `conversation_snapshots`: historico de `/status`.
- `conversation_contexts`: contexto de `/status`.
- `messages`: debe poblarse desde `/status` con ultimo mensaje observado, pero las metricas de conteo deben tratarse como observadas/aproximadas hasta que `/incoming` y `/outgoing` esten completos.
- `operators`: cuando `/outgoing` o `/status.LAST_MESSAGE` tenga operador.

### Columnas Que No Conviene Poblar Todavia Si No Hay Fuente Real

No conviene inferir artificialmente:

- `conversations.closed_at`
- `conversations.closed_by`
- `conversations.resolution_type`
- `conversations.handoff_reason`
- `conversations.journey_stage`
- `operators.operator_role`
- `messages.intent_name`
- `conversation_metrics.*`

Razon: los fixtures actuales no traen una semantica suficiente para completarlas sin inventar reglas. Poner valores heuristico podria producir dashboards engañosos.

### FK, Indices Y Trazabilidad

No falta ninguna FK bloqueante para Grafana:

- `conversations.customer_id -> customers.id`
- `messages.conversation_id -> conversations.id`
- `messages.customer_id -> customers.id`
- `messages.operator_id -> operators.id`
- `conversation_snapshots.* -> conversations/customers`
- `conversation_contexts.* -> conversations/customers`

No se recomienda agregar `raw_event_id` directamente a `messages` o `conversations` por ahora:

- Un mensaje puede ser creado por `/outgoing` y luego complementado por varios `/status`.
- Una conversacion se actualiza por muchos raw events.
- Un unico `raw_event_id` en la fila normalizada seria ambiguo.

Si en el futuro se requiere trazabilidad raw-normalized completa para auditoria forense, conviene una tabla puente `webhook_event_entity_links` con `(raw_event_id, entity_type, entity_id, action)`. No es necesaria para Grafana en esta etapa.

Si faltan indices para dashboards, no son FKs sino indices compuestos sobre:

- `conversations(channel, status_current, current_queue_name, last_message_at)`
- `messages(conversation_id, sender_type, message_at)`
- `messages(operator_id, message_at)`
- `conversation_snapshots(status_current, queue_name, snapshot_at)`
- `conversation_contexts(conversation_id, snapshot_at)`
- `webhook_events_raw(source_endpoint, processing_status, received_at)`

Estos indices estan incluidos en la migracion propuesta.

## Riesgos

### Riesgo 1: Metricas De Mensajes Incompletas

Si solo entra `/status`, `messages` contiene ultimos mensajes observados en snapshots, no necesariamente el timeline completo. Por eso las vistas basadas en mensajes usan nombres `*_from_messages` y columnas `*_observed`.

### Riesgo 2: Handoff No Tiene Fuente Funcional Explícita

Hoy se puede detectar intervencion humana observada por mensajes de operador o `first_human_response_at`, pero eso no equivale siempre a motivo formal de handoff. La vista usa `handoff_to_human_aprox`.

### Riesgo 3: Resolucion/Cierre No Es Confiable Aun

El DDL tiene `resolved_flag`, `resolution_type`, `closed_by`, `closed_at`, pero los fixtures actuales no traen eventos de cierre claros. La capa SQL no inventa cierre; deja `resolution_time_seconds` en NULL salvo que exista `closed_at`.

### Riesgo 4: Catalogos Prematuros

Crear catalogos de topic/subtopic/product/handoff antes de tener una taxonomia funcional estable puede rigidizar el modelo. Por ahora conviene exponer strings normalizados y resolver curadoria fuera o despues.

### Riesgo 5: Indices En Migracion No Idempotente

MySQL 8 no soporta `CREATE INDEX IF NOT EXISTS`. La migracion debe correrse una vez por ambiente. Si se necesita rerun idempotente, se deberia envolver con un runner que consulte `information_schema.statistics`.

### Riesgo 6: `product` Sobrecargado Con Actividad

Con datos reales observados, `AP_Actividad` trae valores como:

- `Fotografía`
- `Trabajo en altura 30 metros`
- `Construcciones`
- `Albañil y pintor`

Eso no se comporta como `product` estable sino como actividad/oficio/motivo operativo. Por eso la recomendacion es no seguir poblando `product` desde `AP_Actividad`.

## Recomendaciones Previas A Poblar Datos

### Cambios Recomendados De Base De Datos

Bloqueantes antes de dashboards:

- Aplicar `database/migrations/20260420_grafana_analytics_layer.sql` para crear indices y vistas.
- En ambientes ya migrados, usar `database/migrations/20260421_grafana_views_refresh.sql` cuando cambie la definicion de una view o aparezcan columnas derivadas nuevas como `motivo_consulta_aprox`.

No bloqueantes:

- Evaluar una tabla puente raw-normalized si se necesita auditoria forense fina, no para Grafana.
- Evaluar catalogos de topic/subtopic/product/handoff cuando haya taxonomia validada.

No recomendado ahora:

- Poblar `conversation_metrics` desde lambdas en linea.
- Agregar columnas de cierre/resolucion si no existe un payload que las alimente.
- Crear tablas duplicadas de mensajes o snapshots.

### Cambios Recomendados De Codigo

Bloqueantes:

- Ninguno para la capa SQL de Grafana.

Recomendados para confiabilidad analitica:

- Mantener `/incoming` y `/outgoing` activos para completar `messages`.
- No poblar `conversation_metrics` en lambdas transaccionales de webhook.
- Cuando aparezcan payloads reales de cierre/resolucion, mapearlos explicitamente a `conversations.closed_at`, `closed_by`, `resolved_flag`, `resolution_type` y `handoff_reason`.
- Tratar `AP_Actividad` como `activity_name`, no como `product`.
- Exponer `motivo_consulta_aprox` en la capa analitica como campo derivado de `subtopic/topic/activity_name/product`, claramente marcado como aproximado.
- Si ya existen cargas historicas donde `product` absorbio `AP_Actividad`, reconciliarlas con `database/query_packs/20260421_activity_product_reconciliation.sql` antes de publicar breakdowns analiticos.
- Si se adopta una tabla puente de trazabilidad raw-normalized, agregar inserciones en el repositorio dentro de la misma transaccion.

### Opcional Vs Bloqueante

Bloqueante para Grafana inicial:

- Vistas e indices de la migracion.
- Refresh de views en ambientes existentes si la base ya tenia una version anterior de `vw_grafana_conversations_current` o de las vistas dependientes.

Opcional:

- Tabla puente de trazabilidad raw-normalized.
- Catalogos de clasificacion.
- Materializacion de `conversation_metrics`.

## Decision Sobre `conversation_metrics`

Recomendacion: no poblarla todavia.

Motivos:

- MySQL no tiene materialized views nativas.
- Hoy hay metricas que son exactas solo si `messages` esta completo.
- Poblarla desde lambdas mezclaria ingesta operacional con agregacion analitica.
- Un error de orden temporal o reintento podria dejar agregados inconsistentes.

Uso futuro recomendado:

- Convertir `conversation_metrics` en tabla derivada/materializada poblada por un job batch o scheduled Lambda.
- Recalcular por `conversation_id` a partir de `conversations`, `messages`, snapshots y contexts.
- Usarla cuando el volumen haga caras las vistas para Grafana.

## Metricas Exactas Vs Aproximadas

### Exactas Hoy Con El Estado Actual

Asumiendo que cada endpoint persiste segun el codigo actual:

- Ingestion raw por endpoint/status/dia desde `webhook_events_raw`.
- Conversaciones actuales por canal/status/cola desde `conversations`.
- Snapshots por estado/cola/dia desde `conversation_snapshots`.
- Bot muted y pending messages por snapshot desde `conversation_snapshots`.
- Ultimo contexto observado por conversacion desde `conversation_contexts`.
- Intents ejecutados observados en snapshots desde `conversation_snapshots.executed_intents_json`.
- Operadores observados en `/outgoing` o `LAST_MESSAGE` de `/status`.

### Aproximadas Hoy

Marcadas con `_aprox` en vistas o documentadas como `observed`:

- `handoff_to_human_aprox`: presencia de humano observada, no motivo formal de handoff.
- `time_to_first_bot_response_seconds_aprox`: usa `conversation_started_at` si falta `first_user_message_at`.
- `time_to_first_human_response_seconds_aprox`: usa `conversation_started_at` si falta `first_user_message_at`.
- `motivo_consulta_aprox`: hoy se deriva de `subtopic/topic/activity_name/product`; con los datos actuales suele caer en `activity_name`.
- Conteos desde `messages` si solo se pobla `/status`: son mensajes observados, no total real.
- `interaction_mode_observed` si no esta completo el timeline.

### Exactas Cuando `/incoming` Y `/outgoing` Esten Completos

- Conteo de mensajes por customer/bot/operator.
- Ratio bot-only / human-only / mixed.
- Tiempo a primera respuesta humana desde primer mensaje usuario.
- Tiempo a primera respuesta bot desde primer mensaje usuario.
- Volumen por operador/cola/canal.
- Adjuntos por actor.
- Deteccion de intervencion humana basada en mensajes.

### No Soportadas Aun Sin Mas Data

- Quien cierra la conversacion, salvo que llegue `closed_by`.
- Tiempo de resolucion exacto, salvo que llegue `closed_at`.
- Motivo formal de derivacion a humano, salvo que llegue `handoff_reason` o una variable equivalente.
- Resultado de journey si no hay variable confiable de journey/outcome.

## Capa SQL Propuesta Para Grafana

Migracion:

- `database/migrations/20260420_grafana_analytics_layer.sql`

Views principales:

- `vw_grafana_raw_ingestion_health_daily`
- `vw_grafana_conversation_latest_context`
- `vw_grafana_conversation_message_metrics_from_messages`
- `vw_grafana_conversations_current`
- `vw_grafana_conversations_daily`
- `vw_grafana_queue_channel_status_current`
- `vw_grafana_conversation_snapshots`
- `vw_grafana_snapshots_daily`
- `vw_grafana_executed_intents`
- `vw_grafana_intents_daily`
- `vw_grafana_messages_from_messages`
- `vw_grafana_messages_daily_from_messages`
- `vw_grafana_operator_volume_from_messages`
- `vw_grafana_resolution_current`
- `vw_grafana_handoff_to_human_aprox`
- `vw_grafana_activity_motive_breakdown_current`

Estrategia:

- Grafana deberia consultar vistas, no tablas base, salvo investigaciones puntuales.
- Los paneles de estado actual usan `vw_grafana_conversations_current` y agregadas derivadas.
- Los paneles historicos de estado usan snapshots.
- Los paneles de mensajes/operadores usan vistas `*_from_messages`.
- Los paneles aproximados deben mostrar esa condicion en el titulo o descripcion.

## SQL Propuesto

El SQL ejecutable esta en:

```text
database/migrations/20260420_grafana_analytics_layer.sql
```

Incluye:

- indices compuestos para consultas frecuentes;
- vistas de salud de ingesta;
- vistas de conversaciones actuales;
- vistas de snapshots;
- expansion de intents con `JSON_TABLE`;
- vistas de mensajes y operador;
- vistas de resolucion y handoff aproximado.

No incluye:

- nuevas tablas operativas;
- catalogos prematuros;
- inserts/updates de `conversation_metrics`;
- alteraciones de columnas funcionales sin fuente real.

## Ejemplos De Consumo

Nota de uso:

- Version `Grafana`: usa macros como `$__timeFilter`, `$__timeFrom()` y `$__timeTo()`. Solo funcionan dentro de Grafana.
- Version `MySQL`: reemplaza las macros por fechas literales o variables de sesion. Sirve para MySQL Workbench, DBeaver o consola.

### Conversaciones Por Dia / Canal / Estado / Cola

Version Grafana:

```sql
SELECT
    TIMESTAMP(conversation_date) AS time,
    channel,
    status_current,
    queue_name,
    SUM(conversation_count) AS conversations
FROM vw_grafana_conversations_daily
WHERE $__timeFilter(TIMESTAMP(conversation_date))
GROUP BY
    conversation_date,
    channel,
    status_current,
    queue_name
ORDER BY conversation_date;
```

Version MySQL:

```sql
SELECT
    TIMESTAMP(conversation_date) AS time,
    channel,
    status_current,
    queue_name,
    SUM(conversation_count) AS conversations
FROM vw_grafana_conversations_daily
WHERE conversation_date BETWEEN DATE('2026-04-20') AND DATE('2026-04-21')
GROUP BY
    conversation_date,
    channel,
    status_current,
    queue_name
ORDER BY conversation_date;
```

### Estado Actual Por Cola Y Canal

```sql
SELECT
    channel,
    queue_name,
    status_current,
    conversation_count
FROM vw_grafana_queue_channel_status_current
ORDER BY conversation_count DESC;
```

### Evolucion Temporal De Snapshots

Version Grafana:

```sql
SELECT
    TIMESTAMP(snapshot_date) AS time,
    channel,
    status_current,
    SUM(snapshot_count) AS snapshots,
    SUM(conversation_count) AS conversations
FROM vw_grafana_snapshots_daily
WHERE $__timeFilter(TIMESTAMP(snapshot_date))
GROUP BY
    snapshot_date,
    channel,
    status_current
ORDER BY snapshot_date;
```

Version MySQL:

```sql
SELECT
    TIMESTAMP(snapshot_date) AS time,
    channel,
    status_current,
    SUM(snapshot_count) AS snapshots,
    SUM(conversation_count) AS conversations
FROM vw_grafana_snapshots_daily
WHERE snapshot_date BETWEEN DATE('2026-04-20') AND DATE('2026-04-21')
GROUP BY
    snapshot_date,
    channel,
    status_current
ORDER BY snapshot_date;
```

### Ranking De Intents

Version Grafana:

```sql
SELECT
    intent_name,
    SUM(intent_occurrence_count) AS occurrences,
    SUM(conversation_count) AS conversations
FROM vw_grafana_intents_daily
WHERE $__timeFilter(TIMESTAMP(intent_date))
GROUP BY intent_name
ORDER BY occurrences DESC
LIMIT 20;
```

Version MySQL:

```sql
SELECT
    intent_name,
    SUM(intent_occurrence_count) AS occurrences,
    SUM(conversation_count) AS conversations
FROM vw_grafana_intents_daily
WHERE intent_date BETWEEN DATE('2026-04-20') AND DATE('2026-04-21')
GROUP BY intent_name
ORDER BY occurrences DESC
LIMIT 20;
```

### Conversaciones Con Handoff Humano Aproximado

Version Grafana:

```sql
SELECT
    conversation_external_id,
    channel,
    current_queue_name,
    topic,
    subtopic,
    first_human_response_at,
    handoff_detection_basis_aprox
FROM vw_grafana_handoff_to_human_aprox
WHERE $__timeFilter(COALESCE(conversation_started_at, first_human_response_at))
ORDER BY first_human_response_at DESC;
```

Version MySQL:

```sql
SELECT
    conversation_external_id,
    channel,
    current_queue_name,
    topic,
    subtopic,
    first_human_response_at,
    handoff_detection_basis_aprox
FROM vw_grafana_handoff_to_human_aprox
WHERE COALESCE(conversation_started_at, first_human_response_at)
      BETWEEN TIMESTAMP('2026-04-20 00:00:00') AND TIMESTAMP('2026-04-21 23:59:59')
ORDER BY first_human_response_at DESC;
```

### Volumen Por Operador

Version Grafana:

```sql
SELECT
    TIMESTAMP(message_date) AS time,
    operator_name,
    operator_email,
    SUM(outbound_message_count) AS outbound_messages,
    SUM(conversation_count) AS conversations
FROM vw_grafana_operator_volume_from_messages
WHERE $__timeFilter(TIMESTAMP(message_date))
GROUP BY
    message_date,
    operator_name,
    operator_email
ORDER BY message_date, outbound_messages DESC;
```

Version MySQL:

```sql
SELECT
    TIMESTAMP(message_date) AS time,
    operator_name,
    operator_email,
    SUM(outbound_message_count) AS outbound_messages,
    SUM(conversation_count) AS conversations
FROM vw_grafana_operator_volume_from_messages
WHERE message_date BETWEEN DATE('2026-04-20') AND DATE('2026-04-21')
GROUP BY
    message_date,
    operator_name,
    operator_email
ORDER BY message_date, outbound_messages DESC;
```

### Breakdown Por Activity / Motivo / Product

```sql
SELECT
    activity_name,
    motivo_consulta_aprox,
    topic,
    subtopic,
    product,
    SUM(conversation_count) AS conversations,
    SUM(handoff_to_human_count_aprox) AS handoffs_aprox,
    AVG(avg_time_to_first_human_response_seconds) AS avg_first_human_response_seconds
FROM vw_grafana_activity_motive_breakdown_current
GROUP BY
    activity_name,
    motivo_consulta_aprox,
    topic,
    subtopic,
    product
ORDER BY conversations DESC;
```

### Tiempo De Primera Respuesta

Version Grafana:

```sql
SELECT
    channel,
    current_queue_name,
    AVG(time_to_first_bot_response_seconds) AS avg_first_bot_response_seconds,
    AVG(time_to_first_human_response_seconds) AS avg_first_human_response_seconds,
    AVG(time_to_first_bot_response_seconds_aprox) AS avg_first_bot_response_seconds_aprox,
    AVG(time_to_first_human_response_seconds_aprox) AS avg_first_human_response_seconds_aprox
FROM vw_grafana_conversations_current
WHERE $__timeFilter(COALESCE(conversation_started_at, last_message_at))
GROUP BY
    channel,
    current_queue_name;
```

Version MySQL:

```sql
SELECT
    channel,
    current_queue_name,
    AVG(time_to_first_bot_response_seconds) AS avg_first_bot_response_seconds,
    AVG(time_to_first_human_response_seconds) AS avg_first_human_response_seconds,
    AVG(time_to_first_bot_response_seconds_aprox) AS avg_first_bot_response_seconds_aprox,
    AVG(time_to_first_human_response_seconds_aprox) AS avg_first_human_response_seconds_aprox
FROM vw_grafana_conversations_current
WHERE COALESCE(conversation_started_at, last_message_at)
      BETWEEN TIMESTAMP('2026-04-20 00:00:00') AND TIMESTAMP('2026-04-21 23:59:59')
GROUP BY
    channel,
    current_queue_name;
```

### Salud De Ingesta

Version Grafana:

```sql
SELECT
    TIMESTAMP(event_date) AS time,
    source_endpoint,
    processing_status,
    SUM(event_count) AS events
FROM vw_grafana_raw_ingestion_health_daily
WHERE $__timeFilter(TIMESTAMP(event_date))
GROUP BY
    event_date,
    source_endpoint,
    processing_status
ORDER BY event_date;
```

Version MySQL:

```sql
SELECT
    TIMESTAMP(event_date) AS time,
    source_endpoint,
    processing_status,
    SUM(event_count) AS events
FROM vw_grafana_raw_ingestion_health_daily
WHERE event_date BETWEEN DATE('2026-04-20') AND DATE('2026-04-21')
GROUP BY
    event_date,
    source_endpoint,
    processing_status
ORDER BY event_date;
```

## Criterio Para Evolucion Futura

Crear tablas auxiliares solo cuando exista una razon funcional concreta:

- Catalogo de topics/subtopics/products: cuando haya taxonomia versionada y reglas de normalizacion.
- Catalogo de handoff reasons: cuando el payload tenga motivos confiables o reglas de clasificacion aprobadas.
- Tabla puente raw-normalized: cuando auditoria requiera reconstruir exactamente que raw afecto que entidad.
- Materializacion de `conversation_metrics`: cuando el volumen haga costosas las vistas o se requieran snapshots de metricas cerradas.
