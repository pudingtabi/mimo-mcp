//! Tree-Sitter NIF - AST parsing for Mimo's Living Codebase
//!
//! Provides fast incremental parsing, symbol extraction, and query capabilities
//! for multiple programming languages using Tree-Sitter.

use rustler::{Atom, Encoder, Env, Error, NifResult, ResourceArc, Term};
use std::sync::Mutex;
use streaming_iterator::StreamingIterator;
use tree_sitter::{Language, Node, Parser, Query, QueryCursor, Tree};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unknown_language,
        parse_error,
        query_error,
        invalid_tree,
        // Symbol types
        function,
        method,
        module,
        class,
        variable,
        constant,
        import,
        alias,
        // Languages
        elixir,
        python,
        javascript,
        typescript,
    }
}

/// Wrapper for Tree-Sitter Tree to be used as a NIF resource
pub struct TreeResource {
    tree: Mutex<Option<Tree>>,
    source: Mutex<String>,
    language: String,
}

// Note: Resource registration is handled by rustler::resource!() macro in the load function below

/// Initialize the NIF module
#[rustler::nif]
fn init_resources() -> Atom {
    atoms::ok()
}

/// Get the language grammar for a given language name
fn get_language(lang: &str) -> Option<Language> {
    match lang {
        "elixir" => Some(tree_sitter_elixir::LANGUAGE.into()),
        "python" => Some(tree_sitter_python::LANGUAGE.into()),
        "javascript" => Some(tree_sitter_javascript::LANGUAGE.into()),
        "typescript" => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),
        "tsx" => Some(tree_sitter_typescript::LANGUAGE_TSX.into()),
        _ => None,
    }
}

/// Parse source code and return a tree handle
///
/// Returns {:ok, tree_handle} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
fn parse<'a>(env: Env<'a>, source: String, language: String) -> NifResult<Term<'a>> {
    let lang = match get_language(&language) {
        Some(l) => l,
        None => return Ok((atoms::error(), atoms::unknown_language()).encode(env)),
    };

    let mut parser = Parser::new();
    parser.set_language(&lang).map_err(|_| Error::Term(Box::new("Failed to set language")))?;

    match parser.parse(&source, None) {
        Some(tree) => {
            let resource = ResourceArc::new(TreeResource {
                tree: Mutex::new(Some(tree)),
                source: Mutex::new(source),
                language,
            });
            Ok((atoms::ok(), resource).encode(env))
        }
        None => Ok((atoms::error(), atoms::parse_error()).encode(env)),
    }
}

/// Parse source code incrementally using the previous tree
///
/// Returns {:ok, tree_handle} or {:error, reason}
#[rustler::nif(schedule = "DirtyCpu")]
fn parse_incremental<'a>(
    env: Env<'a>,
    source: String,
    old_tree: ResourceArc<TreeResource>,
    _edits: Vec<(usize, usize, usize)>, // (start_byte, old_end_byte, new_end_byte)
) -> NifResult<Term<'a>> {
    let language = {
        let _guard = old_tree.tree.lock().unwrap();
        old_tree.language.clone()
    };

    let lang = match get_language(&language) {
        Some(l) => l,
        None => return Ok((atoms::error(), atoms::unknown_language()).encode(env)),
    };

    let mut parser = Parser::new();
    parser.set_language(&lang).map_err(|_| Error::Term(Box::new("Failed to set language")))?;

    // Get the old tree for incremental parsing
    let old_ts_tree = {
        let guard = old_tree.tree.lock().unwrap();
        guard.clone()
    };

    match parser.parse(&source, old_ts_tree.as_ref()) {
        Some(tree) => {
            let resource = ResourceArc::new(TreeResource {
                tree: Mutex::new(Some(tree)),
                source: Mutex::new(source),
                language,
            });
            Ok((atoms::ok(), resource).encode(env))
        }
        None => Ok((atoms::error(), atoms::parse_error()).encode(env)),
    }
}

/// Get the root node S-expression representation (for debugging)
#[rustler::nif]
fn get_sexp<'a>(env: Env<'a>, tree_resource: ResourceArc<TreeResource>) -> NifResult<Term<'a>> {
    let guard = tree_resource.tree.lock().unwrap();
    match &*guard {
        Some(tree) => {
            let sexp = tree.root_node().to_sexp();
            Ok((atoms::ok(), sexp).encode(env))
        }
        None => Ok((atoms::error(), atoms::invalid_tree()).encode(env)),
    }
}

