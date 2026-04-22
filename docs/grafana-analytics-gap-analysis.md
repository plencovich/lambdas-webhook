# Grafana Analytics Gap Analysis

## Resumen Ejecutivo

Validé la capa analítica contra el esquema del repo, las migraciones SQL existentes y los backups exportados en `temp/` con fecha 2026-04-21. La base actual alcanza para una primera capa usable en Grafana sin poblar `conversation_metrics` ni agregar tablas nuevas, pero había cuatro problemas reales que impedían considerarla consistente:

1. `topic` y `subtopic` no tienen cobertura real hoy.
2. `product` está subutilizado y contaminado por valores de actividad o texto libre.
3. la resolución exacta no está soportada: `closed_at`, `closed_by` y `handoff_reason` no tienen fuente confiable en los datos observados.
4. el fallback actual de `motivo_consulta_aprox` mezclaba dimensiones heterogéneas y favorecía interpretaciones falsas.

La reconciliación propuesta deja la capa analítica alineada con la realidad observada:

- mantiene exacto solo lo que realmente viene del modelo operacional;
- marca explícitamente lo aproximado;
- deja `activity_name` como fallback analítico dominante cuando no hay taxonomía `topic/subtopic`;
- deja `product` expuesto pero sin usarlo como comodín para motivo;
- crea la vista faltante `vw_grafana_activity_motive_breakdown_current`;
- agrega auditorías para detectar desvíos post-cambio.

## Evidencia Revisada

Archivos base:

- `database/init_db.sql`
- `docs/persistence-traceability-matrix.md`

SQL existentes:

- `database/migrations/20260420_grafana_analytics_layer.sql`
- `database/migrations/20260421_grafana_views_refresh.sql`
- `database/query_packs/20260421_post_load_audit_pack.sql`
- `database/query_packs/20260421_activity_product_reconciliation.sql`

Backups observados:

- tablas: `webhook_events_raw`, `customers`, `operators`, `conversations`, `messages`, `conversation_snapshots`, `conversation_contexts`, `conversation_metrics`
- vistas: `vw_grafana_conversations_current`, `vw_grafana_resolution_current`, `vw_grafana_handoff_to_human_aprox`, `vw_grafana_messages_from_messages`, `vw_grafana_operator_volume_from_messages`

Cobertura del backup exportado:

| Entidad | Filas |
|---|---:|
| `conversations` | 26 |
| `messages` | 463 |
| `conversation_snapshots` | 409 |
| `conversation_contexts` | 408 |
| `webhook_events_raw` | 738 |
| `operators` | 2 |
| `conversation_metrics` | 0 |

Nota metodológica:

- No hubo conexión directa al RDS real desde este workspace, así que la reconciliación se hizo contra el repo y los exports provistos.
- El backup JSON de `conversation_contexts` provisto en `temp/` no es parseable tal como fue exportado porque varios `context_json` vacíos salen sin `null`.
- El CSV suplementario `backup_conversation_contexts.csv` sí es consistente: los vacíos aparecen exportados como `""`, no como JSON roto.
- En `conversation_contexts` los vacíos son esperables en muchos snapshots porque la tabla hoy funciona como historial append-only de `/status`, no como tabla “solo cuando apareció contexto nuevo”.
- Algunos exports serializan `NULL` como `""` o `0`; por eso el análisis se hizo con saneo defensivo y el SQL nuevo normaliza blanks en la capa analítica.

## Hallazgos Principales

1. `topic` y `subtopic` están en 0/26 conversaciones. Hoy no son fuente usable para breakdowns.
2. `activity_name` sí aporta señal útil: aparece en 13/26 conversaciones. En 8 casos viene de `ActividadName` y en 5 de `AP_Actividad`.
3. `motivo_consulta_aprox` en los datos actuales cae 13/13 veces en `activity_name`. No hay soporte real para derivarlo desde `product`.
4. `product` solo aparece en 3/26 conversaciones y las 3 requieren auditoría:
   - un caso claramente replica la actividad (`Fotografía` vs `Fotografo`);
   - un caso es un valor distinto pero no validado (`Artista` vs `Acrobacia en tela`);
   - un caso contiene texto libre largo, impropio de un producto.
