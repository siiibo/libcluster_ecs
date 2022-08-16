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

    assert {{:error, []}, log} = ExUnit.CaptureLog.with_log(fn -> ClusterEcs.Strategy.get_nodes(state) end)
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
