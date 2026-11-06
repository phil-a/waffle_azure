defmodule Waffle.Storage.Azure.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Waffle.Storage.Azure.TokenCache]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
