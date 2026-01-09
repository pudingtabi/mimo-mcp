//! Vector Math NIF - SIMD-accelerated vector operations for Mimo-MCP
//!
//! Provides high-performance cosine similarity and batch vector operations
//! using platform-specific SIMD intrinsics.
//! 
//! SPEC-031 Phase 2: Added int8 quantization functions for storage optimization.
//! SPEC-033 Phase 3a: Added binary quantization and Hamming distance for fast pre-filtering.
//! SPEC-033 Phase 3b: Added HNSW index for O(log n) approximate nearest neighbor search.

use rayon::prelude::*;
use rustler::{Binary, Encoder, Env, NifResult, OwnedBinary, Term};

#[cfg(feature = "hnsw")]
use rustler::ResourceArc;

// HNSW module for SPEC-033 Phase 3b (requires "hnsw" feature flag)
#[cfg(feature = "hnsw")]
mod hnsw;
#[cfg(feature = "hnsw")]
pub use hnsw::HnswIndex;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        dimension_mismatch,
        empty_vector,
        empty_corpus,
    }
}

/// Computes cosine similarity between two vectors.
/// 
/// Scheduled on DirtyCpu to avoid blocking BEAM schedulers.
/// Returns {:ok, similarity} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
fn cosine_similarity<'a>(env: Env<'a>, a: Term<'a>, b: Term<'a>) -> NifResult<Term<'a>> {
    let vec_a: Vec<f32> = rustler::Decoder::decode(a)?;
    let vec_b: Vec<f32> = rustler::Decoder::decode(b)?;

    if vec_a.is_empty() || vec_b.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }

    if vec_a.len() != vec_b.len() {
        return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
    }

    let result = simd_cosine(&vec_a, &vec_b);
    Ok((atoms::ok(), result).encode(env))
}

/// Computes cosine similarity between a query vector and a corpus of vectors.
/// 
/// Uses Rayon for parallel processing across multiple cores.
/// Returns {:ok, [similarities]} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
fn batch_similarity<'a>(
    env: Env<'a>,
    query: Term<'a>,
    corpus: Term<'a>,
) -> NifResult<Term<'a>> {
    let query_vec: Vec<f32> = rustler::Decoder::decode(query)?;
    let corpus_vecs: Vec<Vec<f32>> = rustler::Decoder::decode(corpus)?;

    if query_vec.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }

    if corpus_vecs.is_empty() {
        return Ok((atoms::error(), atoms::empty_corpus()).encode(env));
    }

    // Validate all vectors have same dimension
    let dim = query_vec.len();
    for vec in &corpus_vecs {
        if vec.len() != dim {
            return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
        }
    }

    // Parallel computation using Rayon
    let results: Vec<f32> = corpus_vecs
        .par_iter()
        .map(|vec| simd_cosine(&query_vec, vec))
        .collect();

    Ok((atoms::ok(), results).encode(env))
}

/// Find top-k most similar vectors from corpus.
/// 
/// Returns {:ok, [{index, similarity}, ...]} sorted by similarity descending.
#[rustler::nif(schedule = "DirtyCpu")]
fn top_k_similar<'a>(
    env: Env<'a>,
    query: Term<'a>,
    corpus: Term<'a>,
    k: usize,
) -> NifResult<Term<'a>> {
    let query_vec: Vec<f32> = rustler::Decoder::decode(query)?;
    let corpus_vecs: Vec<Vec<f32>> = rustler::Decoder::decode(corpus)?;

    if query_vec.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env))
    }

    if corpus_vecs.is_empty() {
        return Ok((atoms::error(), atoms::empty_corpus()).encode(env));
    }

    let dim = query_vec.len();
    for vec in &corpus_vecs {
        if vec.len() != dim {
            return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
        }
    }

    // Compute all similarities with indices
    let mut indexed_results: Vec<(usize, f32)> = corpus_vecs
        .par_iter()
        .enumerate()
        .map(|(idx, vec)| (idx, simd_cosine(&query_vec, vec)))
        .collect();

    // Partial sort for top-k (more efficient than full sort)
    let k = k.min(indexed_results.len());
    indexed_results.select_nth_unstable_by(k.saturating_sub(1), |a, b| {
        b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)
    });

    // Sort just the top-k
    indexed_results.truncate(k);
    indexed_results.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    Ok((atoms::ok(), indexed_results).encode(env))
}