/// Symbol information returned from extraction
/// NOTE: Reserved for future structured symbol extraction API
#[allow(dead_code)]
#[derive(Debug, Clone)]
struct Symbol {
    name: String,
    kind: String,
    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,
    doc: Option<String>,
    parent: Option<String>,
}

impl Encoder for Symbol {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        // Build a proper map for Symbol encoding
        let pairs: Vec<(Term<'a>, Term<'a>)> = vec![
            ("name".encode(env), self.name.encode(env)),
            ("kind".encode(env), self.kind.encode(env)),
            ("start_line".encode(env), self.start_line.encode(env)),
            ("start_col".encode(env), self.start_col.encode(env)),
            ("end_line".encode(env), self.end_line.encode(env)),
            ("end_col".encode(env), self.end_col.encode(env)),
            ("doc".encode(env), self.doc.encode(env)),
            ("parent".encode(env), self.parent.encode(env)),
        ];
        Term::map_from_pairs(env, &pairs).unwrap()
    }
}

/// Reference information (calls, imports, etc.)
/// NOTE: Reserved for future structured reference extraction API
#[allow(dead_code)]
#[derive(Debug, Clone)]
struct Reference {
    name: String,
    kind: String, // "call", "import", "alias", "use"
    line: usize,
    col: usize,
    target_module: Option<String>,
}

impl Encoder for Reference {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        // Build a proper map for Reference encoding
        let pairs: Vec<(Term<'a>, Term<'a>)> = vec![
            ("name".encode(env), self.name.encode(env)),
            ("kind".encode(env), self.kind.encode(env)),
            ("line".encode(env), self.line.encode(env)),
            ("col".encode(env), self.col.encode(env)),
            ("target_module".encode(env), self.target_module.encode(env)),
        ];
        Term::map_from_pairs(env, &pairs).unwrap()
    }
}

/// Extract all symbols from the parsed tree
#[rustler::nif(schedule = "DirtyCpu")]
fn get_symbols<'a>(
    env: Env<'a>,
    tree_resource: ResourceArc<TreeResource>,
) -> NifResult<Term<'a>> {
    let guard = tree_resource.tree.lock().unwrap();
    let source_guard = tree_resource.source.lock().unwrap();
    let language = &tree_resource.language;
    
    let tree = match &*guard {
        Some(t) => t,
        None => return Ok((atoms::error(), atoms::invalid_tree()).encode(env)),
    };

    let source = source_guard.as_bytes();
    let symbols = extract_symbols_for_language(tree, source, language);
    
    Ok((atoms::ok(), symbols).encode(env))
}

/// Extract symbols based on language
fn extract_symbols_for_language(tree: &Tree, source: &[u8], language: &str) -> Vec<Vec<(String, String)>> {
    let root = tree.root_node();
    let mut symbols = Vec::new();
    
    match language {
        "elixir" => extract_elixir_symbols(&root, source, &mut symbols, None),
        "python" => extract_python_symbols(&root, source, &mut symbols, None),
        "javascript" | "typescript" | "tsx" => extract_js_symbols(&root, source, &mut symbols, None),
        _ => {}
    }
    
    symbols
}

