# Intelligence — model access and the model picker

Copper keeps its model access in Settings › Intelligence. There are two lanes. Jev (TypeSafe) is a separate fast helper and is unchanged.

## The two lanes

**API key** uses an OpenAI-compatible gateway (LiteLLM). Copper sends the gateway address and an API key that you enter in Settings. The gateway chooses and runs the model; no Claude account is needed.

**Claude account** signs in with a claude.ai account — Pro, Max, Team or Enterprise — like Claude Code does. Copper opens an OAuth with PKCE flow in a Copper tab, receives the callback on a loopback port, and stores the access and refresh tokens in `claude.json` with mode 0600. Tokens refresh silently. Inference goes straight to `https://api.anthropic.com/v1/messages` with the Claude Code identity headers; no API key is involved.

The Claude account lane is only for the account you sign in. Copper does not copy the account session into a page or send it through the agent link.

## The picker

The picker has three choices: **Haiku**, **Sonnet** and **Opus**. Sonnet is the default. One choice applies to the agent pane and Jev's text and extract helper. The model name for each choice is editable for each lane. The defaults are `claude-haiku-4-5`, `claude-sonnet-5` and `claude-opus-5-5` for the Claude account lane, and `haiku`, `sonnet` and `opus` for the API-key lane.

### Floating names, never pinned ones

On the API-key lane Copper sends the gateway's **floating aliases** — `haiku`, `sonnet`, `opus` — so the agent follows the gateway to the newest model (Opus 5.5 today) with no change in Copper. phi shows these as `exowatt/opus` and so on; the gateway's own names have no prefix. Any spelling of a Claude tier is sent as its float: `exowatt/opus`, `exowatt/opus-5`, `opus-5`, `claude-opus-5`, `claude-opus-5-5`, `claude-sonnet-4-5-20250929` all go as `opus` or `sonnet`. A name that is not a Claude tier (`luna`, `gpt-4o-mini`) is yours and goes as typed, less an `exowatt/` prefix.

The Claude account lane talks to Anthropic directly, which has no float, so a Claude tier in any spelling is sent as Copper's current id for it (`claude-opus-5-5` for Opus).