/// Normalizes a vector to unit length (L2 normalization).
#[rustler::nif]
fn normalize_vector<'a>(env: Env<'a>, vec: Term<'a>) -> NifResult<Term<'a>> {
    let input: Vec<f32> = rustler::Decoder::decode(vec)?;
    
    if input.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }

    let magnitude: f32 = input.iter().map(|x| x * x).sum::<f32>().sqrt();
    
    if magnitude == 0.0 {
        return Ok((atoms::ok(), input).encode(env));
    }

    let normalized: Vec<f32> = input.iter().map(|x| x / magnitude).collect();
    Ok((atoms::ok(), normalized).encode(env))
}

// =============================================================================
// SPEC-031 Phase 2: Int8 Quantization Functions
// =============================================================================

/// Quantizes a float32 vector to int8 for storage optimization.
/// 
/// Uses min-max scaling to map float32 values to [-128, 127] range.
/// Returns {:ok, {quantized_binary, scale, offset}} where:
/// - quantized_binary: Binary with int8 values
/// - scale: Scale factor for dequantization
/// - offset: Offset for dequantization
/// 
/// To dequantize: float = (int8 + 128) * scale + offset
#[rustler::nif]
fn quantize_int8<'a>(env: Env<'a>, vec: Term<'a>) -> NifResult<Term<'a>> {
    let input: Vec<f32> = rustler::Decoder::decode(vec)?;
    
    if input.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }

    // Find min/max for scaling
    let min_val = input.iter().cloned().fold(f32::INFINITY, f32::min);
    let max_val = input.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
    
    // Calculate scale and offset
    let range = max_val - min_val;
    let scale = if range == 0.0 { 1.0 } else { range / 255.0 };
    let offset = min_val;
    
    // Quantize to int8 (-128 to 127)
    let quantized: Vec<u8> = input.iter()
        .map(|&v| {
            let normalized = if scale == 0.0 { 0.0 } else { (v - offset) / scale };
            // Map 0-255 to -128 to 127, then store as unsigned byte
            ((normalized - 128.0).clamp(-128.0, 127.0) as i8) as u8
        })
        .collect();
    
    // Create proper binary for Elixir
    let mut binary = OwnedBinary::new(quantized.len()).unwrap();
    binary.as_mut_slice().copy_from_slice(&quantized);
    
    Ok((atoms::ok(), (binary.release(env), scale, offset)).encode(env))
}

/// Dequantizes int8 binary back to float32 vector.
/// 
/// Takes the binary from quantize_int8 along with scale and offset.
/// Returns {:ok, float_vector}
#[rustler::nif]
fn dequantize_int8<'a>(
    env: Env<'a>,
    binary: Binary<'a>,
    scale: f64,
    offset: f64,
) -> NifResult<Term<'a>> {
    if binary.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }
    
    let scale = scale as f32;
    let offset = offset as f32;
    
    // Dequantize: interpret as signed, then reverse the quantization
    let dequantized: Vec<f32> = binary.as_slice().iter()
        .map(|&x| {
            let signed = x as i8;
            (signed as f32 + 128.0) * scale + offset
        })
        .collect();
    
    Ok((atoms::ok(), dequantized).encode(env))
}

/// Computes cosine similarity directly on int8 quantized vectors.
/// 
/// This is faster than dequantizing first since we use integer arithmetic.
/// The result is approximate but typically within 1% of the float32 result.
/// 
/// Note: Both vectors must have been quantized with the SAME scale/offset
/// for this to be accurate. For vectors with different quantization params,
/// dequantize first.
#[rustler::nif(schedule = "DirtyCpu")]
fn cosine_similarity_int8<'a>(
    env: Env<'a>,
    a: Binary<'a>,
    b: Binary<'a>,
) -> NifResult<Term<'a>> {
    if a.is_empty() || b.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }

    if a.len() != b.len() {
        return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
    }

    // Compute directly on byte slices
    let result = int8_cosine(a.as_slice(), b.as_slice());
    Ok((atoms::ok(), result).encode(env))
}

