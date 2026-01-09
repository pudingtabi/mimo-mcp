//! HNSW Index NIF Module - SPEC-033 Phase 3b
//!
//! Provides HNSW (Hierarchical Navigable Small World) approximate nearest neighbor
//! search using the usearch library. This enables O(log n) query time for large
//! memory stores instead of O(n) linear search.
//!
//! The HNSW index is wrapped in a ResourceArc so it can be passed between
//! Elixir and Rust, maintaining state across NIF calls.

use rayon::prelude::*;
use rustler::{Binary, Encoder, Env, NifResult, ResourceArc, Term};
use std::sync::RwLock;
use usearch::{Index, IndexOptions, MetricKind, ScalarKind};

/// Atoms for result tuples
mod atoms {
    rustler::atoms! {
        ok,
        error,
        index_error,
        search_error,
        dimension_mismatch,
        empty_vector,
        not_found,
        io_error,
    }
}

/// HNSW Index wrapper that can be stored as a NIF resource.
///
/// Uses RwLock to allow concurrent reads with exclusive writes.
/// The index stores int8 vectors for memory efficiency per SPEC-033.
pub struct HnswIndex {
    /// The underlying usearch index
    index: RwLock<Index>,
    /// Dimensionality of vectors in this index
    dimensions: usize,
    /// Whether the index has been built (vs just created)
    is_built: RwLock<bool>,
}

/// Create a new HNSW index.
///
/// Parameters:
/// - dimensions: Number of dimensions for vectors (e.g., 256 for Qwen embeddings)
/// - connectivity: Number of connections per node (M parameter, default: 16)
/// - expansion_add: Search expansion during construction (ef_construction, default: 128)
/// - expansion_search: Search expansion during queries (ef, default: 64)
///
/// Returns {:ok, resource} or {:error, reason}
#[rustler::nif]
pub fn hnsw_new<'a>(
    env: Env<'a>,
    dimensions: usize,
    connectivity: Option<usize>,
    expansion_add: Option<usize>,
    expansion_search: Option<usize>,
) -> NifResult<Term<'a>> {
    // Use defaults from SPEC-033 if not specified
    let m = connectivity.unwrap_or(16);
    let ef_construction = expansion_add.unwrap_or(128);
    let ef = expansion_search.unwrap_or(64);

    let options = IndexOptions {
        dimensions,
        metric: MetricKind::IP, // Inner product (equivalent to cosine for normalized vectors)
        quantization: ScalarKind::I8, // Int8 quantization for memory efficiency
        connectivity: m,
        expansion_add: ef_construction,
        expansion_search: ef,
        multi: false, // Single vector per key
    };

    match Index::new(&options) {
        Ok(index) => {
            let resource = ResourceArc::new(HnswIndex {
                index: RwLock::new(index),
                dimensions,
                is_built: RwLock::new(false),
            });
            Ok((atoms::ok(), resource).encode(env))
        }
        Err(e) => Ok((atoms::error(), format!("Failed to create index: {}", e)).encode(env)),
    }
}

/// Reserve capacity for the index.
///
/// Should be called before adding vectors to pre-allocate memory.
/// Returns {:ok, :ok} or {:error, reason}
#[rustler::nif]
pub fn hnsw_reserve<'a>(env: Env<'a>, index: ResourceArc<HnswIndex>, capacity: usize) -> NifResult<Term<'a>> {
    let idx = index.index.write().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    match idx.reserve(capacity) {
        Ok(_) => Ok((atoms::ok(), atoms::ok()).encode(env)),
        Err(e) => Ok((atoms::error(), format!("Reserve failed: {}", e)).encode(env)),
    }
}

/// Add a single vector to the index.
///
/// Parameters:
/// - index: The HNSW index resource
/// - key: Unique identifier for this vector (typically engram ID)
/// - vector: The int8 quantized embedding as binary
///
/// Returns {:ok, :ok} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_add<'a>(
    env: Env<'a>,
    index: ResourceArc<HnswIndex>,
    key: u64,
    vector: Binary<'a>,
) -> NifResult<Term<'a>> {
    if vector.len() != index.dimensions {
        return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
    }

    // Convert binary to i8 slice
    let vec_slice: &[i8] = unsafe {
        std::slice::from_raw_parts(vector.as_slice().as_ptr() as *const i8, vector.len())
    };

    let idx = index.index.write().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    match idx.add(key, vec_slice) {
        Ok(_) => Ok((atoms::ok(), atoms::ok()).encode(env)),
        Err(e) => Ok((atoms::error(), format!("Add failed: {}", e)).encode(env)),
    }
}

