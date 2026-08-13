defmodule PlcRemote.Tailscale.EnrollmentTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Tailscale.Enrollment

  test "validates and redacts transient credentials" do
    secret = "tskey-auth-must-not-appear"
    assert {:ok, enrollment} = Enrollment.new(secret)

    refute inspect(enrollment) =~ secret
    assert inspect(enrollment) =~ "[FILTERED]"
    assert Enrollment.consume(enrollment) == secret
  end

  test "rejects missing and implausible keys" do
    assert {:error, :missing_auth_key} = Enrollment.new("")
    assert {:error, :missing_auth_key} = Enrollment.new(nil)
    assert {:error, :invalid_auth_key} = Enrollment.new("not-a-tailnet-key")
  end
end