/// Batch cosine similarity on int8 quantized vectors.
/// 
/// More efficient than the float32 version when vectors are already quantized.
#[rustler::nif(schedule = "DirtyCpu")]
fn batch_similarity_int8<'a>(
    env: Env<'a>,
    query: Binary<'a>,
    corpus: Term<'a>,
) -> NifResult<Term<'a>> {
    if query.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }
    
    // Decode corpus as list of binaries
    let corpus_binaries: Vec<Binary> = rustler::Decoder::decode(corpus)?;

    if corpus_binaries.is_empty() {
        return Ok((atoms::error(), atoms::empty_corpus()).encode(env));
    }

    let dim = query.len();
    for bin in &corpus_binaries {
        if bin.len() != dim {
            return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
        }
    }

    // Convert to slices for parallel processing
    let query_slice = query.as_slice();
    let corpus_slices: Vec<&[u8]> = corpus_binaries.iter().map(|b| b.as_slice()).collect();

    // Parallel computation
    let results: Vec<f32> = corpus_slices
        .par_iter()
        .map(|slice| int8_cosine(query_slice, slice))
        .collect();

    Ok((atoms::ok(), results).encode(env))
}

/// Find top-k similar vectors from int8 quantized corpus.
#[rustler::nif(schedule = "DirtyCpu")]
fn top_k_similar_int8<'a>(
    env: Env<'a>,
    query: Binary<'a>,
    corpus: Term<'a>,
    k: usize,
) -> NifResult<Term<'a>> {
    if query.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }
    
    // Decode corpus as list of binaries
    let corpus_binaries: Vec<Binary> = rustler::Decoder::decode(corpus)?;

    if corpus_binaries.is_empty() {
        return Ok((atoms::error(), atoms::empty_corpus()).encode(env));
    }

    let dim = query.len();
    for bin in &corpus_binaries {
        if bin.len() != dim {
            return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
        }
    }

    // Convert to slices for parallel processing
    let query_slice = query.as_slice();
    let corpus_slices: Vec<&[u8]> = corpus_binaries.iter().map(|b| b.as_slice()).collect();

    // Compute all similarities with indices
    let mut indexed_results: Vec<(usize, f32)> = corpus_slices
        .par_iter()
        .enumerate()
        .map(|(idx, slice)| (idx, int8_cosine(query_slice, slice)))
        .collect();

    // Partial sort for top-k
    let k = k.min(indexed_results.len());
    indexed_results.select_nth_unstable_by(k.saturating_sub(1), |a, b| {
        b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)
    });

    indexed_results.truncate(k);
    indexed_results.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    Ok((atoms::ok(), indexed_results).encode(env))
}

// =============================================================================
// SPEC-033 Phase 3a: Binary Quantization Functions
// =============================================================================

/// Converts a float32 vector to binary representation (sign bits).
/// 
/// Each dimension becomes 1 bit: 1 if >= 0, 0 if < 0.
/// 256 float dimensions → 32 bytes (256 bits).
/// 
/// This enables ultra-fast Hamming distance pre-filtering.
/// Returns {:ok, binary} or {:error, reason}
#[rustler::nif]
fn to_binary<'a>(env: Env<'a>, vec: Term<'a>) -> NifResult<Term<'a>> {
    let input: Vec<f32> = rustler::Decoder::decode(vec)?;
    
    if input.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }
    
    // Pack 8 sign bits into each byte (LSB first)
    let byte_count = (input.len() + 7) / 8;
    let mut binary_vec: Vec<u8> = vec![0u8; byte_count];
    
    for (i, &v) in input.iter().enumerate() {
        if v >= 0.0 {
            let byte_idx = i / 8;
            let bit_idx = i % 8;
            binary_vec[byte_idx] |= 1 << bit_idx;
        }
    }
    
    // Create proper binary for Elixir
    let mut owned = OwnedBinary::new(binary_vec.len()).unwrap();
    owned.as_mut_slice().copy_from_slice(&binary_vec);
    
    Ok((atoms::ok(), owned.release(env)).encode(env))
}

