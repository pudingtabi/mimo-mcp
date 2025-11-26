//! Vector Math NIF - SIMD-accelerated vector operations for Mimo-MCP
//!
//! Provides high-performance cosine similarity and batch vector operations
//! using platform-specific SIMD intrinsics.

use rayon::prelude::*;
use rustler::{Atom, Encoder, Env, Error, NifResult, Term};

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
        return Ok((atoms::error(), atoms::empty_vector()).encode(env));
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

rustler::init!(
    "Elixir.Mimo.Vector.Math",
    [
        cosine_similarity,
        batch_similarity,
        top_k_similar,
        normalize_vector
    ]
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
}
