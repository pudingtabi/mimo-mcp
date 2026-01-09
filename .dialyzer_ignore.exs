# Dialyzer ignore file for known false positives
# These warnings are intentional or unavoidable in the current architecture

[
  # Mix module functions not available in PLT during library compilation
  # These are valid Mix functions that dialyzer can't see
  {":0:unknown_function Function Mix.shell/0 does not exist."},
  {":0:unknown_function Function Mix.Task.run/1 does not exist."},
  {":0:unknown_function Function Mix.raise/1 does not exist."},
  
  # Callback info warnings for Mix.Task - expected in mix tasks
  {"lib/mix/tasks", :callback_info_missing},
  
  # Phoenix router internals - not our code
  {"deps/phoenix/lib/phoenix/router.ex", :pattern_match}
]
