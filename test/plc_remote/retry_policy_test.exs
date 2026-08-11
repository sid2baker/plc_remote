defmodule PlcRemote.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias PlcRemote.RetryPolicy

  test "retries quickly before reaching a bounded five-minute delay" do
    assert RetryPolicy.base_delay(1) == 5_000
    assert RetryPolicy.base_delay(2) == 15_000
    assert RetryPolicy.base_delay(4) == 60_000
    assert RetryPolicy.base_delay(20) == 300_000
  end

  test "jitter remains within twenty percent" do
    for _attempt <- 1..100 do
      delay = RetryPolicy.delay(3)
      assert delay in 24_000..36_000
    end
  end
end
