# Zanaflex — n8n Workflows

6 workflows que compõem o backend Zanaflex. Importe **todos** no mesmo projeto n8n.

| Arquivo                                                                | Webhooks expostos                                                                                                                                        |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Zanaflex-Front.json](Zanaflex-Front.json)                             | `GET /webhook/zanaflex-chat` — serve o HTML do front                                                                                                     |
| [Zanaflex-Agent-IA.json](Zanaflex-Agent-IA.json)                       | `POST /webhook/zanaflex-AgentRag`                                                                                                                        |
| [Zanaflex-RAG.json](Zanaflex-RAG.json)                                 | `POST /webhook/zanaflex-rag-upsert`, `GET /webhook/zanaflex-rag-docs`, `DELETE /webhook/zanaflex-rag-doc-delete`, `POST /webhook/zanaflex-rag-purge-all` |
| [Zanaflex-Chat-GET-Sessions.json](Zanaflex-Chat-GET-Sessions.json)     | `GET /webhook/zanaflex-sessions?userId=…`                                                                                                                |
| [Zanaflex-Chat-GET-History.json](Zanaflex-Chat-GET-History.json)       | `GET /webhook/zanaflex-history?sessionId=…&userId=…`                                                                                                     |
| [Zanaflex-Chat-DELETE-Session.json](Zanaflex-Chat-DELETE-Session.json) | `DELETE /webhook/zanaflex-session?sessionId=…&userId=…`                                                                                                  |

## Credenciais esperadas

Todos os workflows referenciam:

- **Postgres** → `id: "jFjeYH6Nt3aRNkoM"`, `name: "Supabase_database"` — credencial existente no projeto n8n (a mesma usada pela Aspiramaq/Sameka, apontando para `longflatworm-supabase.cloudfy.live`).
- **OpenAI** → placeholder `REPLACE_ME_OPENAI_CRED` em 4 nós (`Generate Embedding`, `Chat Model`, `Embed Query`). Trocar pelo id real da credencial OpenAI antes de ativar.

## Ordem de import

1. Garanta que as migrations **001 → 013** estão aplicadas no Supabase (ver [../migrations/README.md](../migrations/README.md)).
2. Importe os 5 JSONs na ordem que preferir — eles são independentes entre si.
3. Em `Zanaflex-Agent-IA` e `Zanaflex-RAG`, substitua `REPLACE_ME_OPENAI_CRED` pelo id da sua credencial OpenAI (botão "..." → Edit → escolha a credencial).
4. Ative todos os workflows.

## Pontos de design importantes

### RAG — upsert atômico por documento

`POST /webhook/zanaflex-rag-upsert` recebe:

```json
{
  "file_id": "IT-18.05",
  "title": "Pesagem e Dosagem de Produtos Químicos",
  "code": "IT-18.05",
  "category_code": "IT",
  "url": "https://.../IT-18.05.pdf",
  "mime_type": "application/pdf",
  "content_text": "...texto extraído..."
}
```

O fluxo: **purge_file(file_id) → chunk → embed → insert → upsert_metadata**. Só os chunks **daquele** `file_id` são removidos antes de reinserir — os outros documentos permanecem intactos.

Para PDFs binários, insira um nó `Extract from File` **entre** _Parse Payload_ e _Chunk Content_ e use o output como `content_text`. O fallback de decode ASCII via `content_base64` existe só para emergência.

### Agent — ACL por usuário

A ferramenta `search_knowledge_base` invoca `zanaflex_match_documents_for_user(userId, embedding, ...)` (migration 012). A função aplica a ACL: admin enxerga tudo; demais usuários só veem trechos cujo `category_id` esteja entre `zanaflex_user_allowed_categories_for(userId)`.

A ferramenta `get_document_metadata` também filtra por ACL — se o usuário pedir um código que existe mas para o qual não tem acesso, o agente recebe "Documento não encontrado ou sem acesso" e responde de acordo.

### Memória de chat

O nó `Postgres Chat Memory` grava em `zanaflex_chat_message`. O trigger da migration 010 popula `user_id` extraindo do bloco `[CONTEXTO DO USUÁRIO: ... ID="uuid"]` que o nó `Prepare Input` antepõe na mensagem human. Isso garante que `GET /zanaflex-sessions?userId=...` retorne apenas as sessões daquele usuário.

### Privacidade dos endpoints de chat

Todos os 3 endpoints Chat-\* exigem `userId` e filtram por ele no SQL. Mesmo que um usuário descubra um `sessionId` alheio, a query retorna 0 linhas (cláusula `AND user_id = ...`).

## Como atualizar um IT já indexado

Basta enviar o **mesmo** `file_id` no webhook `zanaflex-rag-upsert`. A função `zanaflex_rag_purge_file` apaga só os chunks antigos daquele `file_id` e os novos chunks substituem. Nenhum outro documento é tocado. Tempo de reindexação ≈ proporcional ao tamanho daquele 1 PDF, não ao tamanho do RAG inteiro.
