# live_view.cr

A Crystal port of the **server side of Phoenix LiveView 1.2.12** (Elixir —
Rails has no LiveView equivalent, so the oracle is Phoenix itself):
stateful views living on the server, events over WebSocket, DOM patched
by the official `phoenix_live_view` JS client (MIT, vendored unmodified
in `assets/`, versions pinned: phoenix.js 1.8.15 + phoenix_live_view.js
1.2.12). The wire protocol is byte-compatible with the real thing — an
unmodified client in headless Chromium joins, clicks and patches DOM
against this server (E2E-verified). Suite: **8/8 specs**, including a
1:1 replay of 11 wire cases recorded against real Phoenix LiveView
1.2.12. Bench: same event/diff league as Phoenix (0.7–1.5×) at 14 MB RSS
vs 129 MB.

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  live_view_cr:
    github: OrelSokolov/live_view.cr
```

```sh
shards install
```

Depends on `active_support.cr` (path dependency). Crystal >= 1.21.0.

## Usage

```crystal
require "live_view_cr"

class CounterLive < LiveView::Base
  property count : Int32 = 0

  def handle_event(event : String, params : JSON::Any) : Nil
    @count += 1 if event == "incr"          # mutate state; channel re-renders
  end

  def handle_info(message : LiveView::Info) : Nil
  end

  lv_template "app/views/counter_live.html"  # ERB syntax, compiled at build time
end

# WebSocket endpoint — an HTTP::Handler (mount it in your server stack):
socket = LiveView::Socket.new("session_secret", "/live/websocket")
```

Template (`phx-click` / `phx-submit` bindings are the client's):

```html
<span data-count="<%= @count %>">Count: <%= @count %></span>
<button phx-click="incr">+</button>
```

Client side (vendored `assets/*.js`): note the 1.2 global name is
`LiveView.LiveSocket`, not `LiveSocket`:

```js
new LiveView.LiveSocket("/live", Phoenix.Socket)
```

## Feature comparison vs phoenix_live_view 1.2.12

### Wire protocol & transport

| Feature | Original (phoenix_live_view) | Port (live_view.cr) | Status |
|---|---|---|---|
| Phoenix Channels V2 envelope `[join_ref, ref, topic, event, payload]`, `phx_reply`/`phx_leave` | ✅ | Same | ✅ |
| Heartbeat (`heartbeat` → ok; legacy `phx` → unmatched topic) | ✅ | Same as phoenix.js 1.8 | ✅ |
| Multiple channels per connection (several LiveViews per page) | ✅ | Same | ✅ |
| `phx_join` → rendered (`{"s":0,"p":…,"r":1}`), `event` → diff of changed dynamics only | ✅ | Same | ✅ |
| Unsolicited `diff` push from `handle_info` | ✅ | Same | ✅ |
| `stale` / unmatched-topic errors | ✅ | Same | ✅ |
| Unmodified official JS client works against the server | ✅ | Vendored, verified E2E | ✅ |
| Transport | Bandit/Cowboy | Manual ws-upgrade (mirrors stdlib WebSocketHandler) with TCP_NODELAY | ✅ (different mechanics) |

### View API & templating

| Feature | Original | Port | Status |
|---|---|---|---|
| `mount` / `handle_event` / `handle_info` / `terminate` | ✅ | `LiveView::Base` callbacks | ✅ |
| Templates | HEEx | ERB compiled to `Rendered {statics, dynamics}`; collections via `lv_each` blocks | ⚠️ partial (same wire diffs, same DOM) |
| `send`/`send_after`/`send_every` to self | ✅ | `send_info` / `send_after` / `send_every` | ✅ |
| Raw HTML | `raw`/`Phoenix.HTML.Safe` | `LiveView::SafeString` | ✅ |
| Session tokens | `Phoenix.Token` | `LiveView::Token` (own HMAC-SHA256 format) | ⚠️ partial (client never parses it) |
| Form submits (`type:"form"`, url-encoded → nested JSON, Plug.Query semantics) | ✅ | Same | ✅ |

### Not ported (P1+)

- `live_component`, nested components, streams, uploads, hooks,
  `live_redirect`/`navigate`, `phx-update`, `page_title`,
  `phx-change` inputs, CSRF tokens, `lv:`-event interception
  (clear-flash etc.), multi-node pubsub.

## Deviations & Crystal-specific notes

- `handle_event`/`handle_info` return `Nil` and mutate state — the
  channel re-renders; Phoenix returns `{:noreply, socket}`.
- statics/dynamics segmentation is our own (ERB-based); wire diff
  format and resulting DOM are identical (oracle-verified).
- `rendered.p` is always `{"0": statics}` — a single-template pool;
  Phoenix keeps a global fingerprint pool (the client doesn't care).
- Session token is an HMAC-SHA256 built on `Digest::SHA256` (stdlib
  has no `OpenSSL::HMAC`); format is ours, the client treats it as
  an opaque string.
- Top-level control flow in templates is a compile error (cannot be
  segmented); iterate with `<%= lv_each(@items) do |item| %> … <% end %>`.
- View classes self-register at compile time (`macro inherited`);
  session tokens name their view through that registry.

Full list with rationale: `PLAN.md` (Russian).

## Testing

```sh
crystal spec          # 8 examples, 0 failures; no external services needed
```

Oracle: 11 wire cases (join/click×2/form-save/heartbeat×2/ticks/
bad-token) recorded with the real Phoenix LiveView 1.2.12 via a mix
project (`oracle/app`, websockex client) into `oracle/expected.yml`;
`spec/oracle_spec.cr` replays the transcript 1:1 — exact frames plus
reconstructed HTML per case. Regenerate the oracle with
`oracle/prepare.sh` (needs Elixir/mix and hex).
