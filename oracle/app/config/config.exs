import Config

config :lv_oracle, LVOracle.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: true,
  url: [host: "localhost"],
  render_errors: [formats: [html: LVOracle.ErrorHTML]],
  pubsub_server: LVOracle.PubSub,
  secret_key_base: String.duplicate("oracle_secret_key_base_0123456789", 2),
  live_view: [signing_salt: "lvoracle"]

config :logger, level: :warning