/// Extract Elixir symbols (defmodule, def, defp, defmacro, etc.)
fn extract_elixir_symbols(
    node: &Node,
    source: &[u8],
    symbols: &mut Vec<Vec<(String, String)>>,
    parent: Option<&str>,
) {
    let kind = node.kind();
    
    match kind {
        "call" => {
            // Check if this is a def/defp/defmodule/defmacro call
            // Try field-based access first, then fallback to child iteration
            let target_text = if let Some(target) = node.child_by_field_name("target") {
                Some(node_text(&target, source))
            } else {
                // Fallback: first child is typically the target identifier
                node.child(0).map(|c| node_text(&c, source))
            };
            
            if let Some(target_text) = target_text {
                match target_text.as_str() {
                    "defmodule" => {
                        // Get module name from arguments
                        let module_name = get_elixir_module_name(node, source);
                        
                        if let Some(ref module_name) = module_name {
                            let pos = node.start_position();
                            let end_pos = node.end_position();
                            symbols.push(vec![
                                ("name".to_string(), module_name.clone()),
                                ("kind".to_string(), "module".to_string()),
                                ("start_line".to_string(), (pos.row + 1).to_string()),
                                ("start_col".to_string(), pos.column.to_string()),
                                ("end_line".to_string(), (end_pos.row + 1).to_string()),
                                ("end_col".to_string(), end_pos.column.to_string()),
                                ("parent".to_string(), parent.unwrap_or("").to_string()),
                            ]);
                        }
                        
                        // Recurse into module body with this module as parent
                        let new_parent = module_name.as_deref().or(parent);
                        for i in 0..node.child_count() {
                            if let Some(child) = node.child(i) {
                                extract_elixir_symbols(&child, source, symbols, new_parent);
                            }
                        }
                        return;
                    }
                    "def" | "defp" | "defmacro" | "defmacrop" => {
                        // Get function name from arguments
                        let func_name = get_elixir_function_name(node, source);
                        
                        if let Some(name) = func_name {
                            let pos = node.start_position();
                            let end_pos = node.end_position();
                            let func_kind = if target_text.contains("macro") { "macro" } else { "function" };
                            let visibility = if target_text.ends_with("p") { "private" } else { "public" };
                            
                            symbols.push(vec![
                                ("name".to_string(), name),
                                ("kind".to_string(), func_kind.to_string()),
                                ("visibility".to_string(), visibility.to_string()),
                                ("start_line".to_string(), (pos.row + 1).to_string()),
                                ("start_col".to_string(), pos.column.to_string()),
                                ("end_line".to_string(), (end_pos.row + 1).to_string()),
                                ("end_col".to_string(), end_pos.column.to_string()),
                                ("parent".to_string(), parent.unwrap_or("").to_string()),
                            ]);
                        }
                    }
                    "import" | "alias" | "use" | "require" => {
                        if let Some(import_name) = get_elixir_import_name(node, source) {
                            let pos = node.start_position();
                            symbols.push(vec![
                                ("name".to_string(), import_name),
                                ("kind".to_string(), target_text.clone()),
                                ("start_line".to_string(), (pos.row + 1).to_string()),
                                ("start_col".to_string(), pos.column.to_string()),
                                ("parent".to_string(), parent.unwrap_or("").to_string()),
                            ]);
                        }
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    
    // Recurse into children
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            extract_elixir_symbols(&child, source, symbols, parent);
        }
    }
}

/// Get module name from defmodule call node
fn get_elixir_module_name(node: &Node, source: &[u8]) -> Option<String> {
    // Try arguments field first
    if let Some(args) = node.child_by_field_name("arguments") {
        for i in 0..args.child_count() {
            if let Some(child) = args.child(i) {
                // Module name is typically an alias (e.g., MyApp.Calculator)
                if child.kind() == "alias" || child.kind() == "identifier" {
                    return Some(node_text(&child, source));
                }
            }
        }
    }
    
    // Fallback: iterate all children looking for alias/identifier after the first one
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            if child.kind() == "alias" || (child.kind() == "identifier" && i > 0) {
                return Some(node_text(&child, source));
            }
            // Check inside arguments node
            if child.kind() == "arguments" {
                for j in 0..child.child_count() {
                    if let Some(arg_child) = child.child(j) {
                        if arg_child.kind() == "alias" || arg_child.kind() == "identifier" {
                            return Some(node_text(&arg_child, source));
                        }
                    }
                }
            }
        }
    }
    None
}

/// Get function name from def/defp call node
fn get_elixir_function_name(node: &Node, source: &[u8]) -> Option<String> {
    // Try arguments field first
    if let Some(args) = node.child_by_field_name("arguments") {
        return extract_elixir_function_name(&args, source);
    }
    
    // Fallback: find arguments node by iterating
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            if child.kind() == "arguments" {
                return extract_elixir_function_name(&child, source);
            }
        }
    }
    None
}