/// Converts int8 quantized vector to binary representation.
/// 
/// Each dimension becomes 1 bit: 1 if int8 value >= 0, 0 if < 0.
/// 256 int8 dimensions → 32 bytes (256 bits).
/// 
/// This is useful when you already have int8 embeddings.
/// Returns {:ok, binary} or {:error, reason}
#[rustler::nif]
fn int8_to_binary<'a>(env: Env<'a>, int8_vec: Binary<'a>) -> NifResult<Term<'a>> {
    if int8_vec.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }
    
    let input = int8_vec.as_slice();
    
    // Pack 8 sign bits into each byte (LSB first)
    let byte_count = (input.len() + 7) / 8;
    let mut binary_vec: Vec<u8> = vec![0u8; byte_count];
    
    for (i, &v) in input.iter().enumerate() {
        // Interpret as signed: values >= 0 get bit 1
        let signed = v as i8;
        if signed >= 0 {
            let byte_idx = i / 8;
            let bit_idx = i % 8;
            binary_vec[byte_idx] |= 1 << bit_idx;
        }
    }
    
    // Create proper binary for Elixir
    let mut owned = OwnedBinary::new(binary_vec.len()).unwrap();
    owned.as_mut_slice().copy_from_slice(&binary_vec);
    
    Ok((atoms::ok(), owned.release(env)).encode(env))
}

/// Computes Hamming distance between two binary vectors.
/// 
/// Hamming distance = number of differing bits (popcount of XOR).
/// Lower distance = more similar vectors.
/// 
/// Returns {:ok, distance} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
fn hamming_distance<'a>(
    env: Env<'a>,
    a: Binary<'a>,
    b: Binary<'a>,
) -> NifResult<Term<'a>> {
    if a.is_empty() || b.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }
    
    if a.len() != b.len() {
        return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
    }
    
    // XOR and popcount each byte, sum the results
    let distance: u32 = a.as_slice().iter()
        .zip(b.as_slice().iter())
        .map(|(&x, &y)| (x ^ y).count_ones())
        .sum();
    
    Ok((atoms::ok(), distance).encode(env))
}

/// Batch Hamming distance computation.
/// 
/// Returns {:ok, [distances]} for all corpus vectors.
#[rustler::nif(schedule = "DirtyCpu")]
fn batch_hamming_distance<'a>(
    env: Env<'a>,
    query: Binary<'a>,
    corpus: Term<'a>,
) -> NifResult<Term<'a>> {
    if query.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }
    
    let corpus_binaries: Vec<Binary> = rustler::Decoder::decode(corpus)?;
    
    if corpus_binaries.is_empty() {
        return Ok((atoms::error(), atoms::empty_corpus()).encode(env));
    }
    
    let dim = query.len();
    for bin in &corpus_binaries {
        if bin.len() != dim {
            return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
        }
    }
    
    let query_slice = query.as_slice();
    
    // Convert binaries to owned byte vectors for parallel processing
    // (Binary<'a> doesn't implement Send+Sync needed by rayon)
    let corpus_bytes: Vec<Vec<u8>> = corpus_binaries
        .iter()
        .map(|bin| bin.as_slice().to_vec())
        .collect();
    
    // Parallel computation
    let results: Vec<u32> = corpus_bytes
        .par_iter()
        .map(|bin| {
            bin.iter()
                .zip(query_slice.iter())
                .map(|(&x, &y)| (x ^ y).count_ones())
                .sum()
        })
        .collect();
    
    Ok((atoms::ok(), results).encode(env))
}

