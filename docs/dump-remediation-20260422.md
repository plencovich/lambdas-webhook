# Remediacion Tecnica 2026-04-22

Implementacion aplicada a partir de `docs/dump-audit-20260422.md`.

## Cambios de codigo

- `src/mappers/common.py`
  - agrega normalizacion compartida de strings null-like y split de nombres
- `src/mappers/incoming_mapper.py`
  - usa normalizacion comun para texto y nombres
- `src/mappers/outgoing_mapper.py`
  - usa normalizacion comun para texto
- `src/mappers/status_mapper.py`
  - reemplaza captura dinamica por prefijos por allowlist explicita
  - excluye PII/secrets de `conversation_contexts.context_json`
  - mantiene claves utiles para reporting
  - agrega soporte de `image` en `LAST_MESSAGE`
- `src/repositories/webhook_repository.py`
  - evita que `/status` degrade `messages.client_payload`
  - evita que `/status` degrade `attachment_type`
  - evita inserts redundantes en `conversation_contexts`

## Tests agregados

- `tests/test_status_mapper.py`
- `tests/test_repository_merge_rules.py`
- `tests/test_incoming_mapper.py`

Cobertura nueva:

- exclusion de PII en status mapper
- preservacion de payload nativo rico sobre status
- preservacion y mejora de `attachment_type`
- dedupe de contextos identicos
- normalizacion de strings null-like
- no regresion de `AP_Actividad` hacia `product`

## SQL nuevo

Reconciliacion historica:

- `database/reconciliation/20260422_reconcile_context_cleanup.sql`
- `database/reconciliation/20260422_reconcile_message_merge_artifacts.sql`
- `database/reconciliation/20260422_reconcile_null_like_text.sql`

Query packs organizados:

- `database/query_packs/grafana/`
- `database/query_packs/mysql/`

## Validacion local

- `python3 -m unittest discover -s tests -p 'test_*.py'`
