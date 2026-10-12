# Oracle mirror views — the Crystal counterparts of oracle/app's
# CounterLive / TimerLive, producing identical DOM (the oracle's
# html snapshots prove it).

class CounterLive < LiveView::Base
  property count : Int32 = 0
  property last_note : String = ""

  def mount(params : Hash(String, JSON::Any), session : Hash(String, JSON::Any)) : Nil
  end

  def handle_event(event : String, params : JSON::Any) : Nil
    case event
    when "incr" then @count += 1
    when "decr" then @count -= 1
    when "save"
      if body = params.dig?("note", "body")
        @last_note = body.as_s
      end
    end
  end

  lv_template "spec/fixtures/counter_live.html"
end

class TimerLive < LiveView::Base
  property seconds : Int32 = 0

  def mount(params : Hash(String, JSON::Any), session : Hash(String, JSON::Any)) : Nil
    # mirror of the oracle TimerLive: two one-shot ticks
    send_after(100.milliseconds, "tick")
  end

  def handle_info(message : LiveView::Info) : Nil
    case message
    when "tick"
      @seconds += 1
      send_after(100.milliseconds, "tick") if @seconds < 2
    end
  end

  lv_template "spec/fixtures/timer_live.html"
end