/// Get import/alias/use name from call node
fn get_elixir_import_name(node: &Node, source: &[u8]) -> Option<String> {
    // Try arguments field first
    if let Some(args) = node.child_by_field_name("arguments") {
        for i in 0..args.child_count() {
            if let Some(child) = args.child(i) {
                // Import name is typically an alias
                if child.kind() == "alias" || child.kind() == "identifier" {
                    return Some(node_text(&child, source));
                }
            }
        }
    }
    
    // Fallback: iterate children
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            if child.kind() == "arguments" {
                for j in 0..child.child_count() {
                    if let Some(arg_child) = child.child(j) {
                        if arg_child.kind() == "alias" || arg_child.kind() == "identifier" {
                            return Some(node_text(&arg_child, source));
                        }
                    }
                }
            }
        }
    }
    None
}

/// Extract function name from Elixir def/defp arguments
fn extract_elixir_function_name(args_node: &Node, source: &[u8]) -> Option<String> {
    // The first child of arguments is typically the function head
    for i in 0..args_node.child_count() {
        if let Some(child) = args_node.child(i) {
            let kind = child.kind();
            match kind {
                "identifier" => return Some(node_text(&child, source)),
                "call" => {
                    // Function with parameters: def foo(a, b)
                    // Try field-based access first
                    if let Some(target) = child.child_by_field_name("target") {
                        return Some(node_text(&target, source));
                    }
                    // Fallback: iterate children to find identifier (first child is usually target)
                    for j in 0..child.child_count() {
                        if let Some(sub_child) = child.child(j) {
                            if sub_child.kind() == "identifier" {
                                return Some(node_text(&sub_child, source));
                            }
                        }
                    }
                }
                "binary_operator" => {
                    // Pattern matching in head: def foo(a) when is_integer(a)
                    if let Some(left) = child.child_by_field_name("left") {
                        return extract_elixir_function_name_from_node(&left, source);
                    }
                    // Fallback for binary operator
                    if let Some(first_child) = child.child(0) {
                        return extract_elixir_function_name_from_node(&first_child, source);
                    }
                }
                _ => {}
            }
        }
    }
    None
}

fn extract_elixir_function_name_from_node(node: &Node, source: &[u8]) -> Option<String> {
    match node.kind() {
        "identifier" => Some(node_text(node, source)),
        "call" => {
            if let Some(target) = node.child_by_field_name("target") {
                Some(node_text(&target, source))
            } else {
                None
            }
        }
        _ => None
    }
}

/// Extract Python symbols (def, class, import)
fn extract_python_symbols(
    node: &Node,
    source: &[u8],
    symbols: &mut Vec<Vec<(String, String)>>,
    parent: Option<&str>,
) {
    let kind = node.kind();
    
    match kind {
        "function_definition" | "async_function_definition" => {
            if let Some(name_node) = node.child_by_field_name("name") {
                let name = node_text(&name_node, source);
                let pos = node.start_position();
                let end_pos = node.end_position();
                symbols.push(vec![
                    ("name".to_string(), name),
                    ("kind".to_string(), "function".to_string()),
                    ("start_line".to_string(), (pos.row + 1).to_string()),
                    ("start_col".to_string(), pos.column.to_string()),
                    ("end_line".to_string(), (end_pos.row + 1).to_string()),
                    ("end_col".to_string(), end_pos.column.to_string()),
                    ("parent".to_string(), parent.unwrap_or("").to_string()),
                ]);
            }
        }
        "class_definition" => {
            if let Some(name_node) = node.child_by_field_name("name") {
                let class_name = node_text(&name_node, source);
                let pos = node.start_position();
                let end_pos = node.end_position();
                symbols.push(vec![
                    ("name".to_string(), class_name.clone()),
                    ("kind".to_string(), "class".to_string()),
                    ("start_line".to_string(), (pos.row + 1).to_string()),
                    ("start_col".to_string(), pos.column.to_string()),
                    ("end_line".to_string(), (end_pos.row + 1).to_string()),
                    ("end_col".to_string(), end_pos.column.to_string()),
                    ("parent".to_string(), parent.unwrap_or("").to_string()),
                ]);
                
                // Recurse with class as parent
                for i in 0..node.child_count() {
                    if let Some(child) = node.child(i) {
                        extract_python_symbols(&child, source, symbols, Some(&class_name));
                    }
                }
                return;
            }
        }
        "import_statement" | "import_from_statement" => {
            let pos = node.start_position();
            let import_text = node_text(node, source);
            symbols.push(vec![
                ("name".to_string(), import_text),
                ("kind".to_string(), "import".to_string()),
                ("start_line".to_string(), (pos.row + 1).to_string()),
                ("start_col".to_string(), pos.column.to_string()),
                ("parent".to_string(), parent.unwrap_or("").to_string()),
            ]);
        }
        _ => {}
    }
    
    // Recurse
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            extract_python_symbols(&child, source, symbols, parent);
        }
    }
}

