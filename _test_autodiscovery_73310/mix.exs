defmodule Test.MixProject do
  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:ecto, ">= 3.0.0"},
      {:jason, "~> 1.4", only: :dev}
    ]
  end
end
