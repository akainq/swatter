defmodule SwatterConformanceElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :swatter_conformance_elixir,
      version: "0.0.1",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # не 12/13.x: их tarball'ы не распаковываются erl_tar на OTP 29/Windows
      # ("inner tarball error, not owner"); не 10.x: security advisory
      # валит mix deps.get
      {:sentry, "~> 11.0"},
      {:jason, "~> 1.4"},
      {:hackney, "~> 1.20"}
    ]
  end
end