/// Extract JavaScript/TypeScript symbols (function, class, const, import)
fn extract_js_symbols(
    node: &Node,
    source: &[u8],
    symbols: &mut Vec<Vec<(String, String)>>,
    parent: Option<&str>,
) {
    let kind = node.kind();
    
    match kind {
        "function_declaration" | "generator_function_declaration" => {
            if let Some(name_node) = node.child_by_field_name("name") {
                let name = node_text(&name_node, source);
                let pos = node.start_position();
                let end_pos = node.end_position();
                symbols.push(vec![
                    ("name".to_string(), name),
                    ("kind".to_string(), "function".to_string()),
                    ("start_line".to_string(), (pos.row + 1).to_string()),
                    ("start_col".to_string(), pos.column.to_string()),
                    ("end_line".to_string(), (end_pos.row + 1).to_string()),
                    ("end_col".to_string(), end_pos.column.to_string()),
                    ("parent".to_string(), parent.unwrap_or("").to_string()),
                ]);
            }
        }
        "class_declaration" => {
            if let Some(name_node) = node.child_by_field_name("name") {
                let class_name = node_text(&name_node, source);
                let pos = node.start_position();
                let end_pos = node.end_position();
                symbols.push(vec![
                    ("name".to_string(), class_name.clone()),
                    ("kind".to_string(), "class".to_string()),
                    ("start_line".to_string(), (pos.row + 1).to_string()),
                    ("start_col".to_string(), pos.column.to_string()),
                    ("end_line".to_string(), (end_pos.row + 1).to_string()),
                    ("end_col".to_string(), end_pos.column.to_string()),
                    ("parent".to_string(), parent.unwrap_or("").to_string()),
                ]);
                
                // Recurse with class as parent
                for i in 0..node.child_count() {
                    if let Some(child) = node.child(i) {
                        extract_js_symbols(&child, source, symbols, Some(&class_name));
                    }
                }
                return;
            }
        }
        "method_definition" => {
            if let Some(name_node) = node.child_by_field_name("name") {
                let name = node_text(&name_node, source);
                let pos = node.start_position();
                let end_pos = node.end_position();
                symbols.push(vec![
                    ("name".to_string(), name),
                    ("kind".to_string(), "method".to_string()),
                    ("start_line".to_string(), (pos.row + 1).to_string()),
                    ("start_col".to_string(), pos.column.to_string()),
                    ("end_line".to_string(), (end_pos.row + 1).to_string()),
                    ("end_col".to_string(), end_pos.column.to_string()),
                    ("parent".to_string(), parent.unwrap_or("").to_string()),
                ]);
            }
        }
        "lexical_declaration" | "variable_declaration" => {
            // Extract const/let/var declarations
            for i in 0..node.child_count() {
                if let Some(child) = node.child(i) {
                    if child.kind() == "variable_declarator" {
                        if let Some(name_node) = child.child_by_field_name("name") {
                            let name = node_text(&name_node, source);
                            let pos = child.start_position();
                            let decl_kind = if node.kind() == "lexical_declaration" {
                                // Check for const vs let
                                if let Some(first) = node.child(0) {
                                    node_text(&first, source)
                                } else {
                                    "variable".to_string()
                                }
                            } else {
                                "var".to_string()
                            };
                            symbols.push(vec![
                                ("name".to_string(), name),
                                ("kind".to_string(), decl_kind),
                                ("start_line".to_string(), (pos.row + 1).to_string()),
                                ("start_col".to_string(), pos.column.to_string()),
                                ("parent".to_string(), parent.unwrap_or("").to_string()),
                            ]);
                        }
                    }
                }
            }
        }
        "import_statement" => {
            let pos = node.start_position();
            let import_text = node_text(node, source);
            symbols.push(vec![
                ("name".to_string(), import_text),
                ("kind".to_string(), "import".to_string()),
                ("start_line".to_string(), (pos.row + 1).to_string()),
                ("start_col".to_string(), pos.column.to_string()),
                ("parent".to_string(), parent.unwrap_or("").to_string()),
            ]);
        }
        "export_statement" => {
            let _pos = node.start_position();
            // Check for named export
            for i in 0..node.child_count() {
                if let Some(child) = node.child(i) {
                    extract_js_symbols(&child, source, symbols, parent);
                }
            }
        }
        "arrow_function" => {
            // Arrow functions as variable assignments are handled via lexical_declaration
        }
        _ => {}
    }
    
    // Recurse for non-terminal handling
    if !matches!(kind, "class_declaration") {
        for i in 0..node.child_count() {
            if let Some(child) = node.child(i) {
                extract_js_symbols(&child, source, symbols, parent);
            }
        }
    }
}

