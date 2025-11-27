ExUnit.start()

# Load test support files
Code.require_file("support/data_case.ex", __DIR__)

# Configure Ecto for test database
Ecto.Adapters.SQL.Sandbox.mode(Mimo.Repo, :manual)