/// Find top-k vectors by Hamming distance (lowest distance = most similar).
/// 
/// Returns {:ok, [{index, distance}, ...]} sorted by distance ascending.
/// This is used for fast pre-filtering before more expensive similarity calculations.
#[rustler::nif(schedule = "DirtyCpu")]
fn top_k_hamming<'a>(
    env: Env<'a>,
    query: Binary<'a>,
    corpus: Term<'a>,
    k: usize,
) -> NifResult<Term<'a>> {
    if query.is_empty() {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }
    
    let corpus_binaries: Vec<Binary> = rustler::Decoder::decode(corpus)?;
    
    if corpus_binaries.is_empty() {
        return Ok((atoms::error(), atoms::empty_corpus()).encode(env));
    }
    
    let dim = query.len();
    for bin in &corpus_binaries {
        if bin.len() != dim {
            return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
        }
    }
    
    let query_slice = query.as_slice();
    
    // Convert binaries to owned byte vectors for parallel processing
    let corpus_bytes: Vec<Vec<u8>> = corpus_binaries
        .iter()
        .map(|bin| bin.as_slice().to_vec())
        .collect();
    
    // Parallel computation of distances with indices
    let mut indexed_results: Vec<(usize, u32)> = corpus_bytes
        .par_iter()
        .enumerate()
        .map(|(idx, bin)| {
            let dist: u32 = bin.iter()
                .zip(query_slice.iter())
                .map(|(&x, &y)| (x ^ y).count_ones())
                .sum();
            (idx, dist)
        })
        .collect();
    
    // Partial sort for top-k (lowest distance = most similar)
    let k = k.min(indexed_results.len());
    indexed_results.select_nth_unstable_by_key(k.saturating_sub(1), |(_, d)| *d);
    indexed_results.truncate(k);
    indexed_results.sort_by_key(|(_, d)| *d);
    
    Ok((atoms::ok(), indexed_results).encode(env))
}

/// Convert Hamming distance to approximate cosine similarity.
/// 
/// Uses the relationship: similarity ≈ 1 - (2 * hamming_distance / total_bits)
/// This is a rough approximation but useful for threshold comparisons.
/// 
/// Returns {:ok, similarity} where similarity is in [0, 1] range.
#[rustler::nif]
fn hamming_to_similarity<'a>(
    env: Env<'a>,
    distance: u32,
    total_bits: u32,
) -> NifResult<Term<'a>> {
    if total_bits == 0 {
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
    }
    
    // Normalize: 0 distance = 1.0 similarity, max distance = 0.0 similarity
    // Using linear mapping: sim = 1 - (distance / total_bits)
    let similarity = 1.0 - (distance as f32 / total_bits as f32);
    
    Ok((atoms::ok(), similarity).encode(env))
}

// =============================================================================
// Internal SIMD Functions
// =============================================================================

/// SIMD-accelerated cosine similarity computation.
/// 
/// Processes 8 f32 values per iteration using wide SIMD operations.
/// Falls back to scalar computation for remainder elements.
#[inline(always)]
fn simd_cosine(a: &[f32], b: &[f32]) -> f32 {
    let len = a.len();
    
    let mut sum_ab = 0.0f32;
    let mut sum_a2 = 0.0f32;
    let mut sum_b2 = 0.0f32;

    // Process 8 elements at a time using wide crate
    let chunks = len / 8;
    let remainder = len % 8;

    for i in 0..chunks {
        let offset = i * 8;
        
        // Load 8 f32 values
        let va = wide::f32x8::from([
            a[offset],
            a[offset + 1],
            a[offset + 2],
            a[offset + 3],
            a[offset + 4],
            a[offset + 5],
            a[offset + 6],
            a[offset + 7],
        ]);
        
        let vb = wide::f32x8::from([
            b[offset],
            b[offset + 1],
            b[offset + 2],
            b[offset + 3],
            b[offset + 4],
            b[offset + 5],
            b[offset + 6],
            b[offset + 7],
        ]);

        // Compute products
        let ab = va * vb;
        let a2 = va * va;
        let b2 = vb * vb;

        // Horizontal sum
        sum_ab += ab.reduce_add();
        sum_a2 += a2.reduce_add();
        sum_b2 += b2.reduce_add();
    }

    // Scalar cleanup for remaining elements
    let start = chunks * 8;
    for i in start..(start + remainder) {
        sum_ab += a[i] * b[i];
        sum_a2 += a[i] * a[i];
        sum_b2 += b[i] * b[i];
    }

    // Compute final cosine similarity
    let denominator = (sum_a2.sqrt()) * (sum_b2.sqrt());
    if denominator == 0.0 {
        0.0
    } else {
        sum_ab / denominator
    }
}

