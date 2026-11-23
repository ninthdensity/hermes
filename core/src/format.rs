use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::model::{Appearance, Block, Document, ListKind};

pub const FORMAT_NAME: &str = "hermes";
// Existing documents keep opening after the app rename.
const LEGACY_FORMAT_NAME: &str = "quire";
pub const CURRENT_VERSION: u64 = 5;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FileEnvelope {
    format: String,
    version: u64,
    #[serde(default)]
    appearance: Appearance,
    #[serde(default)]
    blocks: Vec<Block>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    NotADocument,
    NewerVersion(u64),
    Damaged(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::NotADocument => write!(f, "This file isn't a hermes document."),
            Error::NewerVersion(v) => write!(
                f,
                "This document uses format version {v}, which is newer than this copy of hermes supports. Update hermes to open it."
            ),
            Error::Damaged(detail) => write!(f, "The document is damaged: {detail}"),
        }
    }
}

impl std::error::Error for Error {}

/// Reads file bytes in any supported format version and returns the current-version document.
pub fn decode_file(bytes: &[u8]) -> Result<Document, Error> {
    if let Ok(env) = serde_json::from_slice::<FileEnvelope>(bytes) {
        if !matches!(env.format.as_str(), FORMAT_NAME | LEGACY_FORMAT_NAME) {
            return Err(Error::NotADocument);
        }
        if env.version > CURRENT_VERSION {
            return Err(Error::NewerVersion(env.version));
        }
        if !matches!(env.version, 1 | 2 | 3 | 4 | CURRENT_VERSION) {
            return Err(Error::Damaged(format!("unsupported format version {}", env.version)));
        }
        return normalize(Document {
            appearance: env.appearance,
            blocks: env.blocks,
        });
    }
    decode_file_diagnostic(bytes)
}

/// Slow diagnostic path used only when direct typed decoding fails, ensuring precise user-facing
/// errors for non-documents, newer versions with unknown fields, and damaged files.
fn decode_file_diagnostic(bytes: &[u8]) -> Result<Document, Error> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| Error::NotADocument)?;
    let Value::Object(mut root) = value else {
        return Err(Error::NotADocument);
    };
    let format = root.remove("format").and_then(|v| v.as_str().map(str::to_owned));
    if !matches!(format.as_deref(), Some(FORMAT_NAME | LEGACY_FORMAT_NAME)) {
        return Err(Error::NotADocument);
    }
    let version = root
        .remove("version")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| Error::Damaged("missing format version".into()))?;
    if version > CURRENT_VERSION {
        return Err(Error::NewerVersion(version));
    }
    let root = migrate(root, version)?;
    let doc: Document =
        serde_json::from_value(Value::Object(root)).map_err(|e| Error::Damaged(e.to_string()))?;
    normalize(doc)
}

/// Validates and normalizes a document, then encodes it in the current file format.
pub fn encode_file(doc: Document) -> Result<Vec<u8>, Error> {
    let doc = normalize(doc)?;
    Ok(write_canonical(&doc))
}

fn migrate(root: Map<String, Value>, version: u64) -> Result<Map<String, Value>, Error> {
    match version {
        1 | 2 | 3 | 4 | CURRENT_VERSION => Ok(root),
        v => Err(Error::Damaged(format!("unsupported format version {v}"))),
    }
}

/// One block per line keeps files small and line-diffable.
fn write_canonical(doc: &Document) -> Vec<u8> {
    #[derive(Serialize)]
    struct Header {
        format: &'static str,
        version: u64,
        appearance: Appearance,
    }
    let mut out = Vec::with_capacity(64 + doc.blocks.len() * 96);
    serde_json::to_writer(
        &mut out,
        &Header {
            format: FORMAT_NAME,
            version: CURRENT_VERSION,
            appearance: doc.appearance,
        },
    )
    .expect("header serializes");
    out.pop(); // strip closing '}'
    out.extend_from_slice(b",\"blocks\":[\n");
    for (i, block) in doc.blocks.iter().enumerate() {
        if i > 0 {
            out.extend_from_slice(b",\n");
        }
        serde_json::to_writer(&mut out, block).expect("block serializes");
    }
    out.extend_from_slice(b"\n]}\n");
    out
}

