defmodule ClusterEcsTest do
  use ExUnit.Case
  alias Cluster.Strategy.State

  test "missing config" do
    state = %State{
      topology: ClusterEcs.Strategy,
      config: [
        cluster: cluster_arn(),
        region: region()
      ]
    }

    assert_raise KeyError, ~r(key :service_name not found), fn ->
      ClusterEcs.Strategy.get_nodes(state)
    end
  end

  test "misconfig" do
    state = %State{
      topology: ClusterEcs.Strategy,
      config: [
        cluster: cluster_arn(),
        service_name: [""],
        region: region()
      ]
    }

    assert {{:error, []}, log} = ExUnit.CaptureLog.with_log(fn -> ClusterEcs.Strategy.get_nodes(state) end)
    assert log =~ "ECS strategy is selected, but service_name is not configured correctly!"
  end

  test "gets those nodes" do
    state = %State{
      topology: ClusterEcs.Strategy,
      config: [
        cluster: cluster_arn(),
        service_name: service(),
        region: region()
      ]
    }

    assert {:ok, nodes} = ClusterEcs.Strategy.get_nodes(state)
    assert MapSet.size(nodes) > 0

    for node <- nodes do
      assert to_string(node) =~ ~r/app@\d{1,3}\.\d{1,3}\.(\d{1,3})\.(\d{1,3})/
    end
  end

  test "gets ips from list of services (also, local part of node names can be configured)" do
    state = %State{
      topology: ClusterEcs.Strategy,
      config: [
        cluster: cluster_arn(),
        service_name: [service()],
        region: region(),
        app_prefix: "custom"
      ]
    }

    assert {:ok, nodes} = ClusterEcs.Strategy.get_nodes(state)
    assert MapSet.size(nodes) > 0

    for node <- nodes do
      assert to_string(node) =~ ~r/custom@\d{1,3}\.\d{1,3}\.(\d{1,3})\.(\d{1,3})/
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
  defp service() do
    get_raw_string_via_aws_cli(~w(ecs list-services --cluster=#{cluster_arn()} --query=serviceArns))
    |> Jason.decode!()
    |> Enum.random()
  end
end
