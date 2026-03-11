defmodule Dungeonsanddragons.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Dungeonsanddragons.Repo,
      {DNSCluster,
       query: Application.get_env(:dungeonsanddragons, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Dungeonsanddragons.PubSub}
      # Start a worker by calling: Dungeonsanddragons.Worker.start_link(arg)
      # {Dungeonsanddragons.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dungeonsanddragons.Supervisor)
  end
end