pub fn normalize(mut doc: Document) -> Result<Document, Error> {
    for (index, block) in doc.blocks.iter_mut().enumerate() {
        if matches!(block.line_height, Some(height) if !height.is_finite() || !(1.0..=3.0).contains(&height)) {
            return Err(Error::Damaged(format!("paragraph {} has a line height outside 1–3", index + 1)));
        }
        let mut runs: Vec<crate::model::Run> = Vec::with_capacity(block.runs.len());
        for run in block.runs.drain(..) {
            if matches!(run.letter_spacing, Some(spacing) if !spacing.is_finite() || !(-5.0..=20.0).contains(&spacing)) {
                return Err(Error::Damaged(format!("paragraph {} has letter spacing outside −5–20 points", index + 1)));
            }
            if matches!(run.font_size, Some(size) if !(8..=144).contains(&size)) {
                return Err(Error::Damaged(format!("paragraph {} has a text size outside 8–144 points", index + 1)));
            }
            if let Some(c) = run.text.chars().find(|c| matches!(c, '\n' | '\r' | '\u{2029}' | '\0')) {
                return Err(Error::Damaged(format!(
                    "paragraph {} contains a forbidden character U+{:04X}",
                    index + 1,
                    c as u32
                )));
            }
            if matches!(run.link.as_deref(), Some(l) if l.trim().is_empty()) {
                return Err(Error::Damaged(format!("paragraph {} has an empty link", index + 1)));
            }
            if run.text.is_empty() {
                continue;
            }
            match runs.last_mut() {
                Some(prev) if prev.same_marks(&run) => prev.text.push_str(&run.text),
                _ => runs.push(run),
            }
        }
        block.runs = runs;
    }
    if doc.blocks.is_empty() {
        doc.blocks.push(Block::default());
    }
    Ok(doc)
}

pub fn plain_text(doc: &Document) -> String {
    let mut out = String::new();
    let mut ordinal = 0u32;
    for block in &doc.blocks {
        match block.list {
            Some(ListKind::Number) => {
                ordinal += 1;
                out.push_str(&format!("{ordinal}. "));
            }
            Some(ListKind::Bullet) => {
                ordinal = 0;
                out.push_str("• ");
            }
            None => ordinal = 0,
        }
        out.push_str(&block.text());
        out.push('\n');
    }
    out
}

