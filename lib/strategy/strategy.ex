defmodule ClusterEcs.Strategy do
  @moduledoc """
  This clustering strategy works by loading all ecs tasks that belong to the
  given service.

      config :libcluster,
        topologies: [
          example: [
            strategy: #{__MODULE__},
            config: [
              service_name: "my_service",
              polling_interval: 10_000]]]

  ## Configuration Options

  | Key | Required | Description |
  | --- | -------- | ----------- |
  | `:cluster` | yes | Name of the ECS cluster to look in. |
  | `:service_name` | yes | Name of the ECS service to look for. |
  | `:region` | yes | The AWS region you're running in. |
  | `:app_prefix` | no | Will be prepended to the node's private IP address to create the node name. |
  | `:polling_interval` | no | Number of milliseconds to wait between polls to the AWS api. Defaults to 5_000 |
  """

  use GenServer
  use Cluster.Strategy
  import Cluster.Logger
  require Logger

  alias Cluster.Strategy.State

  @default_polling_interval 5_000

  def start_link(opts) do
    Application.ensure_all_started(:ex_aws)
    GenServer.start_link(__MODULE__, opts)
  end

  # libcluster ~> 3.0
  @impl true
  def init([%State{} = state]) do
    state = state |> Map.put(:meta, MapSet.new())

    {:ok, state, 0}
  end

  # libcluster ~> 2.0
  def init(opts) do
    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      list_nodes: Keyword.fetch!(opts, :list_nodes),
      config: Keyword.fetch!(opts, :config),
      meta: MapSet.new([])
    }

    {:ok, state, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    handle_info(:load, state)
  end

  def handle_info(:load, %State{topology: topology, connect: connect, disconnect: disconnect, list_nodes: list_nodes} = state) do
    case get_nodes(state) do
      {:ok, new_nodelist} ->
        new_nodelist = MapSet.new(new_nodelist)
        added = MapSet.difference(new_nodelist, state.meta)
        removed = MapSet.difference(state.meta, new_nodelist)

        new_nodelist =
          case Cluster.Strategy.disconnect_nodes(topology, disconnect, list_nodes, MapSet.to_list(removed)) do
            :ok ->
              new_nodelist

            {:error, bad_nodes} ->
              # Add back the nodes which should have been removed, but which couldn't be for some reason
              Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                MapSet.put(acc, n)
              end)
          end

        new_nodelist =
          case Cluster.Strategy.connect_nodes(topology, connect, list_nodes, MapSet.to_list(added)) do
            :ok ->
              new_nodelist

            {:error, bad_nodes} ->
              # Remove the nodes which should have been added, but couldn't be for some reason
              Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                MapSet.delete(acc, n)
              end)
          end

        Process.send_after(self(), :load, Keyword.get(state.config, :polling_interval, @default_polling_interval))
        {:noreply, %{state | :meta => new_nodelist}}

      _ ->
        Process.send_after(self(), :load, Keyword.get(state.config, :polling_interval, @default_polling_interval))
        {:noreply, state}
    end
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  @spec get_nodes(State.t()) :: {:ok, [atom()]} | {:error, []}
  def get_nodes(%State{topology: topology, config: config}) do
    region = Keyword.fetch!(config, :region)
    cluster = Keyword.fetch!(config, :cluster)
    service_name = Keyword.fetch!(config, :service_name) |> List.wrap()
    app_prefix = Keyword.get(config, :app_prefix, "app")

    with(
      {:config, :cluster, true} <- {:config, :cluster, config_string?(cluster)},
      {:config, :region, true} <- {:config, :region, config_string?(region)},
      {:config, :service_name, true} <- {:config, :service_name, name_configured?(service_name)},
      {:ok, list_service_body} <- list_services(cluster, region),
      {:ok, service_arns} <- extract_service_arns(list_service_body),
      {:ok, task_arns} <- get_tasks_for_services(cluster, region, service_arns, service_name),
      {:ok, desc_task_body} <- describe_tasks(cluster, task_arns, region),
      {:ok, ips} <- extract_ips(desc_task_body)
    ) do
      {:ok, Enum.into(ips, MapSet.new(), &ip_to_nodename(&1, app_prefix))}
    else
      {:config, field, _} ->
        warn(topology, "ECS strategy is selected, but #{field} is not configured correctly!")
        {:error, []}

      err ->
        warn(topology, "Error #{inspect(err)} while determining nodes in cluster via ECS strategy.")
        {:error, []}
    end
  end

  defp config_string?(str) when is_binary(str) and str != "", do: true

  defp config_string?(_), do: false

  defp name_configured?([_ | _] = names) do
    Enum.all?(names, &name_configured?/1)
  end

  defp name_configured?(name), do: config_string?(name)

  defp get_tasks_for_services(cluster, region, service_arns, service_names) do
    Enum.reduce(service_names, {:ok, []}, fn service_name, acc ->
      case acc do
        {:ok, acc_tasks} ->
          with(
            {:ok, service_arn} <- find_service_arn(service_arns, service_name),
            {:ok, list_task_body} <- list_tasks(cluster, service_arn, region),
            {:ok, task_arns} <- extract_task_arns(list_task_body)
          ) do
            {:ok, acc_tasks ++ task_arns}
          end

        other ->
          other
      end
    end)
  end

  defp list_services(cluster, region) do
    params = %{
      "cluster" => cluster
    }

    query("ListServices", params)
    |> ExAws.request(region: region)
    |> list_services(cluster, region, [])
  end

  defp list_services({:ok, %{"nextToken" => next_token, "serviceArns" => service_arns}}, cluster, region, accum)
       when not is_nil(next_token) do
    params = %{
      "cluster" => cluster,
      "nextToken" => next_token
    }

    query("ListServices", params)
    |> ExAws.request(region: region)
    |> list_services(cluster, region, accum ++ service_arns)
  end

  defp list_services({:ok, %{"serviceArns" => service_arns}}, _cluster, _region, accum) do
    {:ok, %{"serviceArns" => accum ++ service_arns}}
  end

  defp list_services({:error, message}, _cluster, _region, _accum) do
    {:error, message}
  end

  defp list_tasks(cluster, service_arn, region) do
    params = %{
      "cluster" => cluster,
      "serviceName" => service_arn,
      "desiredStatus" => "RUNNING"
    }

    query("ListTasks", params)
    |> ExAws.request(region: region)
  end

  defp describe_tasks(cluster, task_arns, region) do
    params = %{
      "cluster" => cluster,
      "tasks" => task_arns
    }

    query("DescribeTasks", params)
    |> ExAws.request(region: region)
  end

  @namespace "AmazonEC2ContainerServiceV20141113"
  defp query(action, params) do
    ExAws.Operation.JSON.new(
      :ecs,
      %{
        data: params,
        headers: [
          {"accept-encoding", "identity"},
          {"x-amz-target", "#{@namespace}.#{action}"},
          {"content-type", "application/x-amz-json-1.1"}
        ]
      }
    )
  end

  defp extract_task_arns(%{"taskArns" => arns}), do: {:ok, arns}
  defp extract_task_arns(_), do: {:error, "unknown task arns response"}

  defp extract_service_arns(%{"serviceArns" => arns}), do: {:ok, arns}
  defp extract_service_arns(_), do: {:error, "unknown service arns response"}

  defp find_service_arn(service_arns, service_name) when is_list(service_arns) do
    with {:ok, regex} <- Regex.compile(service_name) do
      service_arns
      |> Enum.find(&Regex.match?(regex, &1))
      |> case do
        nil ->
          Logger.error("no service matching #{service_name} found")
          {:error, "no service matching #{service_name} found"}

        arn ->
          {:ok, arn}
      end
    end
  end

  defp find_service_arn(_, _), do: {:error, "no service arns returned"}

  defp extract_ips(%{"tasks" => tasks}) do
    ips =
      tasks
      |> Enum.flat_map(fn t -> Map.get(t, "containers", []) end)
      |> Enum.flat_map(fn c -> Map.get(c, "networkInterfaces", []) end)
      |> Enum.map(fn ni -> Map.get(ni, "privateIpv4Address") end)
      |> Enum.reject(&is_nil/1)

    # This is also done in the official Strategy such as DnsPoll
    # https://github.com/bitwalker/libcluster/blob/b8e3a13603539621c871ec9c8c3aece79856f31e/lib/strategy/dns_poll.ex#L117-L129
    # Limitation: Here we reject ECS Tasks based on Tasks' private IPs, meaning we cannot have multiple (but differently named) Erlang nodes in a single ECS Task
    case get_self_private_ip_from_hostname() do
      nil -> {:ok, ips}
      me -> {:ok, Enum.reject(ips, &(&1 == me))}
    end
  end

  defp extract_ips(_), do: {:error, "can't extract ips"}

  defp get_self_private_ip_from_hostname() do
    with(
      {:ok, hostname_charlist} <- :inet.gethostname(),
      # Default hostnames of ECS Tasks are in the form of "ip-xxx-xxx-xxx-xxx" and contains their private IPs
      "ip-" <> hyphenated_ip <- List.to_string(hostname_charlist)
    ) do
      String.replace(hyphenated_ip, "-", ".")
    else
      _not_in_ECS_task_or_hostname_unavailable -> nil
    end
  end

  defp ip_to_nodename(ip, app_prefix) do
    :"#{app_prefix}@#{ip}"
  end
end
