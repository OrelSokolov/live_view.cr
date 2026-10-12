require "spec"
require "../src/live_view_cr"
require "./views"

describe "template compiler" do
  it "segments statics and dynamics" do
    view = CounterLive.new
    rendered = view.render_lv

    rendered.dynamics.size.should eq(3)
    rendered.statics.size.should eq(4)
    rendered.to_html.should contain(%(<span data-count="0">Count: 0</span>))
    rendered.to_html.should contain(%(<button phx-click="decr" phx-value-step="1">-</button>))
    rendered.to_html.should contain(%(<span data-note=""></span>))
  end

  it "escapes dynamic values" do
    view = CounterLive.new
    view.handle_event("save", JSON.parse(%({"note": {"body": "<script>x</script>"}})))
    view.render_lv.to_html.should contain(%(data-note="&lt;script&gt;x&lt;/script&gt;"))
  end

  it "computes diffs over changed dynamics only" do
    view = CounterLive.new
    rendered = view.render_lv

    LiveView::Diff.compute(nil, rendered).size.should eq(3)

    view.handle_event("incr", JSON.parse(%({})))
    updated = view.render_lv
    diff = LiveView::Diff.compute(rendered.dynamics, updated)
    diff.size.should eq(2) # data-count + count text; data-note untouched

    view.handle_event("save", JSON.parse(%({"note": {"body": "hi"}})))
    diff2 = LiveView::Diff.compute(updated.dynamics, view.render_lv)
    diff2.size.should eq(1) # data-note only
  end
end

describe "lv_each do-blocks" do
  it "renders collections into a dynamic" do
    list = ListLive.new
    html = list.render_lv.to_html
    html.should contain(%(<li data-id="1">one</li>))
    html.should contain(%(<li data-id="2">two</li>))
  end
end

class ListLive < LiveView::Base
  @items = [{id: 1, name: "one"}, {id: 2, name: "two"}]

  lv_template "spec/fixtures/list_live.html"
end