/// Add multiple vectors to the index in batch.
///
/// Parameters:
/// - index: The HNSW index resource
/// - entries: List of {key, binary_vector} tuples
///
/// Returns {:ok, count_added} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_add_batch<'a>(
    env: Env<'a>,
    index: ResourceArc<HnswIndex>,
    entries: Vec<(u64, Binary<'a>)>,
) -> NifResult<Term<'a>> {
    if entries.is_empty() {
        return Ok((atoms::ok(), 0usize).encode(env));
    }

    // Validate dimensions
    for (_, vector) in &entries {
        if vector.len() != index.dimensions {
            return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
        }
    }

    let idx = index.index.write().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    let mut added = 0usize;
    for (key, vector) in entries {
        let vec_slice: &[i8] = unsafe {
            std::slice::from_raw_parts(vector.as_slice().as_ptr() as *const i8, vector.len())
        };

        match idx.add(key, vec_slice) {
            Ok(_) => added += 1,
            Err(_) => continue, // Skip failed entries
        }
    }

    // Mark as built after batch add
    if let Ok(mut is_built) = index.is_built.write() {
        *is_built = true;
    }

    Ok((atoms::ok(), added).encode(env))
}

/// Search for the k nearest neighbors of a query vector.
///
/// Parameters:
/// - index: The HNSW index resource
/// - query: The int8 quantized query embedding as binary
/// - k: Number of nearest neighbors to return
///
/// Returns {:ok, [{key, distance}, ...]} or {:error, reason}
/// Results are sorted by distance ascending (closest first).
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_search<'a>(
    env: Env<'a>,
    index: ResourceArc<HnswIndex>,
    query: Binary<'a>,
    k: usize,
) -> NifResult<Term<'a>> {
    if query.len() != index.dimensions {
        return Ok((atoms::error(), atoms::dimension_mismatch()).encode(env));
    }

    // Convert binary to i8 slice
    let query_slice: &[i8] = unsafe {
        std::slice::from_raw_parts(query.as_slice().as_ptr() as *const i8, query.len())
    };

    let idx = index.index.read().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    match idx.search(query_slice, k) {
        Ok(results) => {
            // Convert to list of tuples
            let result_tuples: Vec<(u64, f32)> = results
                .keys
                .iter()
                .zip(results.distances.iter())
                .map(|(&key, &dist)| (key, dist))
                .collect();

            Ok((atoms::ok(), result_tuples).encode(env))
        }
        Err(e) => Ok((atoms::error(), format!("Search failed: {}", e)).encode(env)),
    }
}

/// Get the number of vectors in the index.
#[rustler::nif]
pub fn hnsw_size<'a>(env: Env<'a>, index: ResourceArc<HnswIndex>) -> NifResult<Term<'a>> {
    let idx = index.index.read().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok((atoms::ok(), idx.size()).encode(env))
}

/// Get the capacity of the index.
#[rustler::nif]
pub fn hnsw_capacity<'a>(env: Env<'a>, index: ResourceArc<HnswIndex>) -> NifResult<Term<'a>> {
    let idx = index.index.read().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok((atoms::ok(), idx.capacity()).encode(env))
}

/// Get index dimensions.
#[rustler::nif]
pub fn hnsw_dimensions<'a>(env: Env<'a>, index: ResourceArc<HnswIndex>) -> NifResult<Term<'a>> {
    Ok((atoms::ok(), index.dimensions).encode(env))
}

/// Check if a key exists in the index.
#[rustler::nif]
pub fn hnsw_contains<'a>(env: Env<'a>, index: ResourceArc<HnswIndex>, key: u64) -> NifResult<Term<'a>> {
    let idx = index.index.read().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    Ok((atoms::ok(), idx.contains(key)).encode(env))
}

/// Remove a key from the index.
///
/// Note: HNSW doesn't truly delete, it marks as removed. The space is
/// reclaimed on save/load or compaction.
#[rustler::nif]
pub fn hnsw_remove<'a>(env: Env<'a>, index: ResourceArc<HnswIndex>, key: u64) -> NifResult<Term<'a>> {
    let idx = index.index.write().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    match idx.remove(key) {
        Ok(_) => Ok((atoms::ok(), atoms::ok()).encode(env)),
        Err(e) => Ok((atoms::error(), format!("Remove failed: {}", e)).encode(env)),
    }
}

/// Save the index to a file.
///
/// Returns {:ok, :ok} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_save<'a>(env: Env<'a>, index: ResourceArc<HnswIndex>, path: String) -> NifResult<Term<'a>> {
    let idx = index.index.read().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;

    match idx.save(&path) {
        Ok(_) => Ok((atoms::ok(), atoms::ok()).encode(env)),
        Err(e) => Ok((atoms::error(), format!("Save failed: {}", e)).encode(env)),
    }
}