/// Extract references (function calls, imports)
#[rustler::nif(schedule = "DirtyCpu")]
fn get_references<'a>(
    env: Env<'a>,
    tree_resource: ResourceArc<TreeResource>,
) -> NifResult<Term<'a>> {
    let guard = tree_resource.tree.lock().unwrap();
    let source_guard = tree_resource.source.lock().unwrap();
    let language = &tree_resource.language;
    
    let tree = match &*guard {
        Some(t) => t,
        None => return Ok((atoms::error(), atoms::invalid_tree()).encode(env)),
    };

    let source = source_guard.as_bytes();
    let references = extract_references_for_language(tree, source, language);
    
    Ok((atoms::ok(), references).encode(env))
}

fn extract_references_for_language(tree: &Tree, source: &[u8], language: &str) -> Vec<Vec<(String, String)>> {
    let root = tree.root_node();
    let mut refs = Vec::new();
    
    match language {
        "elixir" => extract_elixir_references(&root, source, &mut refs),
        "python" => extract_python_references(&root, source, &mut refs),
        "javascript" | "typescript" | "tsx" => extract_js_references(&root, source, &mut refs),
        _ => {}
    }
    
    refs
}

fn extract_elixir_references(
    node: &Node,
    source: &[u8],
    refs: &mut Vec<Vec<(String, String)>>,
) {
    let kind = node.kind();
    
    if kind == "call" {
        if let Some(target) = node.child_by_field_name("target") {
            let target_text = node_text(&target, source);
            // Skip definition keywords
            if !["defmodule", "def", "defp", "defmacro", "defmacrop", "import", "alias", "use", "require"].contains(&target_text.as_str()) {
                let pos = node.start_position();
                refs.push(vec![
                    ("name".to_string(), target_text),
                    ("kind".to_string(), "call".to_string()),
                    ("line".to_string(), (pos.row + 1).to_string()),
                    ("col".to_string(), pos.column.to_string()),
                ]);
            }
        }
    }
    
    // Dot calls: Module.function
    if kind == "dot" {
        let pos = node.start_position();
        let dot_text = node_text(node, source);
        refs.push(vec![
            ("name".to_string(), dot_text),
            ("kind".to_string(), "qualified_call".to_string()),
            ("line".to_string(), (pos.row + 1).to_string()),
            ("col".to_string(), pos.column.to_string()),
        ]);
    }
    
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            extract_elixir_references(&child, source, refs);
        }
    }
}

fn extract_python_references(
    node: &Node,
    source: &[u8],
    refs: &mut Vec<Vec<(String, String)>>,
) {
    let kind = node.kind();
    
    if kind == "call" {
        if let Some(func) = node.child_by_field_name("function") {
            let func_text = node_text(&func, source);
            let pos = node.start_position();
            refs.push(vec![
                ("name".to_string(), func_text),
                ("kind".to_string(), "call".to_string()),
                ("line".to_string(), (pos.row + 1).to_string()),
                ("col".to_string(), pos.column.to_string()),
            ]);
        }
    }
    
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            extract_python_references(&child, source, refs);
        }
    }
}