5. `resolved_flag` solo tiene señal explícita en 4 conversaciones. `closed_at`, `closed_by` y `handoff_reason` no tienen cobertura real.
6. `handoff_to_human_aprox` es razonable como señal observada: 24/26 conversaciones y en todos los casos observados la base es `first_human_response_at`.
7. `interaction_mode_observed` hoy es fuerte: 21 `mixed`, 3 `human_only`, 2 `bot_only`.
8. Hay duplicación esperable en snapshots y contexts: 66 pares duplicados por `(conversation_id, snapshot_at)` en ambos historiales, típicamente por `delivered/read` con mismo timestamp. Esto hace riesgoso contar snapshots brutos sin deduplicación conceptual.
9. Hay 2 anomalías temporales reales:
   - 1 conversación con `first_human_response_at < first_user_message_at`
   - 1 conversación con `first_bot_response_at < first_user_message_at`
10. La revisión del CSV de `conversation_contexts` confirmó que la sparsidad es real y no un error de parseo:
   - `topic` y `subtopic` están vacíos en 436/436 filas;
   - `activity_name` solo aparece en 169/436 filas;
   - `context_json` aparece en 318/436 filas;
   - `completion_message_text` aparece en 110/436 filas.

## Cobertura De Preguntas De Negocio

| Pregunta de negocio | Estado actual | Fuente SQL actual | Calidad | Recomendación |
|---|---|---|---|---|
| ¿Quién cierra la conversación? | No soportada | `vw_grafana_conversations_current.last_message_sender_type` solo como contexto, no como cierre | Insuficiente | No inferir `closed_by`; mapear evento/campo explícito de cierre cuando exista |
| ¿Cuánto tarda en resolverse? | No soportada | `vw_grafana_resolution_current.resolution_time_seconds` | Insuficiente | Mantener `resolution_time_seconds` exacto solo con `closed_at`; no aproximar con `last_message_at` |
| ¿Se resolvió o no? | Soportada parcialmente | `vw_grafana_resolution_current.resolved_flag`, `resolved_flag_source`, `resolution_data_quality` | Exacta solo cuando llega `IssueResuelto`; insuficiente si no | Mostrar bucket `resolution_not_supported` y no tratarlo como `no resuelto` |
| ¿Qué canal usó? | Soportada | `vw_grafana_conversations_current`, `vw_grafana_messages_from_messages` | Exacta | Sin cambios |
| ¿Qué tema era? | Soportada parcialmente | `vw_grafana_conversations_current.topic/subtopic/activity_name/motivo_consulta_aprox` | Aproximada | Usar `motivo_consulta_aprox` solo como fallback a `activity_name`; no usar `product` como motivo |
| ¿Intervino el bot, el operador o ambos? | Soportada | `vw_grafana_conversations_current.interaction_mode_observed` | Exacta observada con la ingesta actual | Mantener auditoría de completitud de `messages` |
| ¿Cuáles son los motivos de derivación? | No soportada | `handoff_reason` vacío; solo existe `handoff_to_human_aprox` | Insuficiente | Instrumentar motivo explícito de handoff si el negocio lo necesita |
| ¿Qué conversaciones terminan con handoff humano? | Soportada parcialmente | `vw_grafana_handoff_to_human_aprox` | Aproximada | Mantener `_aprox` en nombre/panel y auditar base de detección |
| ¿Qué journeys están funcionando y cuáles no? | Soportada parcialmente | `vw_grafana_executed_intents`, `vw_grafana_intents_daily`, queries por latest intent | Aproximada | Agregar outcome/journey stage explícito cuando el proveedor lo exponga |

## Qué Queda Bien Cubierto Hoy

- Canal, cola, estado actual, bot muted, pending messages.
- Volumen de mensajes por actor y por operador.
- Intervención bot/humano/mixta.
- Handoff humano observado.
- Intents ejecutados y proxy de “journey actual” usando latest intent.
- Actividad observada (`activity_name`) y breakdown operativo cuando no hay topic/subtopic.
- Cotizaciones generadas cuando existe `quote_external_id` o `coverage_external_id`.

## Qué Queda Parcial

- Resolución: solo hay soporte cuando aparece `IssueResuelto`; no hay cierre exacto.
- Tema/motivo: hoy depende del fallback a actividad, no de una taxonomía estable.
- Journeys funcionando/no funcionando: se puede aproximar por latest intent + handoff/resolution, pero no hay outcome explícito.
- Producto: queda visible como dimensión auditada, no como dimensión confiable de negocio.

## Qué No Se Puede Responder Todavía

- cierre exacto por actor (`closed_by`);
- timestamp exacto de cierre (`closed_at`);
- tiempo de resolución exacto;
- motivo formal de derivación (`handoff_reason`);
- stage/outcome formal del journey (`journey_stage` sigue vacío).

## Riesgos De Calidad Actuales