/// Cosine similarity on int8 vectors (stored as u8, interpreted as i8).
/// 
/// Uses integer arithmetic for speed, normalizes at the end.
#[inline(always)]
fn int8_cosine(a: &[u8], b: &[u8]) -> f32 {
    let len = a.len();
    
    // Use i64 to prevent overflow in accumulation
    let mut dot: i64 = 0;
    let mut norm_a: i64 = 0;
    let mut norm_b: i64 = 0;

    // Process elements - interpret u8 as signed i8
    for i in 0..len {
        let ai = a[i] as i8 as i64;
        let bi = b[i] as i8 as i64;
        
        dot += ai * bi;
        norm_a += ai * ai;
        norm_b += bi * bi;
    }

    // Compute similarity with floating point for final normalization
    let denom = ((norm_a as f64).sqrt() * (norm_b as f64).sqrt()) as f32;
    if denom == 0.0 {
        0.0
    } else {
        (dot as f32) / denom
    }
}

// =============================================================================
// NIF Registration - includes all SPEC-031 and SPEC-033 functions
// =============================================================================

#[cfg(feature = "hnsw")]
fn on_load(env: Env, _info: Term) -> bool {
    // Register the HnswIndex resource type
    rustler::resource!(HnswIndex, env);
    true
}

#[cfg(not(feature = "hnsw"))]
fn on_load(_env: Env, _info: Term) -> bool {
    // No resources to register without HNSW feature
    true
}

// Rustler init macro - conditionally includes HNSW NIFs based on feature flag
#[cfg(feature = "hnsw")]
rustler::init!(
    "Elixir.Mimo.Vector.Math",
    [
        // Float32 operations (existing)
        cosine_similarity,
        batch_similarity,
        top_k_similar,
        normalize_vector,
        // Int8 quantization operations (SPEC-031 Phase 2)
        quantize_int8,
        dequantize_int8,
        cosine_similarity_int8,
        batch_similarity_int8,
        top_k_similar_int8,
        // Binary quantization operations (SPEC-033 Phase 3a)
        to_binary,
        int8_to_binary,
        hamming_distance,
        batch_hamming_distance,
        top_k_hamming,
        hamming_to_similarity,
        // HNSW index operations (SPEC-033 Phase 3b) - requires hnsw feature
        hnsw::hnsw_new,
        hnsw::hnsw_reserve,
        hnsw::hnsw_add,
        hnsw::hnsw_add_batch,
        hnsw::hnsw_search,
        hnsw::hnsw_size,
        hnsw::hnsw_capacity,
        hnsw::hnsw_dimensions,
        hnsw::hnsw_contains,
        hnsw::hnsw_remove,
        hnsw::hnsw_save,
        hnsw::hnsw_load,
        hnsw::hnsw_view,
        hnsw::hnsw_stats,
    ],
    load = on_load
);

