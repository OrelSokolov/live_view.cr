# WebSocket endpoint for LiveView connections — the server side the
# vendored JS client connects to:
#
#   LiveSocket("/live", Phoenix.Socket) → ws(s)://host/live/websocket?vsn=2.0.0
#
# The upgrade is performed manually (mirroring stdlib's
# WebSocketHandler) to set TCP_NODELAY on the socket: event/diff
# round trips are tiny frames, and Nagle's 40ms delay dominates
# latency otherwise.

require "http/server"
require "http/web_socket"
require "base64"

module LiveView
  class Socket
    include HTTP::Handler

    getter token : Token

    def initialize(@secret : String, @mount_path : String = "/live/websocket")
      @token = Token.new(@secret)
    end

    def mount_path : String
      @mount_path
    end

    def call(context : HTTP::Server::Context) : Nil
      unless upgrade_request?(context.request)
        return call_next(context)
      end

      unless context.request.path == @mount_path
        context.response.respond_with_status(404)
        return
      end

      version = context.request.headers["Sec-WebSocket-Version"]?
      unless version == HTTP::WebSocket::Protocol::VERSION
        context.response.status = :upgrade_required
        context.response.headers["Sec-WebSocket-Version"] = HTTP::WebSocket::Protocol::VERSION
        return
      end

      key = context.request.headers["Sec-WebSocket-Key"]?
      unless key
        context.response.respond_with_status(400)
        return
      end

      response = context.response
      response.status = :switching_protocols
      response.headers["Upgrade"] = "websocket"
      response.headers["Connection"] = "Upgrade"
      response.headers["Sec-WebSocket-Accept"] = HTTP::WebSocket::Protocol.key_challenge(key)
      response.upgrade do |io|
        io.as?(TCPSocket).try &.tcp_nodelay = true
        ws = HTTP::WebSocket.new(io, sync_close: false)

        session = Session.new(ws, @token)
        ws.on_message { |message| session.on_message(message) }
        ws.on_close { session.on_close }
        ws.run
      end
    end

    private def upgrade_request?(request) : Bool
      return false unless upgrade = request.headers["Upgrade"]?
      return false unless upgrade.compare("websocket", case_insensitive: true) == 0

      request.headers.includes_word?("Connection", "Upgrade")
    end
  end
end
