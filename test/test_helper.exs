ExUnit.start()

# Configure Ecto for test database
Ecto.Adapters.SQL.Sandbox.mode(Mimo.Repo, :manual)
