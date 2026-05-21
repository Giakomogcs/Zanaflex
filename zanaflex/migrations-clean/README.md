# Zanaflex — Migrations (clean) para Supabase novo

Versão consolidada e enxuta das 20 migrations originais, pensada para rodar do zero num Supabase limpo. Cada arquivo tem o bloco `DOWN` comentado no final.

## Ordem de execução

Execute na ordem numérica, uma de cada vez (Supabase Dashboard → SQL Editor → New query → cole → Run):

| # | Arquivo | Conteúdo | Origem (das antigas) |
|---|---------|----------|----------------------|
| 001 | `001_users_and_admin.sql`  | Helpers `zanaflex_is_admin/is_member`, CRUD de usuários, guards admin-only, anti self-delete, `set_user_teams` | 001 + 002 + 003 + 004 + 005 + 013 |
| 002 | `002_categories.sql`       | Tabela de categorias com `drive_folder_id` + RPCs admin + lookup helper | 006 + 017 |
| 003 | `003_teams_and_acl.sql`    | Equipes, membros, ACL team×categoria + helpers `user_allowed_categories[_for]` | 007 + 012 (helper) |
| 004 | `004_rag_schema.sql`       | pgvector + tabelas RAG + upsert/purge atômicos + listagens | 008 + 009 + 016 (trigger updated_at) |
| 005 | `005_match_documents.sql`  | `match_documents` final (ACL via filter, service_role bypass, enrichment) + variante `_for_user` | 008 + 012 + 014 + 019 + 020 |
| 006 | `006_chat_messages.sql`    | Tabela `zanaflex_chat_message` (com `user_id`) + trigger | 010 + 018 |
| 007 | `007_seeds.sql`            | Seed categoria `IT` + admin bootstrap (`admin@zanaflex.com.br` / `@Admin123`) | 011 + 015 |

## O que ficou de fora (e por quê)

- **016** (`fix_legacy_metadata_schema`): patch para corrigir bancos legados criados pelo node "Webhook Setup" antigo. Num Supabase novo o schema já nasce certo (incluído direto no 004), então não precisa.
- **018** (`fix_chat_user_id_column`): patch idem — a coluna `user_id` agora já nasce no `CREATE TABLE` do 006.
- **014 / 019**: versões intermediárias de `match_documents`. Substituídas pela versão final no 005 (020).
- O backfill de `user_id` em mensagens antigas (parte do 018) não se aplica num banco vazio.

## Pós-instalação

1. Faça login com `admin@zanaflex.com.br` / `@Admin123` e **troque a senha** imediatamente.
2. Configure o `drive_folder_id` da categoria `IT` pela UI (página Categorias) ou via SQL.
3. Ingerir documentos pelo workflow n8n `Zanaflex-RAG` (cada upload chama `zanaflex_rag_purge_file()` + `zanaflex_rag_upsert_metadata()`).

## Rollback

Cada arquivo tem o bloco `-- =======  DOWN  ========` no final, com os `DROP`/`DELETE` comentados. Para reverter tudo, descomente e execute na ordem inversa (007 → 001).
