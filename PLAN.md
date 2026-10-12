# live_view.cr — серверная часть Phoenix LiveView

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

Неймспейс: `LiveView`. Портируется не Rails-гем (в Rails нет LiveView),
а **Phoenix LiveView 1.2.12** (Elixir): stateful-вьюха на сервере,
события по WebSocket, DOM морфит официальный JS-клиент
`phoenix_live_view` (MIT, vendored в `assets/`, версия запинена).
Клиент немодифицирован — это тот же трюк, что `@rails/actioncable`
для action_cable.cr.

## Что реализовано (Iteration 8, P0)

- **Wire-протокол Phoenix Channels V2**: JSON-конверт
  `[join_ref, ref, topic, event, payload]`, phx_reply/phx_leave,
  heartbeat (`heartbeat` → ok, как phoenix.js 1.8; легаси `phx` →
  unmatched topic — 1:1 с оракулом). Несколько каналов на соединении
  (одна страница — несколько LiveView).
- **LiveView-канал**: `phx_join` → rendered
  (`{"s":0,"p":{"0":[statics]},"0":dyn,...,"r":1}`), `event` → дифф
  только изменившихся dynamics, `handle_info` → несолитированный
  push `"diff"`, ошибки `stale`/`unmatched topic` как у Phoenix.
- **Транспорт**: ручной ws-upgrade (mirror stdlib WebSocketHandler) с
  TCP_NODELAY — без него закрытый цикл мелких фреймов упирается в
  Nagle+delayed-ACK 40 мс (задокументировано в бенче).
- **Шаблоны**: ERB-синтаксис компилируется в
  `Rendered {statics, dynamics}` (run()-компилятор
  `lv_template_processor.cr`, по образцу action_view). Управляющий код
  верхнего уровня — ошибка компиляции (нельзя сегментировать):
  списки через ` <%= lv_each(@items) do |item| %> ... <% end %> `.
- **API вьюхи** (`LiveView::Base`): `mount(params, session)`,
  `render` (макрос `lv_template path`), `handle_event(event, params)`,
  `handle_info(msg)`, `terminate(reason)`; `send_info/send_after/
  send_every`; `SafeString` для raw-HTML.
- **Токены**: `LiveView::Token` — HMAC-SHA256 поверх Digest::SHA256
  (в stdlib нет OpenSSL::HMAC); формат наш: клиент токен не парсит.
- **Формы**: `type:"form"` c url-encoded value → вложенный JSON
  (`"note[body]=x"` → `{"note":{"body":"x"}}`, Plug.Query-семантика).

## Оракул (AGENTS.md)

- `oracle/app` — mix-проект с настоящим Phoenix LiveView **1.2.12**
  (hex; phoenix 1.8.15, bandit; из системы удалён public_key/include —
  prepare.sh вырезает phx.gen.cert). Тест-транскрипт
  (`mix test`) снимает wire-кейсы с реального сервера через websockex:
  join/click×2/form-save/heartbeat/ticks/bad-token → `expected.yml`
  (req + rep + реконструированный html на каждый кейс).
- Зеркало: `spec/oracle_spec.cr` — наш сервер проходит транскрипт:
  точные кадры (stale, heartbeat) и семантика DOM (наша сегментация
  statics/dynamics отличается от HEEx, итоговый HTML — совпадает).
- `spec/ws_spec.cr` — интеграционный: реальный ws-клиент, полный
  цикл join → event → diff → form → heartbeat → leave; handle_info
  пуши. 8/8 зелёные.
- Регенерация оракула: `oracle/prepare.sh` (deps.get + mix test).

## Клиент и демо

- `assets/`: `phoenix.min.js` 1.8.15 + `phoenix_live_view.min.js`
  1.2.12 (npm-тарболлы; LICENSE-файлы рядом). Инициализация:
  `new LiveView.LiveSocket("/live", Phoenix.Socket)` — в 1.2 глобаль
  называется `LiveView.LiveSocket`, не `LiveSocket` (грабли задокументированы).
- demo: страница `/live` (счётчик с тиками + live-список notes c
  AR-записью), ws монтируется в `Application#call` (`/live/websocket`),
  JS отдаётся контроллером (embed в бинарь, `content_type:` опция
  render добавлена в action_pack).
- Критерий готовности подтверждён: headless Chromium + немодифицированный
  клиент — join → mount → click → diff → DOM-патч (`E2E_OK`,
  `?autotest=1` хук в шаблоне страницы).

## Бенч (`bench/results/400-liveview.md`)

Closed-loop event/diff, fiber-клиенты с TCP_NODELAY, вьюха-зеркало
BenchCounterLive на обеих сторонах:

| | CRails | Phoenix LV (Bandit) |
|---|---|---|
| ev/s (4–16 клиентов) | 52–61k | 39–88k |
| VmRSS после нагрузки | **14 MB** | 129 MB |

Одна лига (~0.7–1.5×), память в 9 раз меньше. Узкое место P0 —
`state_lock` сериализует render+diff; следующий шаг — cork/encode-once
по образцу action_cable P1.5.

## Отклонения от Phoenix (зафиксированы)

- Токен сессии — наш формат (HMAC), не Phoenix.Token (клиенту всё равно).
- `handle_event`/`handle_info` возвращают Nil и мутируют состояние —
  рендер вызывает канал; в Phoenix — `{:noreply, socket}`.
- Сегментация statics/dynamics наша (ERB), не HEEx; wire-формат
  диффов идентичен, DOM — идентичен (проверено оракулом).
- Не реализовано (P1+): live_component, uploads, hooks, streams,
  live_redirect/navigate, nested components, `phx-update`, CSRF-токен.
- `rendered.p` всегда `{"0": statics}` — пул из одного шаблона (у
  Phoenix глобальный пул по fingerprint'ам; клиенту безразлично).

## P1 (следующий заход)

- Серверный cork/encode-once (перенос action_cable P1.5).
- live_redirect/navigate, `phx-change`-инпуты, `page_title`.
- Мульти-нодность: pubsub между нодами (PG LISTEN/NOTIFY — Iteration 7).
- Интерсепция `lv:`-событий (clear-flash и т.п.).
