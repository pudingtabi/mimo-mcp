ExUnit.start(exclude: [:integration, :external])

# Load test support files
Code.require_file("support/data_case.ex", __DIR__)

# Configure Ecto SQL Sandbox for test isolation
Ecto.Adapters.SQL.Sandbox.mode(Mimo.Repo, :manual)