pub fn word_count(text: &str) -> u64 {
    use unicode_segmentation::UnicodeSegmentation;
    text.unicode_words().count() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Run, Style};

    fn run(text: &str) -> Run {
        Run { text: text.into(), ..Default::default() }
    }

    fn sample() -> Document {
        Document {
            appearance: Appearance::Classic,
            blocks: vec![
                Block { style: Style::Title, list: None, alignment: Default::default(), line_height: None, runs: vec![run("On Writing")] },
                Block {
                    style: Style::Body,
                    list: None,
                    alignment: Default::default(), line_height: None,
                    runs: vec![
                        run("Plain, "),
                        Run { text: "bold".into(), bold: true, ..Default::default() },
                        run(" and "),
                        Run { text: "linked".into(), link: Some("https://example.com".into()), ..Default::default() },
                    ],
                },
                Block { style: Style::Body, list: Some(ListKind::Number), alignment: Default::default(), line_height: None, runs: vec![run("first")] },
                Block { style: Style::Body, list: Some(ListKind::Number), alignment: Default::default(), line_height: None, runs: vec![run("second")] },
                Block { style: Style::Quote, list: None, alignment: Default::default(), line_height: None, runs: vec![run("Ünïcödé — 日本語 🎉")] },
            ],
        }
    }

    #[test]
    fn round_trips_through_file_format() {
        let doc = sample();
        let bytes = encode_file(doc.clone()).unwrap();
        assert_eq!(decode_file(&bytes).unwrap(), doc);
    }

    #[test]
    fn encoding_is_canonical_and_line_per_block() {
        let bytes = encode_file(sample()).unwrap();
        let text = String::from_utf8(bytes.clone()).unwrap();
        assert!(text.starts_with("{\"format\":\"hermes\",\"version\":5,\"appearance\":\"classic\",\"blocks\":[\n"));
        assert_eq!(text.lines().count(), sample().blocks.len() + 2);
        let again = encode_file(decode_file(&bytes).unwrap()).unwrap();
        assert_eq!(again, bytes);
    }

    #[test]
    fn merges_adjacent_runs_and_drops_empty_ones() {
        let doc = Document {
            appearance: Appearance::Serif,
            blocks: vec![Block {
                style: Style::Body,
                list: None,
                    alignment: Default::default(), line_height: None,
                runs: vec![run("a"), run(""), run("b"), Run { text: "c".into(), italic: true, ..Default::default() }],
            }],
        };
        let n = normalize(doc).unwrap();
        assert_eq!(n.blocks[0].runs.len(), 2);
        assert_eq!(n.blocks[0].runs[0].text, "ab");
    }

    #[test]
    fn empty_document_gets_one_paragraph() {
        assert_eq!(normalize(Document::default()).unwrap().blocks.len(), 1);
    }

    #[test]
    fn line_height_round_trips_and_old_files_use_style_defaults() {
        let doc = Document {
            blocks: vec![Block { line_height: Some(1.75), runs: vec![run("Spaced")], ..Default::default() }],
            ..Default::default()
        };
        assert_eq!(decode_file(&encode_file(doc.clone()).unwrap()).unwrap(), doc);
        for version in [1, 2] {
            let bytes = format!(r#"{{"format":"hermes","version":{version},"blocks":[{{"runs":[{{"text":"Original"}}]}}]}}"#);
            assert_eq!(decode_file(bytes.as_bytes()).unwrap().blocks[0].line_height, None);
        }
    }

    #[test]
    fn rejects_invalid_line_heights() {
        for height in [0.0, 0.9, 3.1, f64::NAN, f64::INFINITY] {
            let doc = Document {
                blocks: vec![Block { line_height: Some(height), runs: vec![run("text")], ..Default::default() }],
                ..Default::default()
            };
            assert!(matches!(encode_file(doc), Err(Error::Damaged(_))));
        }
        assert!(matches!(decode_file(br#"{"format":"hermes","version":3,"blocks":[{"lineHeight":4}]}"#), Err(Error::Damaged(_))));
    }

    #[test]
    fn sizes_and_alignment_round_trip_without_merging_different_sizes() {
        let doc = Document {
            blocks: vec![Block {
                alignment: crate::model::Alignment::Center,
                runs: vec![
                    Run { text: "small".into(), font_size: Some(12), ..Default::default() },
                    Run { text: "large".into(), font_size: Some(36), ..Default::default() },
                ],
                ..Default::default()
            }],
            ..Default::default()
        };
        assert_eq!(decode_file(&encode_file(doc.clone()).unwrap()).unwrap(), doc);
    }

    #[test]
    fn version_one_documents_keep_their_original_defaults() {
        let doc = decode_file(br#"{"format":"hermes","version":1,"blocks":[{"runs":[{"text":"Original"}]}]}"#).unwrap();
        assert_eq!(doc.blocks[0].alignment, crate::model::Alignment::Left);
        assert_eq!(doc.blocks[0].runs[0].font_size, None);
        assert!(!doc.blocks[0].runs[0].code);
        assert!(!doc.blocks[0].runs[0].strikethrough);
        let upgraded = encode_file(doc.clone()).unwrap();
        assert_eq!(decode_file(&upgraded).unwrap(), doc);
        assert!(String::from_utf8(upgraded).unwrap().contains("\"version\":5"));
    }

    #[test]
    fn code_and_strikethrough_round_trip_and_v4_files_decode_cleanly() {
        let doc = Document {
            blocks: vec![Block {
                runs: vec![
                    run("Use "),
                    Run { text: "cargo test".into(), code: true, ..Default::default() },
                    run(" not "),
                    Run { text: "manual".into(), strikethrough: true, ..Default::default() },
                    Run { text: " old".into(), strikethrough: true, code: true, bold: true, ..Default::default() },
                ],
                ..Default::default()
            }],
            ..Default::default()
        };
        let encoded = encode_file(doc.clone()).unwrap();
        assert_eq!(decode_file(&encoded).unwrap(), doc);

        let v4 = decode_file(br#"{"format":"hermes","version":4,"blocks":[{"runs":[{"text":"v4","letterSpacing":1.0}]}]}"#).unwrap();
        assert!(!v4.blocks[0].runs[0].code);
        assert!(!v4.blocks[0].runs[0].strikethrough);
        assert_eq!(v4.blocks[0].runs[0].letter_spacing, Some(1.0));
    }

    #[test]
    fn rejects_invalid_sizes_and_alignment() {
        for size in [0, 7, 145, 65535] {
            let doc = Document {
                blocks: vec![Block { runs: vec![Run { text: "text".into(), font_size: Some(size), ..Default::default() }], ..Default::default() }],
                ..Default::default()
            };
            assert!(matches!(encode_file(doc), Err(Error::Damaged(_))));
        }
        assert!(matches!(decode_file(br#"{"format":"hermes","version":2,"blocks":[{"alignment":"diagonal"}]}"#), Err(Error::Damaged(_))));
    }

    #[test]
    fn rejects_newlines_inside_runs() {
        let doc = Document { blocks: vec![Block { runs: vec![run("a\nb")], ..Default::default() }], ..Default::default() };
        assert!(matches!(encode_file(doc), Err(Error::Damaged(_))));
    }

    #[test]
    fn opens_legacy_documents_and_writes_hermes() {
        for version in [1, 2, 3, 4] {
            let bytes = format!(r#"{{"format":"quire","version":{version},"blocks":[{{"style":"heading","runs":[{{"text":"Legacy","bold":true}}]}}]}}"#);
            let doc = decode_file(bytes.as_bytes()).unwrap();
            assert_eq!(doc.blocks[0].runs[0].text, "Legacy");
            assert!(doc.blocks[0].runs[0].bold);
            let encoded = encode_file(doc.clone()).unwrap();
            assert!(String::from_utf8_lossy(&encoded).starts_with("{\"format\":\"hermes\""));
            assert_eq!(decode_file(&encoded).unwrap(), doc);
        }
    }

    #[test]
    fn letter_spacing_round_trips_without_merging_distinct_runs() {
        let doc = Document { blocks: vec![Block { runs: vec![
            Run { text: "wide".into(), letter_spacing: Some(1.5), ..Default::default() },
            Run { text: "tight".into(), letter_spacing: Some(-0.5), ..Default::default() },
        ], ..Default::default() }], ..Default::default() };
        assert_eq!(decode_file(&encode_file(doc.clone()).unwrap()).unwrap(), doc);
        let old = decode_file(br#"{"format":"hermes","version":3,"blocks":[{"runs":[{"text":"old"}]}]}"#).unwrap();
        assert_eq!(old.blocks[0].runs[0].letter_spacing, None);
    }

    #[test]
    fn rejects_invalid_letter_spacing() {
        for spacing in [-5.1, 20.1, f64::NAN, f64::INFINITY] {
            let doc = Document { blocks: vec![Block { runs: vec![Run {
                text: "text".into(), letter_spacing: Some(spacing), ..Default::default()
            }], ..Default::default() }], ..Default::default() };
            assert!(matches!(encode_file(doc), Err(Error::Damaged(_))));
        }
    }

    #[test]
    fn rejects_foreign_and_newer_files() {
        assert_eq!(decode_file(b"not json"), Err(Error::NotADocument));
        assert_eq!(decode_file(br#"{"format":"other","version":1}"#), Err(Error::NotADocument));
        assert_eq!(decode_file(br#"{"format":"hermes","version":9,"blocks":[]}"#), Err(Error::NewerVersion(9)));
    }

    #[test]
    fn rejects_unknown_fields_instead_of_dropping_them() {
        let bytes = br#"{"format":"hermes","version":1,"blocks":[{"style":"body","runs":[],"color":"red"}]}"#;
        assert!(matches!(decode_file(bytes), Err(Error::Damaged(_))));
    }

    #[test]
    fn plain_text_numbers_consecutive_items() {
        let text = plain_text(&sample());
        assert_eq!(text, "On Writing\nPlain, bold and linked\n1. first\n2. second\nÜnïcödé — 日本語 🎉\n");
    }

    #[test]
    fn counts_words_across_scripts() {
        assert_eq!(word_count("Hello, world — it's  fine."), 4);
        assert_eq!(word_count(""), 0);
        assert_eq!(word_count("   \n\t  "), 0);
        assert_eq!(word_count("state-of-the-art 2026"), 5);
        assert_eq!(word_count("日本語とEnglish"), 5);
    }

    #[test]
    fn rejects_all_forbidden_run_characters_and_empty_links() {
        for forbidden in ["a\rb", "a\u{2029}b", "a\0b"] {
            let doc = Document {
                blocks: vec![Block { runs: vec![run(forbidden)], ..Default::default() }],
                ..Default::default()
            };
            assert!(matches!(encode_file(doc), Err(Error::Damaged(_))));
        }
        for bad_link in ["", "   \t "] {
            let doc = Document {
                blocks: vec![Block {
                    runs: vec![Run { text: "link".into(), link: Some(bad_link.into()), ..Default::default() }],
                    ..Default::default()
                }],
                ..Default::default()
            };
            assert!(matches!(encode_file(doc), Err(Error::Damaged(_))));
        }
    }

    #[test]
    fn accepts_exact_formatting_boundaries_and_rejects_bad_versions() {
        let doc = Document {
            blocks: vec![
                Block {
                    line_height: Some(1.0),
                    runs: vec![Run { text: "min".into(), font_size: Some(8), letter_spacing: Some(-5.0), ..Default::default() }],
                    ..Default::default()
                },
                Block {
                    line_height: Some(3.0),
                    runs: vec![Run { text: "max".into(), font_size: Some(144), letter_spacing: Some(20.0), ..Default::default() }],
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        assert_eq!(decode_file(&encode_file(doc.clone()).unwrap()).unwrap(), doc);
        assert!(matches!(decode_file(br#"{"format":"hermes","blocks":[]}"#), Err(Error::Damaged(_))));
        assert!(matches!(decode_file(br#"{"format":"hermes","version":0,"blocks":[]}"#), Err(Error::Damaged(_))));
    }
}
