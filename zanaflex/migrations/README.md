# Zanaflex — Migrations SQL (Supabase)

Camada de banco de dados para o piloto Zanaflex (auth + permissionamento por equipes + categorias + RAG com upsert atômico por documento).

Roda no mesmo Supabase self-hosted da Sameka (`longflatworm-supabase.cloudfy.live`). Todos os objetos usam o prefixo **`zanaflex_`** — convivem sem colisão com `sameka_*`, `aspiramaq_*`.

## Ordem de execução

Execute na **ordem numérica**, uma de cada vez (Supabase Dashboard → SQL Editor → New query → cole o conteúdo → Run). Cada arquivo é idempotente o suficiente para re-execução, mas **não pule números**.

| # | Arquivo | O que faz |
|---|---------|-----------|
| 001 | `001_user_crud_functions.sql` | RPCs `list/confirm/update/delete_user` |
| 002 | `002_add_roles.sql` | Adiciona `role` ao payload (default `visualizador`) |
| 003 | `003_admin_guards.sql` | `zanaflex_is_admin()` + guards em todas as RPCs |
| 004 | `004_add_company_name.sql` | Filtro de tenant `company_name = 'zanaflex'`; adiciona `zanaflex_is_member()` |
| 005 | `005_prevent_self_delete.sql` | Admin não pode deletar a si mesmo |
| 006 | `006_document_categories.sql` | Tabela `zanaflex_document_categories` + CRUD admin |
| 007 | `007_teams_and_acl.sql` | Tabelas `zanaflex_teams`, `team_members`, `team_category_access` + CRUD admin + helper `zanaflex_user_allowed_categories()` |
| 008 | `008_rag_documents_acl.sql` | Schema RAG (`zanaflex_documents`, `document_metadata`, `document_rows`) com `category_id` na metadata; `zanaflex_match_documents()` filtra por ACL |
| 009 | `009_rag_upsert_replace.sql` | `zanaflex_rag_purge_file()` (substitui só os chunks daquele `file_id`), `zanaflex_rag_upsert_metadata()`, listagens admin/user |
| 010 | `010_chat_user_id.sql` | Tabela `zanaflex_chat_message` + trigger que extrai `user_id` |
| 011 | `011_seed_it_category.sql` | Seed da categoria `IT — Instrução de Trabalho` |
| 012 | `012_match_for_user.sql` | Variantes `_for_user(p_user_id, ...)` para chamadas service_role do n8n |
| 013 | `013_set_user_teams.sql` | RPC `zanaflex_admin_set_user_teams()` para sincronizar equipes de um usuário |
| 014 | `014_match_documents_filter_acl.sql` | `zanaflex_match_documents()` agora honra `filter->'allowed_category_ids'` (usado pelo n8n Supabase Vector Store) |
| 015 | `015_seed_admin_user.sql` | Seed do primeiro usuário admin (bootstrap) |
| 016 | `016_fix_legacy_metadata_schema.sql` | Patch idempotente: adiciona `file_id`/`code`/`source`/`mime_type`/`category_id`/`updated_at` em bancos legados criados pelo node "Webhook Setup" do workflow `Zanaflex-RAG`; converte `schema TEXT → JSONB`; instala FK para `zanaflex_document_categories` e trigger de `updated_at` |

> **Importante:** os 37 PDFs em `RAG/` **não** são seedados via SQL. Eles são ingeridos pelo workflow `Zanaflex-RAG` (próxima fase) que chama `zanaflex_rag_purge_file()` + reinsere chunks para cada `file_id`. Assim, atualizar um IT recalcula só os chunks **daquele** documento.

## Bootstrap do primeiro admin

Depois de rodar as 14 migrations, crie o usuário admin pelo painel Supabase (Authentication → Users → Add user). Em seguida, no SQL Editor:

```sql
UPDATE auth.users
   SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
       || '{"role":"admin","company_name":"zanaflex","full_name":"Admin Zanaflex"}'::jsonb
 WHERE email = 'admin@zanaflex.com.br';
```

A partir daí, esse usuário pode logar pela UI e gerenciar categorias, equipes e usuários.

## Modelo de permissionamento

```
auth.users  ──(team_members)──>  zanaflex_teams  ──(team_category_access)──>  zanaflex_document_categories
                                                                                          │
                                                                                          ▼
                                                              zanaflex_document_metadata.category_id
                                                                                          │
                                                                                          ▼
                                                                            zanaflex_documents.metadata->>'file_id'
```

Resolução para um usuário comum:

```
allowed_categories(user) = ⋃ team.categories  ∀ team ∈ teams(user)
```

`zanaflex_match_documents(...)` JOINa `zanaflex_documents → document_metadata → category_id` e filtra. **Admin enxerga todas** (`zanaflex_is_admin()` é true).

## Mudança vs Sameka

Pontos que **não foram portados** da Sameka (não se aplicam ao piloto Zanaflex):

- Campos `estados` / `cidades` de cobertura geográfica (Sameka 005) — substituídos pelo modelo de equipes × categorias.
- Backfill global de `company_name` (não há usuários legados Zanaflex).

Pontos **novos** em relação à Sameka:

- Tabela `zanaflex_document_categories` (006).
- Modelo de equipes com many-to-many em categorias (007).
- Schema RAG completo com FK para categoria + `zanaflex_match_documents()` ACL-aware (008).
- `zanaflex_rag_purge_file()` para upsert atômico por arquivo (009).

## Verificação manual rápida

Depois de rodar tudo, no SQL Editor (logado como o admin via `set_config`):

```sql
-- 1) sou admin?
SELECT zanaflex_is_admin();
-- 2) categorias visíveis para mim
SELECT * FROM zanaflex_list_categories();
-- 3) docs do RAG visíveis para mim (deve estar vazio até o RAG indexar)
SELECT * FROM zanaflex_list_rag_documents();
-- 4) listar usuários (admin-only)
SELECT * FROM zanaflex_admin_list_users();
```

Como usuário comum sem equipe (negativo):
```sql
SELECT zanaflex_list_rag_documents();  -- 0 linhas (sem categoria permitida)
```

## Down / rollback

Cada arquivo tem um bloco `DOWN` comentado no final. Para reverter, execute-os na **ordem inversa** (011 → 001).
