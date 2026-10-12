# Oracle transcript generator: connects to the real Phoenix LiveView
# endpoint as a wire client (V2 JSON protocol, same frames the official
# JS client sends), drives a Counter/Timer view through join → events →
# diffs, and writes normalized frames to ../expected.yml.
#
# Each case records the reply frame and the full HTML of the view after
# applying it (join → mount html, diff → patched html). The Crystal
# mirror spec reconstructs HTML the same way, so segment differences
# between HEEx and our compiler don't matter — the DOM each side
# produces must match.
#
# Run: mix test (from oracle/app) — regenerates ../expected.yml.

defmodule LVOracle.TranscriptTest do
  use ExUnit.Case, async: false

  alias LVOracle.WireClient

  @base "ws://127.0.0.1:4177/live/websocket?vsn=2.0.0"
  @endpoint LVOracle.Endpoint

  setup do
    :inets.start()

    {:ok, {{_, 200, _}, headers, _}} =
      :httpc.request(~c"http://127.0.0.1:4177/boot")

    cookie =
      Enum.find_value(headers, fn {k, v} ->
        if k == ~c"set-cookie", do: List.to_string(v) |> String.split(";") |> hd()
      end)

    %{cookie: cookie}
  end

  test "wire transcript", %{cookie: cookie} do
    {:ok, ws} = WireClient.start(@base, cookie)

    {counter_id, token} = session(LVOracle.CounterLive, "phx-counter0")
    {timer_id, timer_token} = session(LVOracle.TimerLive, "phx-timer0")

    {bad_req, bad_rep, nil, nil} =
      join_case(ws, counter_id <> "x", "bogus.token")

    {join_req, join_rep, join_html, counter} = join_case(ws, counter_id, token)

    {incr_req, incr_rep, incr_html, counter} =
      event_case(ws, counter_id, "2", counter, click("incr"))

    {again_req, again_rep, again_html, counter} =
      event_case(ws, counter_id, "3", counter, click("incr"))

    {decr_req, decr_rep, decr_html, counter} =
      event_case(ws, counter_id, "4", counter, click("decr", %{"step" => "1"}))

    {save_req, save_rep, save_html, _counter} =
      event_case(ws, counter_id, "5", counter, %{
        "type" => "form",
        "event" => "save",
        "value" => "note[body]=hello+world"
      })

    {hb_req, hb_rep} =
      send_recv(ws, [nil, "6", "phoenix", "heartbeat", %{}])

    {hb_phx_req, hb_phx_rep} =
      send_recv(ws, [nil, "7", "phoenix", "phx", %{}])

    {timer_join_req, timer_join_rep, timer_join_html, timer} =
      join_case(ws, timer_id, timer_token)

    {nil, tick1_rep, tick1_html, timer} = push_case(timer)
    {nil, tick2_rep, tick2_html, _timer} = push_case(timer)

    WebSockex.send_frame(ws, {:text,
      Jason.encode!([nil, nil, "lv:#{counter_id}", "phx_leave", %{}])})

    frames = %{
      "bad_join_reply" => {bad_req, bad_rep, nil},
      "counter_join_reply" => {join_req, join_rep, join_html},
      "counter_click_incr_reply" => {incr_req, incr_rep, incr_html},
      "counter_click_incr_again_reply" => {again_req, again_rep, again_html},
      "counter_click_decr_reply" => {decr_req, decr_rep, decr_html},
      "counter_form_save_reply" => {save_req, save_rep, save_html},
      "heartbeat_reply" => {hb_req, hb_rep, nil},
      "heartbeat_phx_reply" => {hb_phx_req, hb_phx_rep, nil},
      "timer_join_reply" => {timer_join_req, timer_join_rep, timer_join_html},
      "timer_tick1_diff" => {nil, tick1_rep, tick1_html},
      "timer_tick2_diff" => {nil, tick2_rep, tick2_html}
    }

    File.write!("../expected.yml", render_yml(frames))
  end

  defp session(view, id) do
    token =
      Phoenix.LiveView.Static.sign_token(@endpoint, %{
        id: id,
        view: view,
        root_view: view,
        parent_pid: nil,
        root_pid: nil,
        session: %{}
      })

    {id, token}
  end

  defp click(event, value \\ %{}),
    do: %{"type" => "click", "event" => event, "value" => value}

  defp join_case(ws, id, token) do
    req = [
      "1",
      "1",
      "lv:" <> id,
      "phx_join",
      %{
        "session" => token,
        "params" => %{"_mounts" => "0"},
        "url" => "http://127.0.0.1:4177/live"
      }
    ]

    {_req, rep} = send_recv(ws, req)

    case rep do
      [_, _, _, "phx_reply", %{"response" => %{"rendered" => rendered}, "status" => "ok"}] ->
        tree = flatten(rendered)
        {req, rep, html(tree), tree}

      _ ->
        {req, rep, nil, nil}
    end
  end

  defp event_case(ws, id, ref, tree, payload) do
    req = ["1", ref, "lv:" <> id, "event", payload]
    {_req, rep} = send_recv(ws, req)

    [_, _, _, "phx_reply", %{"response" => %{"diff" => diff}, "status" => "ok"}] = rep
    tree = merge_diff(tree, diff)
    {req, rep, html(tree), tree}
  end

  defp push_case(tree) do
    rep = recv_frame()
    [_, _, _, "diff", diff] = rep
    tree = merge_diff(tree, diff)
    {nil, rep, html(tree), tree}
  end

  defp send_recv(ws, frame) do
    WireClient.send_json(ws, frame)
    {frame, recv_frame()}
  end

  defp recv_frame(timeout \\ 2000) do
    receive do
      {:ws_frame, frame} -> frame
    after
      timeout -> flunk("timeout waiting for ws frame")
    end
  end

  # --- client-side rendered tree handling ------------------------------
  # flatten: rendered map with shared template ("p"/"s") into
  # %{statics: [...], dynamics: %{"i" => value}}.

  defp flatten(rendered) do
    template = rendered["p"] || %{}
    statics = template[to_string(rendered["s"])] || []

    dynamics =
      rendered
      |> Enum.reject(fn {k, _} -> k in ["p", "s", "r", "t", "e", "c"] end)
      |> Map.new(fn {k, v} -> {k, flatten_value(v)} end)

    %{statics: statics, dynamics: dynamics}
  end

  defp flatten_value(%{} = nested), do: {:nested, flatten(nested)}
  defp flatten_value(other), do: other

  # merge_diff: apply a diff (numeric keys replace dynamics, a nested
  # value with its own template replaces the whole subtree).
  defp merge_diff(%{statics: statics, dynamics: dyn}, diff) do
    dynamics =
      Enum.reduce(diff, dyn, fn
        {k, v}, acc when k in ["s", "p"] -> acc
        {k, v}, acc -> Map.put(acc, k, flatten_value(v))
      end)

    %{statics: statics, dynamics: dynamics}
  end

  defp html(nil), do: nil

  defp html(%{statics: statics, dynamics: dyn}) do
    {acc, _} =
      Enum.reduce(statics, {"", 0}, fn static, {acc, i} ->
        {acc <> static <> dyn_value(dyn[to_string(i)]), i + 1}
      end)

    acc
  end

  defp dyn_value(nil), do: ""
  defp dyn_value({:nested, tree}), do: html(tree)
  defp dyn_value(bin) when is_binary(bin), do: bin
  defp dyn_value(list) when is_list(list), do: Enum.join(list)

  defp render_yml(frames) do
    Enum.map_join(frames, "\n", fn {name, {req, rep, html}} ->
      json =
        %{req: req && normalize(req), rep: normalize(rep), html: html}
        |> Jason.encode!()

      "#{name}\t#{json}"
    end) <> "\n"
  end

  # Topic ids are per-run; mask them so transcripts are stable.
  defp normalize([join_ref, ref, topic, event, payload]) do
    [join_ref, ref, mask_topic(topic), event, normalize_value(payload)]
  end

  defp normalize_value(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, normalize_value(v)} end)

  defp normalize_value(list) when is_list(list),
    do: Enum.map(list, &normalize_value/1)

  defp normalize_value(bin) when is_binary(bin), do: mask_topic(bin)
  defp normalize_value(other), do: other

  defp mask_topic("lv:phx-" <> _), do: "lv:<ID>"
  defp mask_topic(bin), do: bin
end
