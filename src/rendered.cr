# Rendered tree + diff engine, mirroring the Phoenix LiveView wire
# format (protocol version 1.2.12, vendored JS client).
#
# A template compiles to:
#   statics  — immutable HTML segments
#   dynamics — escaped HTML strings interleaved between statics:
#              statics[0] + dynamics[0] + statics[1] + ... + statics[n]
#
# The join reply sends statics once through the shared-template pool
# ("p"/"s" keys, same shape as Phoenix); every later render sends only
# the dynamics indices whose values changed:
#   {"0": " data-count=\"1\"", "1": "1"}

module LiveView
  class Rendered
    getter statics : Array(String)
    getter dynamics : Array(String)

    def initialize(@statics, @dynamics)
    end

    def to_html : String
      String.build do |io|
        @statics.each_with_index do |stat, i|
          io << stat
          io << (@dynamics[i]? || "")
        end
      end
    end

    # Join-reply rendered payload:
    # {"s": 0, "p": {"0": statics}, "0": dyn, ..., "r": 1}
    def to_render_json(json : JSON::Builder) : Nil
      json.object do
        @dynamics.each_with_index do |dyn, i|
          json.field(i.to_s) { json.string(dyn) }
        end

        json.field("p") do
          json.object do
            json.field("0") do
              json.array do
                @statics.each { |s| json.string(s) }
              end
            end
          end
        end

        json.field("r") { json.number(1) }
        json.field("s") { json.number(0) }
      end
    end
  end

  module Diff
    # Returns the changed dynamics as {"index" => value} — an empty map
    # when nothing changed (the client applies empty diffs as no-ops).
    def self.compute(previous : Array(String)?, rendered : Rendered) : Hash(String, String)
      changed = {} of String => String

      rendered.dynamics.each_with_index do |dyn, i|
        changed[i.to_s] = dyn unless previous && previous[i]? == dyn
      end

      changed
    end
  end
end
