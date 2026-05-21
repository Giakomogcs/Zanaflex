# Zanaflex — Agente IA + RAG

Projeto do **agente de IA da Zanaflex** que responde perguntas sobre Instruções de Trabalho (IT), Normas Regulamentadoras (NR) e outros documentos internos da empresa, com **ACL por equipe/categoria**, **upload pelo chat** e **integração com o ERP**.

Toda a documentação técnica detalhada está em [`zanaflex/`](zanaflex/README.md). Este arquivo é a **visão geral** — leia primeiro.

---

## Sumário

- [Arquitetura em 1 página](#arquitetura-em-1-página)
- [Como o agente funciona (fluxo de uma pergunta)](#como-o-agente-funciona-fluxo-de-uma-pergunta)
- [Como um documento entra no RAG](#como-um-documento-entra-no-rag)
- [ACL: quem vê o quê](#acl-quem-vê-o-quê)
- [Componentes](#componentes)
- [Stack e credenciais](#stack-e-credenciais)
- [Setup do zero](#setup-do-zero)
- [Operação do dia a dia](#operação-do-dia-a-dia)
- [Estrutura de pastas](#estrutura-de-pastas)

---

## Arquitetura em 1 página

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          NAVEGADOR (front-zanaflex.html)                    │
│  Chat · Login · Páginas Admin (Usuários, Equipes, Categorias, Documentos)   │
└───────────────────┬──────────────────────────────────────┬──────────────────┘
                    │ Auth (Supabase JS SDK)               │ Webhooks (n8n)
                    ▼                                      ▼
       ┌──────────────────────────┐         ┌──────────────────────────────┐
       │  Supabase (Postgres +    │         │  n8n (longflatworm.cloudfy)  │
       │  pgvector + Auth +       │◄────────┤                              │
       │  Storage)                │  SQL    │  7 workflows:                │
       │                          │         │  - Zanaflex-Front            │
       │  - zanaflex_users        │         │  - Zanaflex-Agent-IA  ◄── chat
       │  - zanaflex_teams        │         │  - Zanaflex-RAG       ◄── ingest
       │  - zanaflex_documents    │         │  - Zanaflex-RAG-Admin ◄── CRUD docs
       │    (vetores 1536d)       │         │  - Chat GET/DELETE × 3       │
       │  - zanaflex_document_*   │         └────────┬──────────────┬──────┘
       │  - zanaflex_chat_message │                  │              │
       └──────────────────────────┘                  │              │
                                                     ▼              ▼
                                          ┌──────────────────┐  ┌──────────┐
                                          │  Azure OpenAI    │  │  Google  │
                                          │  - embeddings    │  │  Drive   │
                                          │    text-emb-3-sm │  │  (PDFs)  │
                                          │  - chat gpt-5.x  │  │          │
                                          │  - OCR Responses │  │          │
                                          └──────────────────┘  └──────────┘
```

---

## Como o agente funciona (fluxo de uma pergunta)

1. **Usuário pergunta no chat** (ex: *"Qual o EPI obrigatório na pesagem de produtos químicos?"*).
   O front faz `POST /webhook/zanaflex-AgentRag` com `{ sessionId, userId, message }`.

2. **`Zanaflex-Agent-IA`** (n8n) recebe a mensagem:
   - **`Prepare Input`** antepõe um bloco `[CONTEXTO DO USUÁRIO: nome=... ID="uuid"]` à mensagem.
     Esse bloco é o que o trigger SQL usa para gravar `user_id` em `zanaflex_chat_message` (sem precisar de coluna extra no nó memory do n8n).
   - **`Postgres Chat Memory`** carrega o histórico daquela `sessionId`.
   - **Agente LangChain** (Azure OpenAI `gpt-5.x`) decide entre 2 tools:
     - **`search_knowledge_base`** → embedding da query + `zanaflex_match_documents_for_user(userId, embedding, k, filter)`.
       Retorna trechos **filtrados pela ACL do usuário** (admin vê tudo; demais veem só categorias permitidas para suas equipes).
     - **`get_document_metadata`** → busca um IT específico por código (`IT-18.05`), também passando por ACL.
   - O agente compõe a resposta citando os trechos. Se a query não retornou nada relevante para aquele usuário, responde *"não encontrei / sem acesso"*.

3. **Resposta retorna ao front** e a mensagem AI é salva em `zanaflex_chat_message` (o trigger preenche `user_id`).

4. **Listagens** (`/zanaflex-sessions`, `/zanaflex-history`) sempre filtram por `userId` no SQL — mesmo que um usuário descubra um `sessionId` alheio, a query devolve 0 linhas.

---

## Como um documento entra no RAG

O workflow `Zanaflex-RAG.json` concentra **3 portas de entrada** que compartilham o mesmo pipeline downstream:

| Porta de entrada                         | Quem usa                                              | Comportamento no Drive                             | TTL                |
| ---------------------------------------- | ----------------------------------------------------- | -------------------------------------------------- | ------------------ |
| `POST /webhook/zanaflex-index-drive`     | Usuário anexando arquivo a uma sessão de chat         | Cria arquivo com prefixo de data (`21-05-2026_…`) | 24 h (auto-purge)  |
| `POST /webhook/zanaflex-rag-upload`      | Botão "Adicionar Documento" do admin **e** o ERP      | Dedupe por nome exato: substitui ou cria          | permanente         |
| `POST /webhook/zanaflex-rag-reindex`     | Botões "Reprocessar" no admin (1 / N / todos)         | Não toca no Drive — só re-extrai e re-indexa      | permanente         |

**Pipeline downstream** (igual nos três):

```
Drive (download por file_id)
  → Switch por mimeType
     - PDF       → Extract PDF Text → se vazio → OCR via Azure Responses (gpt-5.4-mini visão)
     - XLSX/CSV  → Extract → grava linhas em zanaflex_document_rows
     - Google Doc/outros → Extract genérico
  → Limpeza de texto
  → Insert into Supabase Vectorstore (chunking + embeddings text-embedding-3-small)
    └─ antes, DELETE WHERE metadata->>'file_id' = <id> para evitar duplicar
  → upsert em zanaflex_document_metadata
  → Limpa RAM
```

Detalhes completos e exemplos `curl` em [`zanaflex/workspaces/README.md`](zanaflex/workspaces/README.md).

---

## ACL: quem vê o quê

A ACL é por **categoria de documento** atravessando **equipes**:

```
zanaflex_users ──┐
                 ├── zanaflex_team_members (user_id, team_id)
zanaflex_teams ──┤
                 └── zanaflex_team_category_access (team_id, category_id)
                              │
                              ▼
                    zanaflex_document_metadata (category_id)
                              │
                              ▼ filter via metadata->>'category_id'
                    zanaflex_documents (vetores)
```

- **Admins** (`zanaflex_users.role = 'admin'`) ignoram a ACL — veem tudo.
- **Usuários comuns** veem apenas categorias retornadas por `zanaflex_user_allowed_categories_for(user_id)`.
- A ACL é aplicada **dentro** das funções SQL `zanaflex_match_documents_for_user` e `zanaflex_get_document_metadata_for_user`, então é impossível burlar via webhook — o filtro acontece no Postgres, não no n8n.

---

## Componentes

### 1. Front-end ([`zanaflex/front-zanaflex.html`](zanaflex/front-zanaflex.html))

SPA num único HTML. Servida pelo workflow `Zanaflex-Front` (que devolve o HTML em `GET /webhook/zanaflex-chat`).

Funcionalidades:

- **Chat** com histórico, sessões, anexar arquivo (vira upload temporário no RAG por 24 h).
- **Login/logout** via Supabase Auth.
- **Painel admin** (apenas role `admin`):
  - Usuários: criar, editar role, atribuir equipes.
  - Equipes: CRUD, gerenciar ACL por categoria.
  - Categorias: CRUD, definir `drive_folder_id` (pasta de upload no Drive).
  - **Documentos do RAG**: listar agrupado por categoria, **selecionar com checkbox**, **Reprocessar (1/N/todos)**, **Remover**, **Apagar tudo**, **Adicionar Documento** (multipart com `categoria`).

### 2. Backend n8n ([`zanaflex/workspaces/`](zanaflex/workspaces/README.md))

7 workflows independentes — detalhes em [`zanaflex/workspaces/README.md`](zanaflex/workspaces/README.md):

| Workflow                       | Função                                                                       |
| ------------------------------ | ---------------------------------------------------------------------------- |
| `Zanaflex-Front`               | Serve o HTML do front via webhook                                            |
| `Zanaflex-Agent-IA`            | Agente LangChain (chat + tools com ACL)                                      |
| `Zanaflex-RAG`                 | Ingestão de documentos (3 webhooks unificados + trigger de reset diário)     |
| `Zanaflex-RAG-Admin`           | CRUD admin de documentos (listar, deletar, purgar, upsert direto)            |
| `Zanaflex-Chat-GET-Sessions`   | Lista sessões do usuário                                                     |
| `Zanaflex-Chat-GET-History`    | Histórico de uma sessão                                                      |
| `Zanaflex-Chat-DELETE-Session` | Apaga sessão e suas mensagens                                                |

### 3. Banco (Supabase)

Duas versões das migrations:

- [`zanaflex/migrations/`](zanaflex/migrations/README.md) — histórico real (001 → 020), aplicado incrementalmente no Supabase de produção.
- [`zanaflex/migrations-clean/`](zanaflex/migrations-clean/README.md) — versão consolidada em 7 arquivos para subir um Supabase **novo** do zero.

Tabelas principais:

- `zanaflex_users`, `zanaflex_teams`, `zanaflex_team_members`, `zanaflex_team_category_access`
- `zanaflex_document_categories` (com `drive_folder_id`)
- `zanaflex_documents` (vetores 1536d, `metadata` JSONB com `file_id`, `category_id`, `session_id`)
- `zanaflex_document_metadata` (1 linha por documento, com `last_indexed_at`, `source`)
- `zanaflex_document_rows` (linhas de planilha)
- `zanaflex_chat_message` (memória do agente, com `user_id` populado por trigger)

Funções/RPCs importantes:

- `zanaflex_is_admin(user_id)`, `zanaflex_user_allowed_categories_for(user_id)`
- `zanaflex_match_documents_for_user(user_id, embedding, k, filter)` — busca vetorial com ACL
- `zanaflex_rag_purge_file(file_id)` — apaga chunks de um único arquivo
- `zanaflex_rag_upsert_metadata(...)` — upsert atômico em `_document_metadata`
- `zanaflex_set_user_teams(user_id, team_ids[])`

---

## Stack e credenciais

| Camada           | Tecnologia                                                                      |
| ---------------- | ------------------------------------------------------------------------------- |
| Front            | HTML/CSS/JS puro · Supabase JS SDK · Lucide icons                               |
| Orquestração     | n8n (self-hosted em `longflatworm-n8n.cloudfy.live`)                            |
| LLM + embeddings | **Azure OpenAI** — `text-embedding-3-small`, `gpt-5.4-mini` (Responses p/ OCR)  |
| Banco            | **Supabase** (Postgres 15 + pgvector) em `longflatworm-supabase.cloudfy.live`   |
| Armazenamento    | **Google Drive** (uma pasta por categoria, configurada em `drive_folder_id`)    |
| Auth             | **Supabase Auth** (email/senha)                                                 |

Credenciais n8n (ids reais — não recriar):

- Postgres: `jFjeYH6Nt3aRNkoM` (`Supabase_database`)
- Google Drive OAuth: `1yxLK6IGIPQiU21B`
- Azure OpenAI: `xby4FSbCaCnssJxl`
- Supabase API: `i5Q8tj8Pyc9XjSGd`

---

## Setup do zero

1. **Subir o Supabase** (ou usar o existente) e rodar as migrations:
   - Novo: aplique `zanaflex/migrations-clean/001 → 007` em ordem (ver [README](zanaflex/migrations-clean/README.md)).
   - Existente: aplique as migrations incrementais que ainda faltam de `zanaflex/migrations/`.
2. **Configurar pastas no Drive** — uma pasta por categoria. Cole o ID na coluna `drive_folder_id` (UI → Categorias).
3. **Importar os 7 workflows** em [`zanaflex/workspaces/`](zanaflex/workspaces/README.md) no n8n e ativá-los.
4. **Trocar a senha do admin bootstrap** (`admin@zanaflex.com.br` / `@Admin123` — seed da migration 007).
5. **Cadastrar usuários e equipes** pelo painel admin e definir ACL por categoria.
6. **Ingerir documentos**:
   - Manual: botão "Adicionar Documento" no painel.
   - Em massa: o ERP da Zanaflex chama `POST /webhook/zanaflex-rag-upload` com `data` + `categoria`.
   - Reset/reload: trigger manual `When clicking 'Execute workflow'` no `Zanaflex-RAG` reindexa todas as pastas.

---

## Operação do dia a dia

| Tarefa                                   | Como fazer                                                                                                       |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Adicionar um documento                   | Painel admin → Documentos do RAG → **Adicionar Documento** → escolher categoria → upload                          |
| Substituir versão de um documento        | Upar com o **mesmo nome** pelo mesmo botão (ou via ERP) → faz update no Drive e reindex automático                |
| Reprocessar 1 documento                  | Painel admin → linha do documento → botão **Reprocessar**                                                         |
| Reprocessar vários                       | Marcar checkboxes → barra inferior **Reprocessar selecionados**                                                    |
| Reprocessar tudo                         | Cabeçalho → **Reprocessar todos**                                                                                  |
| Remover documento                        | Linha → **Remover** (apaga vetores + metadados + arquivo no Drive)                                                |
| Apagar a base inteira                    | Cabeçalho → **Apagar tudo** (confirma 2× — opcionalmente apaga também os arquivos no Drive)                       |
| Dar acesso a uma categoria               | Equipes → editar equipe → marcar categorias permitidas → atribuir usuários àquela equipe                          |
| Tornar alguém admin                      | Usuários → editar usuário → mudar role para `admin`                                                                |
| Ver mensagens de um usuário em produção  | SQL: `SELECT * FROM zanaflex_chat_message WHERE user_id = '<uuid>' ORDER BY created_at DESC LIMIT 50;`            |

---

## Estrutura de pastas

```
Zanaflex/
├── README.md                          ← você está aqui
├── RAG/                               (dados auxiliares de ingestão — IT.zip, planilhas)
├── IT.zip, its.xlsx                   (artefatos brutos das ITs)
└── zanaflex/
    ├── front-zanaflex.html            ← SPA single-file (chat + admin)
    ├── workspaces/                    ← 7 workflows n8n
    │   ├── README.md
    │   ├── Zanaflex-Front.json
    │   ├── Zanaflex-Agent-IA.json
    │   ├── Zanaflex-RAG.json          ← ingestão (3 webhooks unificados)
    │   ├── Zanaflex-RAG-Admin.json
    │   ├── Zanaflex-Chat-GET-Sessions.json
    │   ├── Zanaflex-Chat-GET-History.json
    │   └── Zanaflex-Chat-DELETE-Session.json
    ├── migrations/                    ← histórico real (001 → 020)
    │   └── README.md
    └── migrations-clean/              ← versão consolidada p/ Supabase novo
        └── README.md
```

---

## Referências

- [Workflows n8n — detalhamento](zanaflex/workspaces/README.md)
- [Migrations (histórico)](zanaflex/migrations/README.md)
- [Migrations (clean, Supabase novo)](zanaflex/migrations-clean/README.md)