An `intelligence.json` saved by an older build is migrated as it is read: `routerModels`, `routerModel`, `claudeModels` and `textModel` values that are a pinned or prefixed spelling of a tier become the float (or the Claude lane's current id); custom names are kept. The same rule applies to names set with `copper intelligence set`.

Settings › Intelligence › Model says which name is sent (*Sends opus*) and, once an answer has come back, the model it reported (*last answered by claude-opus-5-5-…*); the agent pane's model menu says the same.

### What goes on the wire

Both lanes send no `temperature`, no `thinking` block (disabled or budgeted) and no forced tool: `tool_choice` is `auto` (`{"type": "auto"}` on the Messages API) whenever tools are offered. Opus 5.5 refuses the first two, and `auto` is the one choice every model takes. `Router.body` and `Claude.body` build every request.

### Prompt caching

The agent re-sends the whole conversation on every turn, and neither Bedrock (behind the gateway) nor Anthropic caches anything unless the request marks where a reusable prefix ends. Both lanes mark it with `cache_control: {"type": "ephemeral"}` — at most four marks, Anthropic's limit (`Fork/PromptCache.swift`):

1. the end of the system prompt (with the tools before it, the part every question shares);
2. the last tool definition;
3. the last message — what the next turn reads back;
4. the message just before the last assistant reply — the previous request's last message, sent again exactly as it was, mark included, so this turn reads what that one wrote.

On the gateway the system prompt and the user and tool messages go as content parts, the mark on the last part (`{"type": "text", "text": …, "cache_control": …}`, or an `image_url` part), and the last tool carries `"cache_control"` beside `"type"` and `"function"` — the shape LiteLLM passes on to both Bedrock routes (Converse for `opus`, Invoke for `sonnet`). On the Messages API the mark sits on the last system block (never on the Claude Code identity block before it), the last tool and the last content block of a message. One-shot asks (Jev's text and extract helpers, Settings' test) mark only the instructions: their question is never sent again.

A cache only hits on the same bytes, so the prefix never changes under it: the system prompt and the tool list carry nothing that changes per turn (the page goes in the question), earlier messages are re-sent as they were kept, and every body is written with sorted keys (a Swift dictionary's key order differs from one copy to the next). A model on the gateway that is not a Claude tier gets no marks — `kimi` refuses them — and an answer that blames the marks (a content-policy fallback to such a model) is asked again without them.

A turn then pays full price only for what is new since the last one: on Opus 5.5 a 10k-token turn costs about $0.005 instead of $0.04. `./bench agent chat` lists each request's `usage` — `prompt`, `cached` (read from the cache), `written` and `output` tokens.

Jev (TypeSafe) is separate and unchanged. Its key and endpoint remain the Jev fast lane; the picker controls the model used when Copper needs a model response.

## Keys from Copper Cloud

A Copper signed in to a [Copper Cloud](cloud.md) asks it for model keys — `GET /v1/intelligence`, with the same instance key and session bearer as every other `/v1` call:

```json
{"jev": {"key": "…", "endpoint": "https://api.typesafe.ai/v1/systemone", "model": "jev-latest"},
 "router": {"key": "…", "url": "https://llm.dev.exowatt.com"},
 "updated_at": "2026-10-05T12:00:00Z",
 "agent": {"max_turns": 100}}
```

Any part may be `null` or missing. `agent` is not a key and comes whether or not the cloud shares keys: `max_turns` (a whole number, 1–500; anything else is ignored) is the org's tool-call rounds per question for the agent pane and wins over Settings › Agents while provided (docs/agents.md); it is cached and cleared with the keys. A 404 (a cloud from before this route), 401 or 403 means the cloud provides nothing; no error is shown. Copper asks after a cloud sign-in, at launch when linked and signed in, when Settings opens (at most once a minute) and every 30 minutes. A network failure keeps what was known.

What the cloud provides is kept in memory and in `cloud-intelligence.json` (mode 0600, beside `cloud.json`) so an offline launch still works, and is **never written into `intelligence.json`**. Signing out of the cloud, disconnecting it, or signing in as someone else deletes it.

**While the cloud provides a gateway key, every model call uses it.** The lane in force is the API-key lane with the cloud's key and address — for the agent pane, Jev's text and extract helper, Settings' Check and every agent tab — even with a Claude account signed in, the Claude account lane chosen, or a gateway key typed on this Mac. Nothing of yours is changed: the lane you chose stays in `intelligence.json` (and the Claude account stays signed in), so signing out of the cloud, disconnecting it, or the cloud no longer providing a key puts your own lane and keys back in force.

Field by field:

| Field | Used |
|---|---|
| Lane | the API-key lane while the cloud provides a gateway key; else the one chosen on this Mac |
| API key | the cloud's, whenever it provides one; else a non-empty key typed on this Mac |
| Gateway address | the cloud's while the cloud's key is the one in use; else an address other than the default typed on this Mac; else the default (a key typed here is never sent to an address the cloud chose) |
| Model names (Haiku / Sonnet / Opus) | this Mac's names for the lane in force — the gateway's (`haiku`, `sonnet`, `opus`) on the cloud's key; `/v1/intelligence` ships none |
| Jev key | a non-empty key typed on this Mac; else the cloud's |
| Jev model | a name other than the default `jev-latest` typed on this Mac; else the cloud's; else the default |
| Jev endpoint | an address other than the default typed on this Mac; else the cloud's when the cloud's Jev key is in use; else the default |

So a cloud user with nothing typed has a working agent pane and Jev with no setup. Settings › Intelligence (and Settings › Agents › Jev key) say *Provided by Copper Cloud (host)* for each key the cloud supplies, with the key masked (`sk-…1a2b`) in the field's placeholder. A Jev key typed there overrides the cloud's, and clearing the field goes back to the cloud's. While the cloud's gateway key is in force the Model access card shows the API-key lane as active with *Copper Cloud provides the model key — your Claude account isn't used while you're signed in to it.*, and the lane picker, API key and gateway address are greyed out. The agent pane's model menu reads *Copper Cloud · host* while the cloud's API key is in use.

`copper intelligence sources` lists where each one comes from — `local`, `cloud` or `none` for the keys, `local`, `cloud` or `default` for the addresses and the Jev model, `local` or `cloud` for the lane — and never a key. `copper intelligence refresh` asks the cloud again now; `copper intelligence status` carries the same `sources`, a `cloud` block (host, what it provides, `updatedAt`, `fetchedAt`), and `lane` (the lane in force), `laneSource` (`cloud` or `local`) and `localLane` (the one chosen on this Mac). `./bench ai` and `./bench agent` report the same `lane` and `laneSource`.

## The files

- `intelligence.json` holds the Jev and API-key lane settings. It is beside Copper's session data and is mode 0600.
- `claude.json` holds the Claude account credentials. It is beside `intelligence.json` and is mode 0600.
- `cloud-intelligence.json` holds the keys Copper Cloud provided, the cloud's host and when they were fetched. Mode 0600, written atomically, deleted on cloud sign-out or disconnect.

Copper never puts a token in status output, the CLI output, or a transcript.

## What leaves the Mac

With the API-key lane, Copper sends the prompts and the page information needed by the agent or Jev helper to the gateway address you configured. With the Claude account lane, model requests go directly to Anthropic's Messages API. Jev requests go to the TypeSafe endpoint when Jev is enabled. The account token stays in `claude.json`; the agent link never carries it. Ordinary page requests still go only to the sites you open.

## CLI and bench

The loopback CLI controls the settings without printing secrets:

```sh
copper intelligence status
copper intelligence sources           # local | cloud | none per key, never the key
copper intelligence refresh           # ask Copper Cloud for its keys again
copper intelligence set --lane claude --model sonnet
copper intelligence set --lane key --router-key -
echo "$ROUTER_KEY" | copper intelligence set --router-key -
copper intelligence reload

copper claude status
copper claude signin
copper claude paste -                 # read the callback code from stdin
copper claude signout
copper claude cancel
```

`copper claude signin` opens claude.ai in the running Copper window. Sign in there and let the callback return to Copper. If the callback cannot return, use `copper claude paste -`; stdin is preferred so the code is not put in the process list. `status` reports the lane, tier, model, readiness and account email, never a token. The commands need the loopback server and bearer token, and return 0 on success, 1 when Copper refuses an operation, and 2 for usage errors or an unreachable browser.

`./bench ai` reports the lane in force (with `laneSource` and `localLane`), tier, model, model readiness, Claude-account readiness, `sources` and `answeredBy`. `./bench ai lane key|claude` and `./bench ai tier haiku|sonnet|opus` change this Mac's choice. `./bench ai sources|refresh` are the CLI's two. `./bench ai selftest` (also part of `./bench agent selftest`) checks the model-name migration, the merge of this Mac's keys with the cloud's (including the cloud's gateway key deciding the lane, and the lane coming back when the cloud goes), the `/v1/intelligence` decoder (including `agent.max_turns`: range, wrong types, the cache) and the request shapes, and both lanes' prompt-cache marks over a four-turn conversation — where they sit, never more than four, and each turn's body beginning with the bytes of the one before — probe world only.

## Troubleshooting

- **The sign-in tab did not come back.** Copy the code or redirect text from claude.ai and run `copper claude paste -`, then paste it on stdin.
- **“Sign-in expired.”** Sign in again in Settings › Intelligence, or run `copper claude signin`.
- **429.** The Claude account is rate-limited. Wait and try again, or use the API-key lane.