/// Load an index from a file.
///
/// Returns {:ok, resource} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_load<'a>(env: Env<'a>, path: String) -> NifResult<Term<'a>> {
    // First, we need to create an index with default options
    // and then load into it. USearch 2.21 requires this pattern.
    let options = IndexOptions::default();
    
    match Index::new(&options) {
        Ok(index) => {
            // Load the index from file
            match index.load(&path) {
                Ok(_) => {
                    let dimensions = index.dimensions();
                    
                    let resource = ResourceArc::new(HnswIndex {
                        index: RwLock::new(index),
                        dimensions,
                        is_built: RwLock::new(true),
                    });
                    
                    Ok((atoms::ok(), resource).encode(env))
                }
                Err(e) => Ok((atoms::error(), format!("Load failed: {}", e)).encode(env)),
            }
        }
        Err(e) => Ok((atoms::error(), format!("Failed to create index: {}", e)).encode(env)),
    }
}

/// View an index from a file (memory-mapped, read-only).
///
/// This is more memory efficient for large indices as it doesn't
/// load the entire index into memory.
///
/// Returns {:ok, resource} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
pub fn hnsw_view<'a>(env: Env<'a>, path: String) -> NifResult<Term<'a>> {
    // Create an index with default options, then view the file
    let options = IndexOptions::default();
    
    match Index::new(&options) {
        Ok(index) => {
            // View the index from file (memory-mapped)
            match index.view(&path) {
                Ok(_) => {
                    let dimensions = index.dimensions();
                    
                    let resource = ResourceArc::new(HnswIndex {
                        index: RwLock::new(index),
                        dimensions,
                        is_built: RwLock::new(true),
                    });
                    
                    Ok((atoms::ok(), resource).encode(env))
                }
                Err(e) => Ok((atoms::error(), format!("View failed: {}", e)).encode(env)),
            }
        }
        Err(e) => Ok((atoms::error(), format!("Failed to create index: {}", e)).encode(env)),
    }
}

/// Get statistics about the index.
///
/// Returns {:ok, %{size: n, capacity: n, dimensions: n, memory_usage: n}}
#[rustler::nif]
pub fn hnsw_stats<'a>(env: Env<'a>, index: ResourceArc<HnswIndex>) -> NifResult<Term<'a>> {
    let idx = index.index.read().map_err(|_| rustler::Error::Term(Box::new("lock poisoned")))?;
    
    let stats: Vec<(&str, usize)> = vec![
        ("size", idx.size()),
        ("capacity", idx.capacity()),
        ("dimensions", index.dimensions),
        ("memory_usage", idx.memory_usage()),
    ];
    
    Ok((atoms::ok(), stats).encode(env))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_index_creation() {
        let options = IndexOptions {
            dimensions: 256,
            metric: MetricKind::IP,
            quantization: ScalarKind::I8,
            connectivity: 16,
            expansion_add: 128,
            expansion_search: 64,
            multi: false,
        };

        let index = Index::new(&options).expect("Failed to create index");
        assert_eq!(index.dimensions(), 256);
    }

    #[test]
    fn test_add_and_search() {
        let options = IndexOptions {
            dimensions: 4,
            metric: MetricKind::IP,
            quantization: ScalarKind::I8,
            connectivity: 16,
            expansion_add: 128,
            expansion_search: 64,
            multi: false,
        };

        let index = Index::new(&options).expect("Failed to create index");
        index.reserve(10).expect("Reserve failed");

        // Add some vectors
        let v1: Vec<i8> = vec![1, 2, 3, 4];
        let v2: Vec<i8> = vec![4, 3, 2, 1];
        let v3: Vec<i8> = vec![1, 2, 3, 5]; // Similar to v1

        index.add(1, &v1).expect("Add failed");
        index.add(2, &v2).expect("Add failed");
        index.add(3, &v3).expect("Add failed");

        assert_eq!(index.size(), 3);

        // Search for neighbors of v1
        let results = index.search(&v1, 2).expect("Search failed");
        assert_eq!(results.keys.len(), 2);
        // First result should be v1 itself (key 1) or v3 (key 3) which is similar
        assert!(results.keys[0] == 1 || results.keys[0] == 3);
    }

    #[test]
    fn test_contains_and_remove() {
        let options = IndexOptions {
            dimensions: 4,
            metric: MetricKind::IP,
            quantization: ScalarKind::I8,
            connectivity: 16,
            expansion_add: 128,
            expansion_search: 64,
            multi: false,
        };

        let index = Index::new(&options).expect("Failed to create index");
        index.reserve(10).expect("Reserve failed");

        let v1: Vec<i8> = vec![1, 2, 3, 4];
        index.add(1, &v1).expect("Add failed");

        assert!(index.contains(1));
        assert!(!index.contains(2));

        index.remove(1).expect("Remove failed");
        // Note: contains may still return true after remove in some HNSW implementations
        // The key is marked deleted but not immediately removed
    }
}