fn extract_js_references(
    node: &Node,
    source: &[u8],
    refs: &mut Vec<Vec<(String, String)>>,
) {
    let kind = node.kind();
    
    if kind == "call_expression" {
        if let Some(func) = node.child_by_field_name("function") {
            let func_text = node_text(&func, source);
            let pos = node.start_position();
            refs.push(vec![
                ("name".to_string(), func_text),
                ("kind".to_string(), "call".to_string()),
                ("line".to_string(), (pos.row + 1).to_string()),
                ("col".to_string(), pos.column.to_string()),
            ]);
        }
    }
    
    if kind == "new_expression" {
        if let Some(constructor) = node.child_by_field_name("constructor") {
            let constructor_text = node_text(&constructor, source);
            let pos = node.start_position();
            refs.push(vec![
                ("name".to_string(), constructor_text),
                ("kind".to_string(), "new".to_string()),
                ("line".to_string(), (pos.row + 1).to_string()),
                ("col".to_string(), pos.column.to_string()),
            ]);
        }
    }
    
    for i in 0..node.child_count() {
        if let Some(child) = node.child(i) {
            extract_js_references(&child, source, refs);
        }
    }
}

/// Execute a Tree-Sitter query pattern on the tree
#[rustler::nif(schedule = "DirtyCpu")]
fn query<'a>(
    env: Env<'a>,
    tree_resource: ResourceArc<TreeResource>,
    query_pattern: String,
) -> NifResult<Term<'a>> {
    let guard = tree_resource.tree.lock().unwrap();
    let source_guard = tree_resource.source.lock().unwrap();
    let language_name = &tree_resource.language;
    
    let tree = match &*guard {
        Some(t) => t,
        None => return Ok((atoms::error(), atoms::invalid_tree()).encode(env)),
    };

    let language = match get_language(language_name) {
        Some(l) => l,
        None => return Ok((atoms::error(), atoms::unknown_language()).encode(env)),
    };

    let query = match Query::new(&language, &query_pattern) {
        Ok(q) => q,
        Err(_e) => return Ok((atoms::error(), atoms::query_error()).encode(env)),
    };

    let mut cursor = QueryCursor::new();
    let source = source_guard.as_bytes();
    let mut matches = cursor.matches(&query, tree.root_node(), source);
    
    // capture_names() returns &[&str] in tree-sitter 0.24+, no need for .as_str()
    let capture_names: &[&str] = query.capture_names();
    
    let mut results: Vec<Vec<(String, String)>> = Vec::new();
    
    // Use StreamingIterator pattern for tree-sitter 0.24+
    while let Some(m) = matches.next() {
        for capture in m.captures {
            let node = capture.node;
            let capture_name = capture_names.get(capture.index as usize).unwrap_or(&"");
            let text = node_text(&node, source);
            let pos = node.start_position();
            let end_pos = node.end_position();
            
            results.push(vec![
                ("capture".to_string(), capture_name.to_string()),
                ("text".to_string(), text),
                ("kind".to_string(), node.kind().to_string()),
                ("start_line".to_string(), (pos.row + 1).to_string()),
                ("start_col".to_string(), pos.column.to_string()),
                ("end_line".to_string(), (end_pos.row + 1).to_string()),
                ("end_col".to_string(), end_pos.column.to_string()),
            ]);
        }
    }
    
    Ok((atoms::ok(), results).encode(env))
}

/// Get text content of a node
fn node_text(node: &Node, source: &[u8]) -> String {
    let start = node.start_byte();
    let end = node.end_byte();
    String::from_utf8_lossy(&source[start..end]).to_string()
}

/// List supported languages
#[rustler::nif]
fn supported_languages<'a>(env: Env<'a>) -> Term<'a> {
    vec!["elixir", "python", "javascript", "typescript", "tsx"].encode(env)
}

/// Get language from file extension
#[rustler::nif]
fn language_for_extension<'a>(env: Env<'a>, ext: String) -> NifResult<Term<'a>> {
    let lang = match ext.as_str() {
        "ex" | "exs" => Some("elixir"),
        "py" | "pyw" => Some("python"),
        "js" | "mjs" | "cjs" => Some("javascript"),
        "ts" => Some("typescript"),
        "tsx" => Some("tsx"),
        "jsx" => Some("javascript"),
        _ => None,
    };
    
    match lang {
        Some(l) => Ok((atoms::ok(), l).encode(env)),
        None => Ok((atoms::error(), atoms::unknown_language()).encode(env)),
    }
}

rustler::init!(
    "Elixir.Mimo.Code.TreeSitter.Native",
    [
        init_resources,
        parse,
        parse_incremental,
        get_sexp,
        get_symbols,
        get_references,
        query,
        supported_languages,
        language_for_extension,
    ],
    load = load
);

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(TreeResource, env);
    true
}
