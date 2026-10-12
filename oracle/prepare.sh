#!/bin/sh
# Oracle bootstrap. Run once from oracle/app.
#
# The system Erlang ships without dev headers (public_key/include is
# missing), so phoenix's phx.gen.cert task cannot compile. It is a
# cert-generation mix task, irrelevant to the wire protocol — drop it
# after deps.get.
set -e
mix deps.get
rm -f deps/phoenix/lib/mix/tasks/phx.gen.cert.ex
mix test