#[cfg(not(feature = "hnsw"))]
rustler::init!(
    "Elixir.Mimo.Vector.Math",
    [
        // Float32 operations (existing)
        cosine_similarity,
        batch_similarity,
        top_k_similar,
        normalize_vector,
        // Int8 quantization operations (SPEC-031 Phase 2)
        quantize_int8,
        dequantize_int8,
        cosine_similarity_int8,
        batch_similarity_int8,
        top_k_similar_int8,
        // Binary quantization operations (SPEC-033 Phase 3a)
        to_binary,
        int8_to_binary,
        hamming_distance,
        batch_hamming_distance,
        top_k_hamming,
        hamming_to_similarity,
        // Note: HNSW NIFs require the "hnsw" feature flag (needs rustc 1.82+)
    ],
    load = on_load
);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simd_cosine_identical() {
        let a = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0];
        let b = a.clone();
        let result = simd_cosine(&a, &b);
        assert!((result - 1.0).abs() < 1e-6);
    }

    #[test]
    fn test_simd_cosine_orthogonal() {
        let a = vec![1.0, 0.0, 0.0, 0.0];
        let b = vec![0.0, 1.0, 0.0, 0.0];
        let result = simd_cosine(&a, &b);
        assert!(result.abs() < 1e-6);
    }

    #[test]
    fn test_simd_cosine_opposite() {
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![-1.0, -2.0, -3.0];
        let result = simd_cosine(&a, &b);
        assert!((result + 1.0).abs() < 1e-6);
    }

    #[test]
    fn test_simd_cosine_long_vector() {
        // Test with 1536 dimensions (OpenAI embedding size)
        let a: Vec<f32> = (0..1536).map(|i| i as f32 / 1536.0).collect();
        let b: Vec<f32> = (0..1536).map(|i| (1536 - i) as f32 / 1536.0).collect();
        let result = simd_cosine(&a, &b);
        assert!(result >= -1.0 && result <= 1.0);
    }

    #[test]
    fn test_int8_cosine_identical() {
        // Vectors that when interpreted as i8 are identical
        let a: Vec<u8> = vec![10, 20, 30, 40, 128, 200, 255, 0];
        let b = a.clone();
        let result = int8_cosine(&a, &b);
        assert!((result - 1.0).abs() < 1e-6);
    }

    #[test]
    fn test_int8_cosine_orthogonal() {
        // Create vectors that are roughly orthogonal in signed space
        let a: Vec<u8> = vec![127, 0, 0, 0]; // [127, 0, 0, 0] as i8
        let b: Vec<u8> = vec![0, 127, 0, 0]; // [0, 127, 0, 0] as i8
        let result = int8_cosine(&a, &b);
        assert!(result.abs() < 1e-6);
    }

    // SPEC-033 Phase 3a: Binary quantization tests
    
    #[test]
    fn test_binary_conversion_all_positive() {
        // All positive values should give all 1s
        let input = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0];
        let byte_count = (input.len() + 7) / 8;
        let mut binary_vec: Vec<u8> = vec![0u8; byte_count];
        
        for (i, &v) in input.iter().enumerate() {
            if v >= 0.0 {
                let byte_idx = i / 8;
                let bit_idx = i % 8;
                binary_vec[byte_idx] |= 1 << bit_idx;
            }
        }
        
        // All 8 bits should be set: 0b11111111 = 255
        assert_eq!(binary_vec[0], 255);
    }
    
    #[test]
    fn test_binary_conversion_all_negative() {
        // All negative values should give all 0s
        let input = vec![-1.0, -2.0, -3.0, -4.0, -5.0, -6.0, -7.0, -8.0];
        let byte_count = (input.len() + 7) / 8;
        let mut binary_vec: Vec<u8> = vec![0u8; byte_count];
        
        for (i, &v) in input.iter().enumerate() {
            if v >= 0.0 {
                let byte_idx = i / 8;
                let bit_idx = i % 8;
                binary_vec[byte_idx] |= 1 << bit_idx;
            }
        }
        
        assert_eq!(binary_vec[0], 0);
    }
    
    #[test]
    fn test_binary_conversion_mixed() {
        // Mix of positive and negative
        let input = vec![1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0];
        let byte_count = (input.len() + 7) / 8;
        let mut binary_vec: Vec<u8> = vec![0u8; byte_count];
        
        for (i, &v) in input.iter().enumerate() {
            if v >= 0.0 {
                let byte_idx = i / 8;
                let bit_idx = i % 8;
                binary_vec[byte_idx] |= 1 << bit_idx;
            }
        }
        
        // Bits at positions 0, 2, 4, 6 should be set: 0b01010101 = 85
        assert_eq!(binary_vec[0], 85);
    }
    
    #[test]
    fn test_hamming_distance_identical() {
        let a: Vec<u8> = vec![0b11110000, 0b10101010];
        let b: Vec<u8> = vec![0b11110000, 0b10101010];
        
        let distance: u32 = a.iter()
            .zip(b.iter())
            .map(|(&x, &y)| (x ^ y).count_ones())
            .sum();
        
        assert_eq!(distance, 0);
    }
    
    #[test]
    fn test_hamming_distance_opposite() {
        let a: Vec<u8> = vec![0b11111111];
        let b: Vec<u8> = vec![0b00000000];
        
        let distance: u32 = a.iter()
            .zip(b.iter())
            .map(|(&x, &y)| (x ^ y).count_ones())
            .sum();
        
        assert_eq!(distance, 8);
    }
    
    #[test]
    fn test_hamming_distance_partial() {
        let a: Vec<u8> = vec![0b11110000];
        let b: Vec<u8> = vec![0b11000000];
        
        let distance: u32 = a.iter()
            .zip(b.iter())
            .map(|(&x, &y)| (x ^ y).count_ones())
            .sum();
        
        // 0b11110000 XOR 0b11000000 = 0b00110000, which has 2 bits set
        assert_eq!(distance, 2);
    }
}
