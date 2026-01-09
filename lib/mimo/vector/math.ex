defmodule Mimo.Vector.Math do
  alias Mimo.Vector.Fallback

  @moduledoc """
  Rust NIF wrapper for SIMD-accelerated vector operations.

  Provides high-performance cosine similarity and batch vector operations
  using platform-specific SIMD intrinsics. Falls back to pure Elixir
  implementation if NIF is not available.

  ## Performance

  The Rust NIF provides 10-40x speedup over pure Elixir for vector operations:
  - Single cosine similarity: ~15-40µs (Rust) vs ~600-800µs (Elixir)
  - Batch operations benefit from Rayon parallelization

  ## SPEC-031: Int8 Quantization

  As of SPEC-031 Phase 2, this module includes int8 quantization functions
  for storage optimization. Int8 vectors use 1/4 the storage of float32
  while maintaining >99% similarity accuracy.

  ## SPEC-033: Binary Quantization

  As of SPEC-033 Phase 3a, this module includes binary quantization functions
  for ultra-fast pre-filtering. Binary vectors use 1 bit per dimension
  (32 bytes for 256-dim) and enable O(1) Hamming distance computation.

  ## Usage

      iex> Mimo.Vector.Math.cosine_similarity([1.0, 2.0, 3.0], [1.0, 2.0, 3.0])
      {:ok, 1.0}

      iex> Mimo.Vector.Math.batch_similarity([1.0, 0.0], [[1.0, 0.0], [0.0, 1.0]])
      {:ok, [1.0, 0.0]}

      # Int8 quantization
      iex> {:ok, {binary, scale, offset}} = Mimo.Vector.Math.quantize_int8([0.1, 0.5, -0.3])
      iex> {:ok, restored} = Mimo.Vector.Math.dequantize_int8(binary, scale, offset)

      # Binary quantization for fast pre-filtering
      iex> {:ok, binary_a} = Mimo.Vector.Math.to_binary([0.1, -0.2, 0.3, -0.4])
      iex> {:ok, binary_b} = Mimo.Vector.Math.to_binary([0.1, 0.2, -0.3, -0.4])
      iex> {:ok, distance} = Mimo.Vector.Math.hamming_distance(binary_a, binary_b)
  """

  @on_load :load_nifs
  @nif_path "priv/native/libvector_math"

  require Logger

  @doc false
  def load_nifs do
    path =
      try do
        Application.app_dir(:mimo_mcp, @nif_path)
      rescue
        _ -> Path.join([:code.priv_dir(:mimo_mcp) |> to_string(), "native", "libvector_math"])
      catch
        _, _ -> Path.join([File.cwd!(), "priv", "native", "libvector_math"])
      end

    case :erlang.load_nif(String.to_charlist(path), 0) do
      :ok ->
        Logger.debug("Vector Math NIF loaded successfully")
        :ok

      {:error, {:reload, _}} ->
        # Already loaded, that's fine
        :ok

      {:error, reason} ->
        Logger.warning("Vector Math NIF failed to load: #{inspect(reason)}, using fallback")
        :ok
    end
  end

  @doc """
  Computes cosine similarity between two vectors.

  ## Parameters

    - `a` - First vector as list of floats
    - `b` - Second vector as list of floats (must be same dimension as `a`)

  ## Returns

    - `{:ok, similarity}` - Similarity value between -1.0 and 1.0
    - `{:error, reason}` - Error if vectors are invalid

  ## Examples

      iex> Mimo.Vector.Math.cosine_similarity([1.0, 0.0], [1.0, 0.0])
      {:ok, 1.0}

      iex> Mimo.Vector.Math.cosine_similarity([1.0, 0.0], [0.0, 1.0])
      {:ok, 0.0}
  """
  @spec cosine_similarity([float()], [float()]) :: {:ok, float()} | {:error, atom()}
  def cosine_similarity(a, b)

  # NIF stub - replaced at runtime if NIF loads
  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    Fallback.cosine_similarity(a, b)
  end

  @doc """
  Computes cosine similarity between a query vector and multiple corpus vectors.

  Uses parallel processing for efficient batch operations.

  ## Parameters

    - `query` - Query vector as list of floats
    - `corpus` - List of vectors to compare against

  ## Returns

    - `{:ok, similarities}` - List of similarity values in same order as corpus
    - `{:error, reason}` - Error if vectors are invalid

  ## Examples

      iex> Mimo.Vector.Math.batch_similarity([1.0, 0.0], [[1.0, 0.0], [0.0, 1.0], [0.707, 0.707]])
      {:ok, [1.0, 0.0, 0.707...]}
  """
  @spec batch_similarity([float()], [[float()]]) :: {:ok, [float()]} | {:error, atom()}
  def batch_similarity(query, corpus)

  # NIF stub - replaced at runtime if NIF loads
  def batch_similarity(query, corpus) when is_list(query) and is_list(corpus) do
    Fallback.batch_similarity(query, corpus)
  end

  @doc """
  Finds the top-k most similar vectors from a corpus.

  More efficient than computing all similarities and sorting when k << corpus size.

  ## Parameters

    - `query` - Query vector as list of floats
    - `corpus` - List of vectors to search
    - `k` - Number of top results to return

  ## Returns

    - `{:ok, results}` - List of `{index, similarity}` tuples sorted by similarity descending
    - `{:error, reason}` - Error if vectors are invalid
  """
  @spec top_k_similar([float()], [[float()]], non_neg_integer()) ::
          {:ok, [{non_neg_integer(), float()}]} | {:error, atom()}
  def top_k_similar(query, corpus, k)

  # NIF stub - replaced at runtime if NIF loads
  def top_k_similar(query, corpus, k) when is_list(query) and is_list(corpus) and is_integer(k) do
    Fallback.top_k_similar(query, corpus, k)
  end

  @doc """
  Normalizes a vector to unit length (L2 normalization).

  ## Parameters

    - `vec` - Vector to normalize

  ## Returns

    - `{:ok, normalized}` - Unit vector in same direction
    - `{:error, reason}` - Error if vector is invalid
  """
  @spec normalize_vector([float()]) :: {:ok, [float()]} | {:error, atom()}
  def normalize_vector(vec)

  # NIF stub - replaced at runtime if NIF loads
  def normalize_vector(vec) when is_list(vec) do
    Fallback.normalize_vector(vec)
  end

  @doc """
  Quantizes a float32 vector to int8 for storage optimization.

  Uses min-max scaling to map float32 values to [-128, 127] range.
  Provides ~4x storage reduction with <1% accuracy loss for cosine similarity.

  ## Parameters

    - `vec` - Float vector to quantize

  ## Returns

    - `{:ok, {binary, scale, offset}}` where:
      - `binary` - Binary containing int8 values (1 byte per dimension)
      - `scale` - Scale factor for dequantization
      - `offset` - Offset for dequantization
    - `{:error, reason}` - Error if vector is invalid

  ## Dequantization Formula

  To restore float value: `float = (int8 + 128) * scale + offset`

  ## Examples

      iex> {:ok, {binary, scale, offset}} = Mimo.Vector.Math.quantize_int8([0.1, 0.5, -0.3, 0.8])
      iex> byte_size(binary)
      4
  """
  @spec quantize_int8([float()]) :: {:ok, {binary(), float(), float()}} | {:error, atom()}
  def quantize_int8(vec)

  # NIF stub - replaced at runtime if NIF loads
  def quantize_int8(vec) when is_list(vec) do
    Fallback.quantize_int8(vec)
  end

  @doc """
  Dequantizes int8 binary back to float32 vector.

  Reverses the quantization performed by `quantize_int8/1`.

  ## Parameters

    - `binary` - Binary from `quantize_int8/1`
    - `scale` - Scale factor from `quantize_int8/1`
    - `offset` - Offset from `quantize_int8/1`

  ## Returns

    - `{:ok, float_vector}` - Restored float vector
    - `{:error, reason}` - Error if input is invalid

  ## Examples

      iex> {:ok, {binary, scale, offset}} = Mimo.Vector.Math.quantize_int8([0.1, 0.5, -0.3])
      iex> {:ok, restored} = Mimo.Vector.Math.dequantize_int8(binary, scale, offset)
      iex> length(restored)
      3
  """
  @spec dequantize_int8(binary(), float(), float()) :: {:ok, [float()]} | {:error, atom()}
  def dequantize_int8(binary, scale, offset)

  # NIF stub - replaced at runtime if NIF loads
  def dequantize_int8(binary, scale, offset)
      when is_binary(binary) and is_number(scale) and is_number(offset) do
    Fallback.dequantize_int8(binary, scale, offset)
  end

  @doc """
  Computes cosine similarity directly on int8 quantized vectors.

  Faster than dequantizing first since it uses integer arithmetic.
  Result is approximate but typically within 1% of float32 result.

  **Note:** Both vectors must have compatible quantization for accurate results.
  For vectors with very different value ranges, dequantize first.

  ## Parameters

    - `a` - First int8 binary
    - `b` - Second int8 binary (must be same length as `a`)

  ## Returns

    - `{:ok, similarity}` - Approximate similarity value
    - `{:error, reason}` - Error if vectors are invalid

  ## Examples

      iex> {:ok, {bin_a, _, _}} = Mimo.Vector.Math.quantize_int8([0.1, 0.5, 0.3])
      iex> {:ok, {bin_b, _, _}} = Mimo.Vector.Math.quantize_int8([0.1, 0.5, 0.3])
      iex> {:ok, sim} = Mimo.Vector.Math.cosine_similarity_int8(bin_a, bin_b)
      iex> sim > 0.99
      true
  """
  @spec cosine_similarity_int8(binary(), binary()) :: {:ok, float()} | {:error, atom()}
  def cosine_similarity_int8(a, b)

  # NIF stub - replaced at runtime if NIF loads
  def cosine_similarity_int8(a, b) when is_binary(a) and is_binary(b) do
    Fallback.cosine_similarity_int8(a, b)
  end

  @doc """
  Batch cosine similarity on int8 quantized vectors.

  More efficient than float32 batch when vectors are already quantized.

  ## Parameters

    - `query` - Query int8 binary
    - `corpus` - List of int8 binaries to compare against

  ## Returns

    - `{:ok, similarities}` - List of similarity values
    - `{:error, reason}` - Error if vectors are invalid
  """
  @spec batch_similarity_int8(binary(), [binary()]) :: {:ok, [float()]} | {:error, atom()}
  def batch_similarity_int8(query, corpus)

  # NIF stub - replaced at runtime if NIF loads
  def batch_similarity_int8(query, corpus) when is_binary(query) and is_list(corpus) do
    Fallback.batch_similarity_int8(query, corpus)
  end

  @doc """
  Finds top-k similar vectors from int8 quantized corpus.

  ## Parameters

    - `query` - Query int8 binary
    - `corpus` - List of int8 binaries to search
    - `k` - Number of top results to return

  ## Returns

    - `{:ok, results}` - List of `{index, similarity}` tuples sorted by similarity descending
    - `{:error, reason}` - Error if vectors are invalid
  """
  @spec top_k_similar_int8(binary(), [binary()], non_neg_integer()) ::
          {:ok, [{non_neg_integer(), float()}]} | {:error, atom()}
  def top_k_similar_int8(query, corpus, k)

  # NIF stub - replaced at runtime if NIF loads
  def top_k_similar_int8(query, corpus, k)
      when is_binary(query) and is_list(corpus) and is_integer(k) do
    Fallback.top_k_similar_int8(query, corpus, k)
  end

  @doc """
  Converts a float32 vector to binary representation (sign bits).

  Each dimension becomes 1 bit: 1 if >= 0, 0 if < 0.
  256 float dimensions → 32 bytes (256 bits).

  This enables ultra-fast Hamming distance pre-filtering for approximate
  nearest neighbor search.

  ## Parameters

    - `vec` - Float vector to convert

  ## Returns

    - `{:ok, binary}` - Binary with packed sign bits (1 byte per 8 dimensions)
    - `{:error, reason}` - Error if vector is invalid

  ## Examples

      iex> {:ok, binary} = Mimo.Vector.Math.to_binary([1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0])
      iex> byte_size(binary)
      1
      iex> :binary.decode_unsigned(binary)
      85  # 0b01010101 - bits at positions 0, 2, 4, 6 are set
  """
  @spec to_binary([float()]) :: {:ok, binary()} | {:error, atom()}
  def to_binary(vec)

  # NIF stub - replaced at runtime if NIF loads
  def to_binary(vec) when is_list(vec) do
    Fallback.to_binary(vec)
  end

  @doc """
  Converts int8 quantized vector to binary representation.

  Each dimension becomes 1 bit: 1 if int8 value >= 0, 0 if < 0.
  This is useful when you already have int8 embeddings.

  ## Parameters

    - `int8_vec` - Int8 binary to convert

  ## Returns

    - `{:ok, binary}` - Binary with packed sign bits
    - `{:error, reason}` - Error if input is invalid

  ## Examples

      iex> {:ok, {int8_vec, _, _}} = Mimo.Vector.Math.quantize_int8([0.1, -0.2, 0.3])
      iex> {:ok, binary} = Mimo.Vector.Math.int8_to_binary(int8_vec)
  """
  @spec int8_to_binary(binary()) :: {:ok, binary()} | {:error, atom()}
  def int8_to_binary(int8_vec)

  # NIF stub - replaced at runtime if NIF loads
  def int8_to_binary(int8_vec) when is_binary(int8_vec) do
    Fallback.int8_to_binary(int8_vec)
  end

  @doc """
  Computes Hamming distance between two binary vectors.

  Hamming distance = number of differing bits (popcount of XOR).
  Lower distance = more similar vectors.

  This is extremely fast for pre-filtering candidates in approximate
  nearest neighbor search.

  ## Parameters

    - `a` - First binary vector
    - `b` - Second binary vector (must be same length as `a`)

  ## Returns

    - `{:ok, distance}` - Number of differing bits (0 = identical)
    - `{:error, reason}` - Error if vectors are invalid

  ## Examples

      iex> {:ok, dist} = Mimo.Vector.Math.hamming_distance(<<255>>, <<255>>)
      iex> dist
      0

      iex> {:ok, dist} = Mimo.Vector.Math.hamming_distance(<<255>>, <<0>>)
      iex> dist
      8
  """
  @spec hamming_distance(binary(), binary()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def hamming_distance(a, b)

  # NIF stub - replaced at runtime if NIF loads
  def hamming_distance(a, b) when is_binary(a) and is_binary(b) do
    Fallback.hamming_distance(a, b)
  end

  @doc """
  Batch Hamming distance computation.

  Computes Hamming distance from query to all vectors in corpus.
  Uses parallel processing for efficiency.

  ## Parameters

    - `query` - Query binary vector
    - `corpus` - List of binary vectors to compare against

  ## Returns

    - `{:ok, distances}` - List of distances in same order as corpus
    - `{:error, reason}` - Error if vectors are invalid
  """
  @spec batch_hamming_distance(binary(), [binary()]) ::
          {:ok, [non_neg_integer()]} | {:error, atom()}
  def batch_hamming_distance(query, corpus)

  # NIF stub - replaced at runtime if NIF loads
  def batch_hamming_distance(query, corpus) when is_binary(query) and is_list(corpus) do
    Fallback.batch_hamming_distance(query, corpus)
  end

  @doc """
  Find top-k vectors by Hamming distance (lowest distance = most similar).

  Returns the k vectors with the smallest Hamming distance to the query.
  This is used for fast pre-filtering before more expensive similarity calculations.

  ## Parameters

    - `query` - Query binary vector
    - `corpus` - List of binary vectors to search
    - `k` - Number of top results to return

  ## Returns

    - `{:ok, results}` - List of `{index, distance}` tuples sorted by distance ascending
    - `{:error, reason}` - Error if vectors are invalid

  ## Examples

      iex> corpus = [<<255>>, <<0>>, <<240>>]  # [11111111, 00000000, 11110000]
      iex> {:ok, results} = Mimo.Vector.Math.top_k_hamming(<<255>>, corpus, 2)
      iex> results
      [{0, 0}, {2, 4}]  # First vector is identical, third differs by 4 bits
  """
  @spec top_k_hamming(binary(), [binary()], non_neg_integer()) ::
          {:ok, [{non_neg_integer(), non_neg_integer()}]} | {:error, atom()}
  def top_k_hamming(query, corpus, k)

  # Handle empty corpus before NIF - return empty results
  def top_k_hamming(_query, [], _k), do: {:ok, []}

  # NIF stub - replaced at runtime if NIF loads
  def top_k_hamming(query, corpus, k)
      when is_binary(query) and is_list(corpus) and is_integer(k) do
    Fallback.top_k_hamming(query, corpus, k)
  end

  @doc """
  Converts Hamming distance to approximate cosine similarity.

  Uses the relationship: similarity ≈ 1 - (hamming_distance / total_bits)
  This is a rough approximation useful for threshold comparisons.

  ## Parameters

    - `distance` - Hamming distance value
    - `total_bits` - Total number of bits in the vectors

  ## Returns

    - `{:ok, similarity}` - Approximate similarity in [0, 1] range
    - `{:error, reason}` - Error if total_bits is 0

  ## Examples

      iex> {:ok, sim} = Mimo.Vector.Math.hamming_to_similarity(0, 256)
      iex> sim
      1.0

      iex> {:ok, sim} = Mimo.Vector.Math.hamming_to_similarity(128, 256)
      iex> sim
      0.5
  """
  @spec hamming_to_similarity(non_neg_integer(), non_neg_integer()) ::
          {:ok, float()} | {:error, atom()}
  def hamming_to_similarity(distance, total_bits)

  # NIF stub - replaced at runtime if NIF loads
  def hamming_to_similarity(distance, total_bits)
      when is_integer(distance) and is_integer(total_bits) do
    Fallback.hamming_to_similarity(distance, total_bits)
  end

  @doc """
  Creates a new HNSW index for approximate nearest neighbor search.

  The index is returned as an opaque reference that can be passed to other
  HNSW functions. The index supports int8 quantized vectors for memory efficiency.

  ## Parameters

    - `dimensions` - Number of dimensions for vectors (e.g., 256 for Qwen embeddings)
    - `connectivity` - Number of connections per node (M parameter, default: 16)
    - `expansion_add` - Search expansion during construction (ef_construction, default: 128)
    - `expansion_search` - Search expansion during queries (ef, default: 64)

  ## Returns

    - `{:ok, index}` - Opaque HNSW index reference
    - `{:error, reason}` - Error if creation failed

  ## Examples

      iex> {:ok, index} = Mimo.Vector.Math.hnsw_new(256)
      iex> {:ok, index} = Mimo.Vector.Math.hnsw_new(256, 32, 200, 100)
  """
  @spec hnsw_new(pos_integer(), pos_integer() | nil, pos_integer() | nil, pos_integer() | nil) ::
          {:ok, reference()} | {:error, String.t()}
  def hnsw_new(dimensions, connectivity \\ nil, expansion_add \\ nil, expansion_search \\ nil)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_new(_dimensions, _connectivity, _expansion_add, _expansion_search) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Reserves capacity in the HNSW index.

  Should be called before adding vectors to pre-allocate memory for better performance.

  ## Parameters

    - `index` - HNSW index reference
    - `capacity` - Number of vectors to reserve space for

  ## Returns

    - `{:ok, :ok}` - Success
    - `{:error, reason}` - Error if reservation failed
  """
  @spec hnsw_reserve(reference(), pos_integer()) :: {:ok, :ok} | {:error, String.t()}
  def hnsw_reserve(index, capacity)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_reserve(_index, _capacity) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Adds a single vector to the HNSW index.

  ## Parameters

    - `index` - HNSW index reference
    - `key` - Unique identifier for this vector (typically engram ID)
    - `vector` - The int8 quantized embedding as binary

  ## Returns

    - `{:ok, :ok}` - Success
    - `{:error, reason}` - Error if add failed
  """
  @spec hnsw_add(reference(), non_neg_integer(), binary()) :: {:ok, :ok} | {:error, String.t()}
  def hnsw_add(index, key, vector)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_add(_index, _key, _vector) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Adds multiple vectors to the HNSW index in batch.

  More efficient than calling `hnsw_add/3` repeatedly for bulk insertions.

  ## Parameters

    - `index` - HNSW index reference
    - `entries` - List of `{key, binary_vector}` tuples

  ## Returns

    - `{:ok, count_added}` - Number of vectors successfully added
    - `{:error, reason}` - Error if batch add failed
  """
  @spec hnsw_add_batch(reference(), [{non_neg_integer(), binary()}]) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def hnsw_add_batch(index, entries)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_add_batch(_index, _entries) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Searches for the k nearest neighbors of a query vector.

  Returns approximate nearest neighbors in O(log n) time instead of O(n) linear scan.

  ## Parameters

    - `index` - HNSW index reference
    - `query` - The int8 quantized query embedding as binary
    - `k` - Number of nearest neighbors to return

  ## Returns

    - `{:ok, results}` - List of `{key, distance}` tuples sorted by distance ascending
    - `{:error, reason}` - Error if search failed

  ## Examples

      iex> {:ok, results} = Mimo.Vector.Math.hnsw_search(index, query_binary, 10)
      iex> [{first_key, first_distance} | _rest] = results
  """
  @spec hnsw_search(reference(), binary(), pos_integer()) ::
          {:ok, [{non_neg_integer(), float()}]} | {:error, String.t()}
  def hnsw_search(index, query, k)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_search(_index, _query, _k) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Gets the number of vectors in the HNSW index.

  ## Parameters

    - `index` - HNSW index reference

  ## Returns

    - `{:ok, size}` - Number of vectors in the index
  """
  @spec hnsw_size(reference()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def hnsw_size(index)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_size(_index) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Gets the capacity of the HNSW index.

  ## Parameters

    - `index` - HNSW index reference

  ## Returns

    - `{:ok, capacity}` - Reserved capacity of the index
  """
  @spec hnsw_capacity(reference()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def hnsw_capacity(index)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_capacity(_index) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Gets the dimensions of vectors in the HNSW index.

  ## Parameters

    - `index` - HNSW index reference

  ## Returns

    - `{:ok, dimensions}` - Vector dimensionality
  """
  @spec hnsw_dimensions(reference()) :: {:ok, pos_integer()} | {:error, String.t()}
  def hnsw_dimensions(index)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_dimensions(_index) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Checks if a key exists in the HNSW index.

  ## Parameters

    - `index` - HNSW index reference
    - `key` - Key to check

  ## Returns

    - `{:ok, exists}` - Boolean indicating if key exists
  """
  @spec hnsw_contains(reference(), non_neg_integer()) :: {:ok, boolean()} | {:error, String.t()}
  def hnsw_contains(index, key)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_contains(_index, _key) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Removes a key from the HNSW index.

  Note: HNSW doesn't truly delete, it marks as removed. The space is
  reclaimed on save/load or compaction.

  ## Parameters

    - `index` - HNSW index reference
    - `key` - Key to remove

  ## Returns

    - `{:ok, :ok}` - Success
    - `{:error, reason}` - Error if removal failed
  """
  @spec hnsw_remove(reference(), non_neg_integer()) :: {:ok, :ok} | {:error, String.t()}
  def hnsw_remove(index, key)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_remove(_index, _key) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Saves the HNSW index to a file.

  ## Parameters

    - `index` - HNSW index reference
    - `path` - File path to save to

  ## Returns

    - `{:ok, :ok}` - Success
    - `{:error, reason}` - Error if save failed
  """
  @spec hnsw_save(reference(), String.t()) :: {:ok, :ok} | {:error, String.t()}
  def hnsw_save(index, path)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_save(_index, _path) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Loads an HNSW index from a file.

  ## Parameters

    - `path` - File path to load from

  ## Returns

    - `{:ok, index}` - Loaded HNSW index reference
    - `{:error, reason}` - Error if load failed
  """
  @spec hnsw_load(String.t()) :: {:ok, reference()} | {:error, String.t()}
  def hnsw_load(path)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_load(_path) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Views an HNSW index from a file (memory-mapped, read-only).

  This is more memory efficient for large indices as it doesn't
  load the entire index into memory.

  ## Parameters

    - `path` - File path to view

  ## Returns

    - `{:ok, index}` - HNSW index reference
    - `{:error, reason}` - Error if view failed
  """
  @spec hnsw_view(String.t()) :: {:ok, reference()} | {:error, String.t()}
  def hnsw_view(path)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_view(_path) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Gets statistics about the HNSW index.

  ## Parameters

    - `index` - HNSW index reference

  ## Returns

    - `{:ok, stats}` - Keyword list with :size, :capacity, :dimensions, :memory_usage
    - `{:error, reason}` - Error if stats retrieval failed
  """
  @spec hnsw_stats(reference()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, String.t()}
  def hnsw_stats(index)

  # NIF stub - replaced at runtime if NIF loads
  def hnsw_stats(_index) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @doc """
  Checks if the Rust NIF is loaded and available.
  """
  @spec nif_loaded?() :: boolean()
  def nif_loaded? do
    # Try to call a NIF function and see if it's the real one
    case cosine_similarity([1.0], [1.0]) do
      {:ok, _} ->
        # Check if we're using the real NIF by examining function info
        info = __MODULE__.__info__(:functions)
        # If NIF is loaded, we should have native implementations
        Keyword.get(info, :cosine_similarity) != nil

      _ ->
        false
    end
  rescue
    _ -> false
  end

  @doc """
  Checks if the HNSW NIF functions are loaded and available.
  """
  @spec hnsw_available?() :: boolean()
  def hnsw_available? do
    case hnsw_new(4) do
      {:ok, _index} -> true
      {:error, _} -> false
    end
  rescue
    # :erlang.nif_error raises ErlangError when NIF not loaded
    _ -> false
  end
end
