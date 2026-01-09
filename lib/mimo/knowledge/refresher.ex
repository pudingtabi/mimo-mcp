defmodule Mimo.Knowledge.Refresher do
  @moduledoc """
  SPEC-2026-003: Self-Refreshing Knowledge

  Automatically detects and refreshes stale package documentation by checking
  registry APIs for version updates.

  ## Strategy

  1. Track known packages with `source_package` and `version` in metadata
  2. Periodically check registry APIs (hex.pm, npm, pypi) for updates
  3. If version changed → mark related facts as stale
  4. Optionally trigger re-fetch of documentation

  ## Usage

      # Check a specific package
      Refresher.check_package("phoenix", :hex)

      # Check all tracked packages
      Refresher.check_all()

      # Get stale packages
      Refresher.list_stale()
  """

  use GenServer
  require Logger

  # Check interval: 24 hours
  @check_interval :timer.hours(24)

  # Registry API endpoints
  @hex_api "https://hex.pm/api/packages"
  @npm_api "https://registry.npmjs.org"
  @pypi_api "https://pypi.org/pypi"
  @crates_api "https://crates.io/api/v1/crates"

  # ETS table for version tracking
  @version_table :mimo_package_versions

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a specific package has a newer version available.

  Returns:
  - `{:ok, :current}` - Package is up to date
  - `{:ok, :stale, %{cached: v1, latest: v2}}` - New version available
  - `{:error, reason}` - Failed to check
  """
  def check_package(package_name, ecosystem \\ :hex) do
    GenServer.call(__MODULE__, {:check_package, package_name, ecosystem})
  end

  @doc """
  Check all tracked packages for updates.
  Returns list of stale packages.
  """
  def check_all do
    GenServer.call(__MODULE__, :check_all, 60_000)
  end

  @doc """
  List packages that are known to be stale.
  """
  def list_stale do
    GenServer.call(__MODULE__, :list_stale)
  end

  @doc """
  Track a package version (called when docs are cached).
  """
  def track_package(package_name, version, ecosystem) do
    GenServer.cast(__MODULE__, {:track, package_name, version, ecosystem})
  end

  @doc """
  Get tracking info for a package.
  """
  def get_tracking(package_name, ecosystem) do
    case :ets.lookup(@version_table, {package_name, ecosystem}) do
      [{_, info}] -> {:ok, info}
      [] -> {:error, :not_tracked}
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    # Create ETS table for version tracking (check if exists to prevent crash on restart)
    if :ets.whereis(@version_table) == :undefined do
      :ets.new(@version_table, [:named_table, :set, :public, read_concurrency: true])
    end

    # Schedule first check after 1 minute (let system stabilize)
    Process.send_after(self(), :scheduled_check, :timer.minutes(1))

    Logger.info("[Refresher] Started - checking packages every #{div(@check_interval, 3_600_000)}h")

    {:ok, %{stale_packages: [], last_check: nil}}
  end

  @impl true
  def handle_call({:check_package, name, ecosystem}, _from, state) do
    result = do_check_package(name, ecosystem)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:check_all, _from, state) do
    stale = do_check_all_packages()
    {:reply, stale, %{state | stale_packages: stale, last_check: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:list_stale, _from, state) do
    {:reply, state.stale_packages, state}
  end

  @impl true
  def handle_cast({:track, name, version, ecosystem}, state) do
    info = %{
      version: version,
      ecosystem: ecosystem,
      tracked_at: DateTime.utc_now(),
      stale: false
    }

    :ets.insert(@version_table, {{name, ecosystem}, info})
    Logger.debug("[Refresher] Tracking #{ecosystem}:#{name}@#{version}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_check, state) do
    Logger.info("[Refresher] Running scheduled version check...")

    stale = do_check_all_packages()

    if length(stale) > 0 do
      Logger.info(
        "[Refresher] Found #{length(stale)} stale package(s): #{inspect(Enum.map(stale, & &1.package))}"
      )
    end

    # Schedule next check
    Process.send_after(self(), :scheduled_check, @check_interval)

    {:noreply, %{state | stale_packages: stale, last_check: DateTime.utc_now()}}
  end

  # --- Internal Functions ---

  defp do_check_package(name, ecosystem) do
    case get_tracking(name, ecosystem) do
      {:ok, %{version: cached_version}} ->
        case fetch_latest_version(name, ecosystem) do
          {:ok, latest} ->
            if latest != cached_version do
              mark_stale(name, ecosystem, cached_version, latest)
              {:ok, :stale, %{cached: cached_version, latest: latest}}
            else
              {:ok, :current}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_tracked} ->
        {:error, :not_tracked}
    end
  end

  defp do_check_all_packages do
    @version_table
    |> :ets.tab2list()
    |> Enum.map(fn {{name, ecosystem}, _info} ->
      case do_check_package(name, ecosystem) do
        {:ok, :stale, details} ->
          %{package: name, ecosystem: ecosystem, details: details}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_latest_version(name, :hex) do
    url = "#{@hex_api}/#{name}"
    fetch_json_version(url, ["releases", Access.at(0), "version"])
  end

  defp fetch_latest_version(name, :npm) do
    url = "#{@npm_api}/#{name}/latest"
    fetch_json_version(url, ["version"])
  end

  defp fetch_latest_version(name, :pypi) do
    url = "#{@pypi_api}/#{name}/json"
    fetch_json_version(url, ["info", "version"])
  end

  defp fetch_latest_version(name, :crates) do
    url = "#{@crates_api}/#{name}"
    fetch_json_version(url, ["crate", "newest_version"])
  end

  defp fetch_json_version(url, path) do
    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        version = get_in(body, path)
        if version, do: {:ok, version}, else: {:error, :version_not_found}

      {:ok, %{status: 404}} ->
        {:error, :package_not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_stale(name, ecosystem, old_version, new_version) do
    # Update tracking info
    case :ets.lookup(@version_table, {name, ecosystem}) do
      [{key, info}] ->
        updated = %{info | stale: true, latest_version: new_version}
        :ets.insert(@version_table, {key, updated})

      _ ->
        :ok
    end

    # Optionally invalidate related memories
    # This could search for memories with the package name and mark them
    Logger.warning(
      "[Refresher] Package #{ecosystem}:#{name} is stale: #{old_version} → #{new_version}"
    )

    # Future: Could trigger re-fetch of docs here
    :ok
  end
end
