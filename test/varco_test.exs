defmodule VarcoTest do
  use ExUnit.Case
  doctest Varco

  test "greets the world" do
    assert Varco.hello() == :world
  end
end