1. `product` sigue siendo una dimensión insegura si se usa sin auditoría. En los datos reales observados no se comporta como taxonomía robusta.
2. Los exports no preservan bien algunos `NULL`; si se analizan fuera de MySQL sin saneo, pueden aparecer ceros o strings vacíos engañosos.
3. `conversation_snapshots` y `conversation_contexts` contienen duplicados temporales legítimos por `delivered/read`; cualquier conteo bruto puede sobreestimar actividad.
4. Existen outliers de orden temporal. No son muchos, pero invalidan promedios si se usan sin filtro.
5. `resolved_flag = NULL` significa “sin soporte”, no “no resuelto”.

## Recomendaciones SQL Aplicables Ya

Aplicadas en `database/migrations/20260422_grafana_analytics_reconciliation.sql`:

1. Normalizar blanks a `NULL` en vistas analíticas.
2. Rehacer `vw_grafana_conversation_latest_context` exponiendo:
   - `activity_name_source`
   - `activity_code`
   - `ap_actividad`
   - `busqueda_actividad_flag`
   - `issue_resuelto_flag`
3. Rehacer `vw_grafana_conversations_current` para:
   - dejar `motivo_consulta_aprox` sin fallback a `product`
   - publicar `motivo_consulta_source_aprox`
   - publicar `classification_quality`
   - publicar `product_data_quality`
   - publicar `resolved_flag_source`
   - publicar `handoff_detection_basis_aprox`
   - publicar `timeline_quality`
4. Rehacer `vw_grafana_resolution_current` y `vw_grafana_handoff_to_human_aprox` para que reflejen esa semántica.
5. Crear la vista faltante `vw_grafana_activity_motive_breakdown_current`.
6. Agregar el índice `idx_conversation_contexts_activity_snapshot` si no existe.

## Recomendaciones De Código Futuras

Bloqueantes para mayor confiabilidad futura:

1. Persistir un evento o variable explícita de cierre para llenar `closed_at` y `closed_by`.
2. Persistir motivo formal de handoff si Botmaker lo expone o si el flujo lo conoce.
3. Persistir una taxonomía real para `topic` / `subtopic` si existe a nivel producto/negocio.
4. Persistir `journey_stage` o outcome explícito si la pregunta de negocio sobre journeys es prioritaria.

Recomendadas pero no bloqueantes:

1. Mantener `AP_Actividad` y `ActividadName` solo como actividad/motivo operativo, no como producto.
2. Si aparece una dimensión producto real, persistirla en un campo distinto de actividad.
3. Mantener la carga de `/incoming` y `/outgoing` como fuente fuerte para `messages`.
4. No poblar `conversation_metrics` desde las lambdas transaccionales; si alguna vez se materializa, que sea por job batch/recalc.

## Exacto Vs Aproximado Por Métrica

| Métrica / dimensión | Estado recomendado |
|---|---|
| `channel`, `status_current`, `current_queue_name` | Exacta |
| `interaction_mode_observed` | Exacta observada |
| `message_count_*_observed` | Exacta observada con la ingesta actual; mantener auditoría |
| `activity_name` | Exacta respecto al snapshot/contexto observado |
| `motivo_consulta_aprox` | Aproximada |
| `handoff_to_human_aprox` | Aproximada |
| `time_to_first_bot_response_seconds` | Exacta cuando `timeline_quality = ok` |
| `time_to_first_human_response_seconds` | Exacta cuando `timeline_quality = ok` |
| `time_to_first_*_seconds_aprox` | Aproximada |
| `resolved_flag` | Exacta solo cuando `resolved_flag_source = IssueResuelto` |
| `resolution_time_seconds` | Exacta solo con `closed_at`; hoy no soportada en práctica |
| `product` | No confiable aún como dimensión analítica primaria |

## Archivos Nuevos Relacionados

- `database/migrations/20260422_grafana_analytics_reconciliation.sql`
- `database/query_packs/20260422_grafana_validation_queries.sql`
- `database/query_packs/20260422_grafana_panel_queries.sql`

## Criterio De Uso En Grafana

- Usar `vw_grafana_conversations_current` para estado actual, clasificación y mix de actores.
- Usar `vw_grafana_resolution_current` solo para métricas exactas o buckets de soporte.
- Usar `vw_grafana_handoff_to_human_aprox` con el sufijo `_aprox` visible en paneles.
- Usar `vw_grafana_activity_motive_breakdown_current` para breakdowns de actividad/motivo.
- No usar `product` como eje principal hasta validar su semántica con nuevos datos o con una taxonomía explícita.
