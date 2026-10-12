# Integration spec: real HTTP server + WebSocket client speaking the
# Phoenix Channels V2 wire protocol against LiveView::Socket —
# join → rendered, click → diff, form submit → diff, heartbeat,
# handle_info → pushed diff, phx_leave.

require "spec"
require "http/server"
require "http/web_socket"
require "../src/live_view_cr"
require "./views"

def start_lv_server
  socket = LiveView::Socket.new("test_secret")
  http = HTTP::Server.new([socket])
  address = http.bind_tcp("127.0.0.1", 0)
  spawn { http.listen }
  Fiber.yield

  {socket, address}
end

# A message queue attached to the socket *before* any frames are sent,
# so replies can't race the callback registration.
class FrameQueue
  @queue = Channel(JSON::Any).new(64)

  def attach(ws : HTTP::WebSocket) : Nil
    ws.on_message { |message| @queue.send(JSON.parse(message)) }
  end

  def recv(timeout = 2.seconds) : JSON::Any?
    select
      when msg = @queue.receive
        msg
      when timeout(timeout)
        nil
    end
  end
end

describe "live_view websocket protocol" do
  it "speaks join/rendered/event/diff/heartbeat/leave" do
    socket, address = start_lv_server
    token = socket.token.sign({
      id:      "phx-counter0",
      view:    "CounterLive",
      session: {} of String => String,
    })

    ws = HTTP::WebSocket.new("127.0.0.1", "/live/websocket?vsn=2.0.0", address.port)
    frames = FrameQueue.new
    frames.attach(ws)
    spawn { ws.run }
    Fiber.yield

    # -- join
    ws.send(%(["1","1","lv:phx-counter0","phx_join",
      {"session": #{token.to_json}, "params": {"_mounts": "0"},
       "url": "http://127.0.0.1/live"}]))

    reply = frames.recv.not_nil!
    reply[3].should eq("phx_reply")
    reply[4]["status"].should eq("ok")

    rendered = reply[4]["response"]["rendered"]
    rendered["r"].should eq(JSON::Any.new(1))
    rendered["s"].should eq(JSON::Any.new(0))
    template = rendered["p"]["0"].as_a
    template.join("").should contain(%(<div class="counter">))

    # reconstructed DOM matches the full template + dynamics
    dynamics = rendered.as_h.reject { |k, _| {"p", "s", "r"}.includes?(k) }
    html = String.build do |io|
      template.each_with_index do |stat, i|
        io << stat.as_s
        io << (dynamics[i.to_s]? || JSON::Any.new("")).as_s
      end
    end
    html.should contain(%(<span data-count="0">Count: 0</span>))

    # -- click event → diff
    ws.send(%(["1","2","lv:phx-counter0","event",
      {"type": "click", "event": "incr", "value": {}}]))
    diff_reply = frames.recv.not_nil!
    diff_reply[4]["status"].should eq("ok")
    diff_reply[4]["response"]["diff"].as_h.size.should eq(2) # data-count + text

    # -- form event (url-encoded value) → diff on data-note
    ws.send(%(["1","3","lv:phx-counter0","event",
      {"type": "form", "event": "save", "value": "note[body]=hello+world"}]))
    form_reply = frames.recv.not_nil!
    form_reply[4]["status"].should eq("ok")
    form_reply[4]["response"]["diff"].as_h.values
      .map(&.as_s).join.should contain("hello world")

    # -- heartbeats: the 1.8 client sends "heartbeat" (ok), the legacy
    # "phx" name gets the same unmatched-topic error Phoenix sends
    ws.send(%([null,"4","phoenix","heartbeat",{}]))
    hb = frames.recv.not_nil!
    hb[2].should eq("phoenix")
    hb[3].should eq("phx_reply")
    hb[4]["status"].should eq("ok")
    hb[4]["response"].as_h.should be_empty

    ws.send(%([null,"5","phoenix","phx",{}]))
    hb_phx = frames.recv.not_nil!
    hb_phx[4]["status"].should eq("error")
    hb_phx[4]["response"]["reason"].should eq("unmatched topic")

    # -- leave
    ws.send(%([null,null,"lv:phx-counter0","phx_leave",{}]))
    leave = frames.recv.not_nil!
    leave[4]["status"].should eq("ok")
  end

  it "rejects a bad session token with stale" do
    socket, address = start_lv_server

    ws = HTTP::WebSocket.new("127.0.0.1", "/live/websocket?vsn=2.0.0", address.port)
    frames = FrameQueue.new
    frames.attach(ws)
    spawn { ws.run }
    Fiber.yield

    ws.send(%(["1","1","lv:phx-counter0","phx_join",
      {"session": "bogus.token", "params": {"_mounts": "0"}}]))

    reply = frames.recv.not_nil!
    reply[3].should eq("phx_reply")
    reply[4]["status"].should eq("error")
    reply[4]["response"]["reason"].should eq("stale")
  end

  it "pushes unsolicited diffs from handle_info" do
    socket, address = start_lv_server
    token = socket.token.sign({
      id:      "phx-timer0",
      view:    "TimerLive",
      session: {} of String => String,
    })

    ws = HTTP::WebSocket.new("127.0.0.1", "/live/websocket?vsn=2.0.0", address.port)
    frames = FrameQueue.new
    frames.attach(ws)
    spawn { ws.run }
    Fiber.yield

    ws.send(%(["1","1","lv:phx-timer0","phx_join",
      {"session": #{token.to_json}, "params": {"_mounts": "0"}}]))

    join = frames.recv.not_nil!
    join[4]["status"].should eq("ok")

    # two ticks arrive as "diff" pushes (join_ref set, no ref)
    tick1 = frames.recv(timeout: 3.seconds).not_nil!
    tick1[3].should eq("diff")
    tick1[1].as_nil # no ref on unsolicited pushes

    tick2 = frames.recv(timeout: 3.seconds).not_nil!
    tick2[3].should eq("diff")
    tick2[4]["1"].as_s.should eq("2") # seconds counter went 0 → 1 → 2
  end
end
