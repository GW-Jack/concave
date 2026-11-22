use std::path::Path;

use oxc_allocator::Allocator;
use oxc_codegen::Codegen;
use oxc_parser::Parser;
use oxc_semantic::SemanticBuilder;
use oxc_span::SourceType;
use oxc_transformer::{TransformOptions, Transformer};

/// Strip TypeScript types on the fly in Rust using `oxc`, returning browser-native ESM JavaScript.
pub fn transpile_ts(filename: &str, source: &str) -> Result<String, String> {
    let allocator = Allocator::default();
    let source_type = SourceType::from_path(filename).unwrap_or_else(|_| SourceType::ts());

    let parsed = Parser::new(&allocator, source, source_type).parse();
    if !parsed.errors.is_empty() {
        let msgs: Vec<String> = parsed.errors.iter().map(|e| e.to_string()).collect();
        return Err(format!("TS parse error in `{filename}`: {}", msgs.join("; ")));
    }

    let mut program = parsed.program;
    let semantic = SemanticBuilder::new().build(&program);
    let scoping = semantic.semantic.into_scoping();

    let options = TransformOptions::default();
    let result = Transformer::new(&allocator, Path::new(filename), &options)
        .build_with_scoping(scoping, &mut program);

    if !result.errors.is_empty() {
        let msgs: Vec<String> = result.errors.iter().map(|e| e.to_string()).collect();
        return Err(format!(
            "TS transform error in `{filename}`: {}",
            msgs.join("; ")
        ));
    }

    let js = Codegen::new().build(&program).code;
    Ok(js)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_typescript_types_to_browser_esm() {
        let ts = r#"
            export interface Msg { id: string; body: string; }
            export const greet = (m: Msg): string => `hi ${m.body}`;
        "#;
        let js = transpile_ts("example.ts", ts).unwrap();
        assert!(!js.contains("interface Msg"));
        assert!(js.contains("export const greet"));
        assert!(js.contains("hi ${m.body}"));
    }
}
