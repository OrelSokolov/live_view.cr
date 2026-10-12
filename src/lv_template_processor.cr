# LV template compiler (compile-time tool), invoked through the macro
# `run()` mechanism from view.cr. Prints the body of a method returning
# a LiveView::Rendered with immutable statics and dynamic expressions:
#
#   text             ->  statics segment
#   <%= expr %>      ->  dynamics: __lv_escape(expr)
#   <%= expr do %>   ->  dynamics: __lv_escape( expr do ... end )
#   <% stmt %>       ->  top level: compile error (cannot be segmented);
#                       inside a do-block: buffer append / control code
#
# Interleaving contract: output = statics[0] + dynamics[0] + statics[1]
# + ... , with dynamics.size == statics.size - 1 (empty statics pad the
# gaps when a template starts with or chains dynamic expressions).
#
# Control code at the top level cannot become part of statics — the
# compiler raises so the author restructures it as a do-block, e.g.
#   <%= lv_each(@items) do |item| %> ... <% end %>
#
# Erubi-style trim inside do-blocks: one newline directly after a code
# tag is dropped (same semantics as action_view.cr templates).

path = ARGV[0]
input = File.read(path)

i = 0
pending_do = 0   # open `<%= expr do %>` inside the current dynamic
inner_do = 0     # nested `do` blocks opened by control code inside it

statics = [] of String    # literal segments (quoted)
dynamics = [] of String   # generated expressions
block_code = [] of String # lines inside the currently open do-block
last_dynamic = false

while open = input.index("<%", i)
  text = input[i...open]

  if pending_do > 0
    block_code << "__lv_out #{text.inspect}" unless text.empty?
  elsif !text.empty?
    statics << text.inspect
    last_dynamic = false
  end

  close = input.index("%>", open + 2)
  raise "Missing %> in #{path} after offset #{open}" unless close
  inner = input[open + 2...close]
  i = close + 2

  if inner.starts_with?("#")
    # comment — dropped, with Erubi trim of the following newline
    i += 1 if input[i]? == '\n'
    next
  elsif inner.starts_with?("=")
    expr = inner[1..].strip

    if pending_do > 0
      if expr.ends_with?("do") || expr =~ /do\s+\|[^|]*\|\s*$/
        raise "#{path}: nested `<%= expr do %>` inside a do-block is not supported"
      end
      block_code << "@__lv_buf << __lv_escape( #{expr} )"
      i += 1 if input[i]? == '\n'
      next
    end

    # A dynamic following another dynamic needs an empty static gap.
    statics << %("") if last_dynamic && !statics.empty?

    if expr.ends_with?("do") || expr =~ /do\s+\|[^|]*\|\s*$/
      dynamics << "__lv_escape( #{expr}"
      pending_do += 1
    else
      dynamics << "__lv_escape( #{expr} )"
    end

    last_dynamic = true
  else
    code = inner.strip

    if pending_do > 0
      if code == "end" && inner_do == 0
        dynamics[-1] = "#{dynamics[-1]}\n#{block_code.join("\n")}\nend )"
        block_code.clear
        pending_do -= 1
      else
        block_code << inner
        inner_do += 1 if code.ends_with?("do") || code =~ /do\s+\|[^|]*\|\s*$/
      end
      # Erubi trim: drop one newline right after a code tag.
      i += 1 if input[i]? == '\n'
      next
    end

    raise "#{path}: stray `<% end %>` with no open do-block" if code == "end"

    raise "#{path}: control code `<% #{code} %>` is not supported at the top level of a LiveView template; move it inside a `<%= ... do %>` block"
  end
end

text = input[i..]
raise "#{path}: unterminated do-block at end of template" if pending_do > 0

if text.empty?
  # Template ends with a dynamic: pad the trailing static slot.
  statics << %("") if last_dynamic || statics.empty?
else
  statics << text.inspect
end
statics << %("") if statics.empty?

print "def render_lv : LiveView::Rendered\n"
print "  LiveView::Rendered.new(\n"
print "    statics: [\n"
statics.each { |s| print "      ", s, ",\n" }
print "    ] of String,\n"
print "    dynamics: [\n"
dynamics.each { |d| print "      ", d, ",\n" }
print "    ] of String,\n"
print "  )\n"
print "end\n"
