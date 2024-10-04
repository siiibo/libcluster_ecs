defmodule ClusterEcsTest do
  use ExUnit.Case
  alias Cluster.Strategy.State

  setup_all do
    %{cluster: cluster_arn()}
  end

  test "missing config", context do
    state = %State{
      topology: ClusterEcs.Strategy,
      config: [
        cluster: context.cluster,
        region: region()
      ]
    }

    assert_raise KeyError, ~r(key :service_name not found), fn ->
      ClusterEcs.Strategy.get_nodes(state)
    end
  end

  test "misconfig", context do
    state = %State{
      topology: ClusterEcs.Strategy,
      config: [
        cluster: context.cluster,
        service_name: [""],
        region: region()
      ]
    }

    assert {{:error, "ECS strategy is selected, but service_name is not configured correctly!"}, log} = ExUnit.CaptureLog.with_log(fn -> ClusterEcs.Strategy.get_nodes(state) end)
    assert log =~ "ECS strategy is selected, but service_name is not configured correctly!"
  end

  test "gets those nodes", context do
    state = %State{
      topology: ClusterEcs.Strategy,
      config: [
        cluster: context.cluster,
        service_name: service(context.cluster),
        region: region()
      ]
    }

    assert {:ok, nodes} = ClusterEcs.Strategy.get_nodes(state)
    assert length(nodes) > 0

    for node <- nodes do
      assert to_string(node) =~ ~r/app@ip-\d{1,3}-\d{1,3}-(\d{1,3})-(\d{1,3})\.(?<region>.+)\.compute\.internal/
    end
  end

  test "gets ips from list of services (also, local part of node names can be configured)", context do
    state = %State{
      topology: ClusterEcs.Strategy,
      config: [
        cluster: context.cluster,
        service_name: [service(context.cluster)],
        region: region(),
        app_prefix: "custom"
      ]
    }

    assert {:ok, nodes} = ClusterEcs.Strategy.get_nodes(state)
    assert length(nodes) > 0

    for node <- nodes do
      assert to_string(node) =~ ~r/custom@ip-\d{1,3}-\d{1,3}-(\d{1,3})-(\d{1,3})\.(?<region>.+)\.compute\.internal/
    end
  end

  test "gets resources from cluster", context do
    # This test shows how to use functions to get resources (Their functions were private in original repository)
    region = region()
    {:ok, services} = ClusterEcs.Strategy.list_services(context.cluster, region)
    {:ok, service_arns} = ClusterEcs.Strategy.extract_service_arns(services)
    assert length(service_arns) > 0

    for service_arn <- service_arns do
      {:ok, tasks} = ClusterEcs.Strategy.list_tasks(context.cluster, service_arn, region)
      {:ok, task_arns} = ClusterEcs.Strategy.extract_task_arns(tasks)
      assert length(task_arns) > 0

      desc_tasks = ClusterEcs.Strategy.describe_tasks(context.cluster, task_arns, region)
      assert match?({:ok, _}, desc_tasks)
    end
  end

  # Since this package does not provide nor depend on full-featured ExAws.Ecs, we rely on aws-cli for testing.
  defp get_raw_string_via_aws_cli(args) do
    {output, 0} = System.cmd("aws", args)
    output |> String.trim() |> String.trim("\"")
  end

  # Your aws cli config must have default region to test.
  defp region(), do: get_raw_string_via_aws_cli(~W(configure get region))

  # Use random-found cluster as a test fixture. You must have one to test.
  defp cluster_arn() do
    get_raw_string_via_aws_cli(~W(ecs list-clusters --query=clusterArns))
    |> Jason.decode!()
    |> Enum.random()
  end

  # Use random-found service as a test fixture. You must have one in the cluster to test.
  defp service(cluster) do
    get_raw_string_via_aws_cli(~w(ecs list-services --cluster=#{cluster} --query=serviceArns))
    |> Jason.decode!()
    |> Enum.random()
  end
end
