defmodule Mix.Tasks.Nif.Build do
  @moduledoc """
  Build Rust NIFs for SIMD-accelerated vector operations.

  ## Usage

      mix nif.build [--release] [--clean]

  ## Options

    * `--release` - Build in release mode (default)
    * `--debug` - Build in debug mode
    * `--clean` - Clean build artifacts before building

  ## Prerequisites

  Rust must be installed: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`

  ## Output

  The built library will be copied to `priv/native/libvector_math.so` (Linux),
  `priv/native/libvector_math.dylib` (macOS), or `priv/native/vector_math.dll` (Windows).
  """

  use Mix.Task

  @shortdoc "Build Rust NIFs for vector math operations"

  @native_path "native/vector_math"
  @priv_path "priv/native"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [release: :boolean, debug: :boolean, clean: :boolean])

    build_mode = if opts[:debug], do: :debug, else: :release

    Mix.shell().info("🔨 Building Rust NIFs (#{build_mode} mode)...")

    # Check for Rust installation
    check_rust_installed!()

    # Clean if requested
    if opts[:clean] do
      Mix.shell().info("🧹 Cleaning build artifacts...")
      clean_build()
    end

    # Build NIF
    build_nif(build_mode)

    # Copy to priv
    copy_to_priv(build_mode)

    Mix.shell().info("✅ NIF build complete!")
  end

  defp check_rust_installed! do
    case System.cmd("rustc", ["--version"], stderr_to_stdout: true) do
      {version, 0} ->
        Mix.shell().info("  Rust version: #{String.trim(version)}")

      {_, _} ->
        Mix.raise("""
        Rust is not installed or not in PATH.

        Install Rust with:
          curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
          source ~/.cargo/env
        """)
    end
  end

  defp clean_build do
    System.cmd("cargo", ["clean"], cd: @native_path, stderr_to_stdout: true)
  end

  defp build_nif(build_mode) do
    args =
      case build_mode do
        :release -> ["build", "--release"]
        :debug -> ["build"]
      end

    case System.cmd("cargo", args, cd: @native_path, into: IO.stream(:stdio, :line)) do
      {_, 0} ->
        :ok

      {output, code} ->
        Mix.raise("Cargo build failed with exit code #{code}:\n#{output}")
    end
  end

  defp copy_to_priv(build_mode) do
    # Ensure priv/native directory exists
    File.mkdir_p!(@priv_path)

    mode_dir = if build_mode == :release, do: "release", else: "debug"
    source_dir = Path.join([@native_path, "target", mode_dir])

    # Determine library name based on OS
    {lib_name, dest_name} =
      case :os.type() do
        {:unix, :darwin} ->
          {"libvector_math.dylib", "libvector_math.so"}

        {:unix, _} ->
          {"libvector_math.so", "libvector_math.so"}

        {:win32, _} ->
          {"vector_math.dll", "vector_math.dll"}
      end

    source = Path.join(source_dir, lib_name)
    dest = Path.join(@priv_path, dest_name)

    if File.exists?(source) do
      File.cp!(source, dest)
      Mix.shell().info("  Copied #{lib_name} -> #{dest}")
    else
      Mix.raise("Built library not found at #{source}")
    end
  end
end
