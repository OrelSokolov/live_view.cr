# Signed LiveView session tokens — the stand-in for Phoenix.Token.
#
# The JS client never parses the token: it reads `data-phx-session`
# from the container and echoes it back on phx_join, so the wire format
# is ours. Payload is JSON: {"id": ..., "view": "CounterLive", "session": {}}
# plus an HMAC-SHA256 signature (computed over Digest::SHA256 — the
# stdlib dropped OpenSSL::HMAC).

require "digest/sha256"

module LiveView
  class Token
    HMAC_BLOCK = 64

    def initialize(@secret : String)
    end

    def sign(payload : String) : String
      body = Base64.urlsafe_encode(payload)
      mac = Base64.urlsafe_encode(hmac_sha256(@secret, payload), padding: false)
      "#{body}.#{mac}"
    end

    def sign(payload : Hash | NamedTuple) : String
      sign(payload.to_json)
    end

    # Returns the payload JSON string, or nil when the signature is bad.
    def verify(token : String) : String?
      body, dot, mac = token.rpartition(".")
      return nil if dot.empty? || body.empty? || mac.empty?

      begin
        payload = Base64.decode_string(body)
      rescue Base64::Error | ArgumentError
        return nil
      end

      expected = Base64.urlsafe_encode(hmac_sha256(@secret, payload), padding: false)

      secure_compare(mac, expected) ? payload : nil
    end

    def verify_json(token : String) : JSON::Any?
      payload = verify(token)
      payload ? JSON.parse(payload) : nil
    rescue JSON::ParseException
      nil
    end

    # -- HMAC-SHA256 (RFC 2104) ------------------------------------------------

    private def hmac_sha256(key : String, data : String) : Bytes
      key_bytes = key.to_slice
      key_bytes = Digest::SHA256.digest(key_bytes) if key_bytes.size > HMAC_BLOCK

      ipad = Bytes.new(HMAC_BLOCK)
      opad = Bytes.new(HMAC_BLOCK)
      HMAC_BLOCK.times do |i|
        byte = i < key_bytes.size ? key_bytes[i] : 0_u8
        ipad[i] = byte ^ 0x36_u8
        opad[i] = byte ^ 0x5c_u8
      end

      inner = Digest::SHA256.digest(ipad + data.to_slice)
      Digest::SHA256.digest(opad + inner)
    end

    private def secure_compare(a : String, b : String) : Bool
      return false unless a.bytesize == b.bytesize
      res = 0_u8
      a.to_slice.zip(b.to_slice) { |x, y| res |= x ^ y }
      res == 0
    end
  end
end
