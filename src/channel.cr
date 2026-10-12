# Phoenix Channels wire protocol (V2 JSON serializer) + the LiveView
# channel on top: phx_join / event / diff / phx_leave, in the exact
# shapes recorded by the oracle transcript (oracle/expected.yml).
#
# Frame (client → server):  [join_ref, ref, topic, event, payload]
# Reply (server → client):  [join_ref, ref, topic, "phx_reply",
#                             {"response": ..., "status": "ok"|"error"}]
# Push  (server → client):  [join_ref, null, topic, "diff", {diff}]
#
# One connection may host several channels (one per mounted LiveView),
# exactly like Phoenix Channels: state is keyed by topic.

require "http/web_socket"
require "json"

module LiveView
  PROTOCOL_VERSION = "1.2.12"

  # Per-channel (per mounted LiveView) state.
  class ChannelState
    property view : Base
    property topic : String
    property last_dynamics : Array(String)?
    property join_ref : String

    def initialize(@view, @topic, @join_ref)
    end
  end

  class Session
    getter ws : HTTP::WebSocket
    getter token : Token

    @channels = {} of String => ChannelState
    @state_lock = Mutex.new  # channel state across reader + inbox fibers
    @write_lock = Mutex.new  # serializes ws frame writes

    def initialize(@ws, @token)
    end

    def on_message(raw : String) : Nil
      frame = JSON.parse(raw)
      return unless frame.as_a?

      join_ref = frame[0]?.try &.as_s?
      ref = frame[1]?.try &.as_s?
      topic = frame[2]?.try &.as_s?
      event = frame[3]?.try &.as_s?
      return unless topic && event

      payload = frame[4]? || empty_object

      case event
      when "heartbeat"
        # phoenix.js >= 1.8 heartbeat on the "phoenix" topic (oracle:
        # heartbeat_reply; the transport answers ok with an empty map).
        if topic == "phoenix"
          reply(topic, join_ref, ref, "ok", empty_object)
        else
          reply(topic, join_ref, ref, "error", {"reason" => any("unmatched topic")})
        end
      when "phx"
        # legacy heartbeat event name — the LiveView socket answers
        # exactly this way (oracle: heartbeat_phx_reply).
        reply(topic, join_ref, ref, "error", {"reason" => any("unmatched topic")})
      when "phx_join"
        handle_join(topic, join_ref.to_s, ref.to_s, payload)
      when "event"
        handle_event(topic, join_ref.to_s, ref.to_s, payload)
      when "phx_leave"
        handle_leave(topic, join_ref, ref)
      else
        reply(topic, join_ref, ref, "error", {"reason" => any("unmatched topic")})
      end
    rescue ex : JSON::ParseException
      # Malformed frames are dropped, like the Phoenix transport does.
    end

    def on_close : Nil
      @state_lock.synchronize do
        @channels.each_value do |channel|
          channel.view.__lv_close("shutdown")
          channel.view.terminate("shutdown")
        end
        @channels.clear
      end
    end

    # -- handlers ------------------------------------------------------------

    def handle_join(topic : String, join_ref : String, ref : String, payload : JSON::Any) : Nil
      data = payload["session"]?.try { |t| @token.verify_json(t.as_s) }

      if data.nil? || data["view"]?.nil?
        reply(topic, join_ref, ref, "error", {"reason" => any("stale")})
        return
      end

      id = data["id"]?.try &.as_s
      view_name = data["view"].as_s
      view_class = Base.registry[view_name]?

      if id.nil? || topic != "lv:#{id}" || view_class.nil?
        reply(topic, join_ref, ref, "error", {"reason" => any("stale")})
        return
      end

      user_session = data["session"]?.try(&.as_h) || {} of String => JSON::Any
      params = payload["params"]?.try(&.as_h) || {} of String => JSON::Any

      view = view_class.new

      # Replace the channel if the client rejoins the same topic.
      @state_lock.synchronize do
        if (existing = @channels[topic]?)
          existing.view.__lv_close("rejoin")
          existing.view.terminate("rejoin")
        end
        @channels[topic] = ChannelState.new(view, topic, join_ref)
      end

      view.mount(params, user_session)

      rendered = view.render_lv
      @state_lock.synchronize { @channels[topic].last_dynamics = rendered.dynamics }
      view.__lv_start(self)

      response = JSON.build do |json|
        json.object do
          json.field("rendered") { rendered.to_render_json(json) }
          json.field("liveview_version") { json.string(PROTOCOL_VERSION) }
        end
      end

      reply(topic, join_ref, ref, "ok", JSON.parse(response))
    end

    def handle_event(topic : String, join_ref : String, ref : String, payload : JSON::Any) : Nil
      channel = @state_lock.synchronize { @channels[topic]? }

      if channel.nil? || channel.join_ref != join_ref
        reply(topic, join_ref, ref, "error", {"reason" => any("unmatched topic")})
        return
      end

      event = payload["event"]?.try &.as_s
      if event.nil?
        reply(topic, join_ref, ref, "error", {"reason" => any("invalid")})
        return
      end

      value = decode_event_value(payload)
      channel.view.handle_event(event, value)

      diff = @state_lock.synchronize { diff_locked(channel, view_render(channel.view)) }
      reply(topic, join_ref, ref, "ok", {"diff" => JSON.parse(diff)})
    end

    def handle_leave(topic : String, join_ref : String?, ref : String?) : Nil
      channel = @state_lock.synchronize { @channels.delete(topic) }
      channel.try &.view.__lv_close("left")
      channel.try &.view.terminate("left")
      reply(topic, join_ref, ref, "ok", empty_object)
    end

    # handle_info runs on the inbox fiber; renders and pushes a diff.
    def run_handle_info(view : Base, message : Info) : Nil
      @state_lock.synchronize do
        channel = @channels.find { |_, c| c.view.same?(view) }
        return unless channel

        view.handle_info(message)
        push_diff_locked(channel[1], view_render(view))
      end
    end

    # -- event value decoding --------------------------------------------------

    private def decode_event_value(payload : JSON::Any) : JSON::Any
      type = payload["type"]?.try &.as_s
      value = payload["value"]?

      if type == "form" && (form = value.try &.as_s?)
        return form_to_json(form)
      end

      value || empty_object
    end

    # "note[body]=hello+world" → {"note": {"body": "hello world"}}
    # (Plug.Conn.Query.decode semantics, P0 subset: nested [key] parts).
    private def form_to_json(query : String) : JSON::Any
      root = {} of String => JSON::Any

      URI::Params.parse(query).each do |key, value|
        parts = key.split('[').map(&.tr("]", ""))

        if parts.size == 1
          root[parts[0]] = any(value)
        else
          cursor = root
          parts[0...-1].each do |part|
            case current = cursor[part]?
            when Hash
              cursor = current
            else
              nested = {} of String => JSON::Any
              cursor[part] = JSON::Any.new(nested)
              cursor = nested
            end
          end

          cursor[parts.last] = any(value)
        end
      end

      JSON::Any.new(root)
    end

    # -- rendering / diffing ---------------------------------------------------

    private def view_render(view : Base) : Rendered
      view.render_lv
    end

    private def diff_locked(channel : ChannelState, rendered : Rendered) : String
      diff = Diff.compute(channel.last_dynamics, rendered)
      channel.last_dynamics = rendered.dynamics
      diff.to_json
    end

    private def push_diff_locked(channel : ChannelState, rendered : Rendered) : Nil
      diff = Diff.compute(channel.last_dynamics, rendered)
      channel.last_dynamics = rendered.dynamics

      unless diff.empty?
        push(channel, "diff", JSON.parse(diff.to_json))
      end
    end

    # -- frames ------------------------------------------------------------------

    private def reply(topic : String, join_ref : String?, ref : String?, status : String, response) : Nil
      body = JSON.parse({status: status, response: response}.to_json)
      frame = [any(join_ref), any(ref), any(topic), any("phx_reply"), body]
      send_frame(frame)
    end

    private def push(channel : ChannelState, event : String, payload : JSON::Any) : Nil
      frame = [any(channel.join_ref), any(nil), any(channel.topic), any(event), payload]
      send_frame(frame)
    end

    private def send_frame(frame : Array(JSON::Any)) : Nil
      @write_lock.synchronize { @ws.send(frame.to_json) }
    end

    private def any(value : String?) : JSON::Any
      JSON::Any.new(value)
    end

    private def any(value : Nil) : JSON::Any
      JSON::Any.new(nil)
    end

    private def empty_object : JSON::Any
      JSON::Any.new({} of String => JSON::Any)
    end
  end
end
