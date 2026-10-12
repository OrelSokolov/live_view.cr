# LiveView::Base — stateful server-side view over the Phoenix LiveView
# wire protocol (1.2.12). One instance per joined connection; the
# connection fiber drives events, an inbox fiber drives handle_info.

module LiveView
  # Messages deliverable to #handle_info.
  alias Info = String | Int32 | Int64 | Float64 | Bool

  # HTML that is already escaped — inserted verbatim (like
  # ActionView::SafeString, kept local to keep the shard dependency-free).
  class SafeString
    getter raw : String

    def initialize(@raw : String)
    end

    def to_s : String
      @raw
    end

    def self.new(raw : SafeString) : SafeString
      raw
    end
  end

  abstract class Base
    # view name -> class, so session tokens can name their view.
    @@registry = {} of String => Base.class

    def self.registry : Hash(String, Base.class)
      @@registry
    end

    macro inherited
      LiveView::Base.registry[{{ @type.name.stringify }}] = {{ @type }}
    end

    @__lv_buf : IO::Memory = IO::Memory.new
    @__lv_inbox = Channel(Info).new(64)
    @__lv_session : Session?
    @__lv_closed = false

    # -- lifecycle (override in subclasses) --------------------------------

    def mount(params : Hash(String, JSON::Any), session : Hash(String, JSON::Any)) : Nil
    end

    def handle_event(event : String, params : JSON::Any) : Nil
    end

    def handle_info(message : Info) : Nil
    end

    def terminate(reason : String) : Nil
    end

    # -- template -----------------------------------------------------------

    # Compiles an ERB-syntax template into #render_lv. Path resolves from
    # the compile-time working directory (like stdlib ECR).
    macro lv_template(path)
      {{ run("./lv_template_processor", path) }}
    end

    # -- buffer helpers used by generated code ------------------------------

    def __lv_out(value : String) : Nil
      @__lv_buf << value
    end

    def __lv_escape(value : String) : String
      HTML.escape(value)
    end

    def __lv_escape(value : SafeString) : String
      value.raw
    end

    def __lv_escape(value : Nil) : String
      ""
    end

    def __lv_escape(value) : String
      HTML.escape(value.to_s)
    end

    # Iterates a collection inside a template do-block. The block
    # appends markup through __lv_out / __lv_escape; the result is the
    # block's buffer as safe HTML (the Phoenix `for` comprehension).
    def lv_each(collection)
      outer = @__lv_buf
      @__lv_buf = IO::Memory.new
      collection.each { |item| yield item }
      SafeString.new(@__lv_buf.to_s)
    ensure
      @__lv_buf = outer if outer
    end

    # -- messaging ----------------------------------------------------------

    def send_info(message : Info) : Nil
      @__lv_inbox.send(message) unless @__lv_closed
    end

    def send_after(delay : Time::Span, message : Info) : Nil
      spawn(name: "lv-send-after") do
        sleep delay
        send_info(message)
      end
    end

    def send_every(interval : Time::Span, message : Info) : Nil
      spawn(name: "lv-send-every") do
        loop do
          sleep interval
          break if @__lv_closed
          send_info(message)
        end
      end
    end

    # Wires the session and starts the inbox fiber (called by Session#join).
    def __lv_start(session : Session) : Nil
      @__lv_session = session
      spawn(name: "lv-inbox") do
        loop do
          message = @__lv_inbox.receive
          break if @__lv_closed
          session.run_handle_info(self, message)
        end
      end
    end

    def __lv_close(reason : String) : Nil
      @__lv_closed = true
    end
  end
end
