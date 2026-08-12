defmodule PlcRemote.Tailscale.EnrollmentTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Tailscale.Enrollment

  test "redacts transient credentials from inspection" do
    secret = "tskey-auth-must-not-appear"
    enrollment = Enrollment.new(secret)

    refute inspect(enrollment) =~ secret
    assert inspect(enrollment) =~ "[FILTERED]"
    assert Enrollment.consume(enrollment) == secret
  end
end
