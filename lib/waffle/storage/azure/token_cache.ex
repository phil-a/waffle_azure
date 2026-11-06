defmodule Waffle.Storage.Azure.TokenCache do
  @moduledoc false
  # Caches access tokens and user delegation keys until shortly before they
  # expire, so that most requests don't have to fetch one first.
  #
  # Reads go straight to a protected ETS table. Fetches go through this process,
  # so that when several uploads find the same entry missing at once, only the
  # first of them fetches it and the rest reuse the result.

  use GenServer

  alias Waffle.Storage.Azure.AuthError

  @table __MODULE__

  # Entries are refreshed this many seconds before they expire, so that a value
  # is never used just as it runs out.
  @refresh_margin 5 * 60

  # Long enough for a fetch that Req retries several times.
  @fetch_timeout 60_000

  def start_link(_options) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Returns the value cached under `key`, as long as it stays valid until at least
  `valid_until` (Unix seconds). Otherwise calls `fun` for a new one.

  `fun` returns `{:ok, value, expires_at}`, with `expires_at` in Unix seconds, or
  `{:error, reason}`, which is returned without being cached.
  """
  def fetch(key, valid_until, fun) do
    # Fetching a user delegation key needs a token, so the cache's own process
    # can end up here, and can't call itself.
    in_cache? = self() == Process.whereis(__MODULE__)

    case lookup(key, valid_until) do
      {:ok, value} ->
        {:ok, value}

      :miss when in_cache? ->
        fetch_and_store(key, valid_until, fun)

      :miss ->
        try do
          GenServer.call(__MODULE__, {:fetch, key, valid_until, fun}, @fetch_timeout)
        catch
          :exit, {:timeout, _} ->
            {:error, %AuthError{message: "timed out getting Azure credentials"}}
        end
    end
  end

  @doc false
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:fetch, key, valid_until, fun}, _from, state) do
    {:reply, fetch_and_store(key, valid_until, fun), state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # Checks again first, as another caller may have just fetched it.
  defp fetch_and_store(key, valid_until, fun) do
    with :miss <- lookup(key, valid_until) do
      case safely(fun) do
        {:ok, value, expires_at} ->
          :ets.insert(@table, {key, value, expires_at})
          {:ok, value}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp lookup(key, valid_until) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at - @refresh_margin >= valid_until -> {:ok, value}
      _missing_or_expiring -> :miss
    end
  end

  # A crash here would empty the cache for everyone, so it becomes an error for
  # the caller that asked instead.
  defp safely(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  end
end
