use pulldown_cmark::{Event, HeadingLevel, LinkType, Options, Parser, Tag, TagEnd};

use crate::format::normalize;
use crate::model::{Block, Document, ListKind, Run, Style};

pub fn parse(source: &str) -> Option<Document> {
    let source = source.strip_prefix('\u{feff}').unwrap_or(source);
    let document = read(source)?;
    // Only use the rich editor if its model can be serialized without changing the meaning.
    if document.blocks.iter().any(|block| block.runs.is_empty()) {
        return (document == normalize(Document::default()).ok()?).then_some(document);
    }
    render_checked(&document).map(|_| document)
}

fn read(source: &str) -> Option<Document> {
    let options =
        (Options::all() - Options::ENABLE_SMART_PUNCTUATION - Options::ENABLE_OLD_FOOTNOTES)
            | Options::ENABLE_FOOTNOTES;
    let parser = Parser::new_ext(source, options);
    if parser.reference_definitions().iter().next().is_some()
        || source.contains(['\u{2028}', '\u{2029}', '\0', '\u{fffc}'])
    {
        return None;
    }
    let mut events = parser.peekable();
    let mut blocks = Vec::new();
    while let Some(event) = events.next() {
        let Event::Start(tag) = event else {
            return None;
        };
        let (style, end) = match tag {
            Tag::Paragraph => (Style::Body, TagEnd::Paragraph),
            Tag::Heading {
                level,
                id: None,
                classes,
                attrs,
            } if classes.is_empty() && attrs.is_empty() => {
                let style = match level {
                    HeadingLevel::H1 => Style::Title,
                    HeadingLevel::H2 => Style::Heading,
                    HeadingLevel::H3 => Style::Subheading,
                    _ => return None,
                };
                (style, TagEnd::Heading(level))
            }
            Tag::BlockQuote(None) => {
                if blocks
                    .last()
                    .is_some_and(|block: &Block| block.style == Style::Quote)
                {
                    return None;
                }
                let block_count = blocks.len();
                while matches!(events.peek(), Some(Event::Start(Tag::Paragraph))) {
                    events.next();
                    let runs = inlines(&mut events, TagEnd::Paragraph)?;
                    blocks.push(Block {
                        style: Style::Quote,
                        runs,
                        ..Block::default()
                    });
                }
                if events.next() != Some(Event::End(TagEnd::BlockQuote(None)))
                    || blocks.len() == block_count
                {
                    return None;
                }
                continue;
            }
            Tag::List(start @ (None | Some(1))) => {
                let kind = if start.is_some() {
                    ListKind::Number
                } else {
                    ListKind::Bullet
                };
                if blocks
                    .last()
                    .is_some_and(|block: &Block| block.list == Some(kind))
                {
                    return None;
                }
                while matches!(events.peek(), Some(Event::Start(Tag::Item))) {
                    events.next();
                    let runs = if matches!(events.peek(), Some(Event::Start(Tag::Paragraph))) {
                        events.next();
                        let runs = inlines(&mut events, TagEnd::Paragraph)?;
                        if events.next() != Some(Event::End(TagEnd::Item)) {
                            return None;
                        }
                        runs
                    } else {
                        inlines(&mut events, TagEnd::Item)?
                    };
                    blocks.push(Block {
                        list: Some(kind),
                        runs,
                        ..Block::default()
                    });
                }
                if events.next() != Some(Event::End(TagEnd::List(start.is_some()))) {
                    return None;
                }
                continue;
            }
            _ => return None,
        };
        blocks.push(Block {
            style,
            runs: inlines(&mut events, end)?,
            ..Block::default()
        });
    }
    normalize(Document {
        blocks,
        ..Document::default()
    })
    .ok()
}

fn inlines<'a>(events: &mut impl Iterator<Item = Event<'a>>, end: TagEnd) -> Option<Vec<Run>> {
    let mut runs = Vec::new();
    let mut marks = Run::default();
    let (mut bold, mut italic, mut strikethrough) = (0, 0, 0);
    for event in events {
        match event {
            Event::End(tag) if tag == end => return Some(runs),
            Event::Start(Tag::Strong) => bold += 1,
            Event::End(TagEnd::Strong) => bold -= 1,
            Event::Start(Tag::Emphasis) => italic += 1,
            Event::End(TagEnd::Emphasis) => italic -= 1,
            Event::Start(Tag::Strikethrough) => strikethrough += 1,
            Event::End(TagEnd::Strikethrough) => strikethrough -= 1,
            Event::Start(Tag::Link {
                link_type,
                dest_url,
                title,
                ..
            }) if matches!(
                link_type,
                LinkType::Inline | LinkType::Autolink | LinkType::Email
            ) && !dest_url.trim().is_empty()
                && title.is_empty() =>
            {
                marks.link = Some(dest_url.into_string());
            }
            Event::End(TagEnd::Link) => marks.link = None,
            Event::Code(text) => runs.push(Run {
                text: text.into_string(),
                bold: bold > 0,
                italic: italic > 0,
                strikethrough: strikethrough > 0,
                code: true,
                ..marks.clone()
            }),
            Event::Text(text) => runs.push(Run {
                text: text.into_string(),
                bold: bold > 0,
                italic: italic > 0,
                strikethrough: strikethrough > 0,
                ..marks.clone()
            }),
            Event::SoftBreak => runs.push(Run {
                text: " ".into(),
                bold: bold > 0,
                italic: italic > 0,
                strikethrough: strikethrough > 0,
                ..marks.clone()
            }),
            _ => return None,
        }
    }
    None
}

pub fn write(mut document: Document) -> Result<String, String> {
    document.appearance = Default::default();
    for block in &mut document.blocks {
        block.alignment = Default::default();
        block.line_height = None;
        if block.list.is_some() || block.style == Style::Subtitle {
            block.style = Style::Body;
        }
        for run in &mut block.runs {
            run.underline = false;
            run.font_size = None;
            run.letter_spacing = None;
        }
    }
    let mut document = normalize(document).map_err(|error| error.to_string())?;
    document.blocks.retain(|block| !block.runs.is_empty());
    if document.blocks.is_empty() {
        return Ok(String::new());
    }
    render_checked(&document).ok_or_else(|| {
        "Some formatting can’t be saved safely as Markdown. Remove it or save a Hermes copy.".into()
    })
}

fn render_checked(document: &Document) -> Option<String> {
    for (italic_delimiter, escape_edges) in [("_", false), ("*", false), ("_", true), ("*", true)] {
        let source = render(document, italic_delimiter, escape_edges);
        if read(&source).as_ref() == Some(document) {
            return Some(source);
        }
    }
    None
}

fn render(document: &Document, italic_delimiter: &str, escape_edges: bool) -> String {
    let mut output = String::new();
    let mut number = 0;
    for (index, block) in document.blocks.iter().enumerate() {
        if index > 0 {
            let previous = &document.blocks[index - 1];
            if previous.style == Style::Quote && block.style == Style::Quote {
                output.push_str(">\n");
            } else if block.list.is_none() || previous.list != block.list {
                output.push('\n');
            }
        }
        match block.list {
            Some(ListKind::Number) => {
                number += 1;
                output.push_str(&format!("{number}. "));
            }
            Some(ListKind::Bullet) => output.push_str("- "),
            None => output.push_str(match block.style {
                Style::Title => "# ",
                Style::Heading => "## ",
                Style::Subheading => "### ",
                Style::Quote => "> ",
                _ => "",
            }),
        }
        if block.list != Some(ListKind::Number) {
            number = 0;
        }
        for runs in block.runs.chunk_by(|left, right| left.link == right.link) {
            if let Some(link) = &runs[0].link {
                output.push('[');
                write_runs(runs, &mut output, italic_delimiter, escape_edges);
                output.push_str("](<");
                for character in link.chars() {
                    if matches!(character, '<' | '>' | '\\' | '&') {
                        output.push('\\');
                    }
                    output.push(character);
                }
                output.push_str(">)");
            } else {
                write_runs(runs, &mut output, italic_delimiter, escape_edges);
            }
        }
        output.push('\n');
    }
    output
}

fn write_runs(runs: &[Run], output: &mut String, italic_delimiter: &str, escape_edges: bool) {
    let mut open: Vec<&str> = Vec::with_capacity(3);
    for run in runs {
        let wants = |mark| match mark {
            "**" => run.bold,
            "~~" => run.strikethrough,
            _ => run.italic,
        };
        let keep = open.iter().take_while(|mark| wants(**mark)).count();
        for mark in open.drain(keep..).rev() {
            output.push_str(mark);
        }
        for mark in ["**", italic_delimiter, "~~"] {
            if wants(mark) && !open.contains(&mark) {
                output.push_str(mark);
                open.push(mark);
            }
        }
        if run.code {
            write_code_span(&run.text, output);
        } else {
            escape(&run.text, output, escape_edges);
        }
    }
    for mark in open.into_iter().rev() {
        output.push_str(mark);
    }
}

fn write_code_span(text: &str, output: &mut String) {
    let mut max_ticks = 0usize;
    let mut current_ticks = 0usize;
    for byte in text.bytes() {
        if byte == b'`' {
            current_ticks += 1;
            max_ticks = max_ticks.max(current_ticks);
        } else {
            current_ticks = 0;
        }
    }
    let ticks = max_ticks + 1;
    let pad = text.starts_with('`')
        || text.ends_with('`')
        || (text.starts_with(' ') && text.ends_with(' ') && text.bytes().any(|b| b != b' '));
    for _ in 0..ticks {
        output.push('`');
    }
    if pad {
        output.push(' ');
    }
    output.push_str(text);
    if pad {
        output.push(' ');
    }
    for _ in 0..ticks {
        output.push('`');
    }
}

fn escape(text: &str, output: &mut String, escape_edges: bool) {
    let trimmed_start = text.len() - text.trim_start().len();
    let trimmed_end = text.trim_end().len();
    for (index, character) in text.char_indices() {
        if escape_edges
            && character.is_whitespace()
            && (index < trimmed_start || index >= trimmed_end || character == '\t')
        {
            output.push_str(&format!("&#{};", character as u32));
        } else {
            let initial_marker =
                matches!(character, '#' | '+' | '-' | '=' | ':') && index == trimmed_start;
            let list_delimiter = matches!(character, '.' | ')')
                && index > trimmed_start
                && text[trimmed_start..index]
                    .bytes()
                    .all(|byte| byte.is_ascii_digit());
            let image_marker = escape_edges && character == '!' && index + 1 == text.len();
            if "\\`*_[]<>&~^$".contains(character)
                || initial_marker
                || list_delimiter
                || image_marker
            {
                output.push('\\');
            }
            output.push(character);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rich_markdown_round_trips_after_editing() {
        let source = "# A draft\n\nPlain **bold**, *italic*, ~~struck~~, `code`, and [a link](../notes.md#topic).\n\n## Section\n\n> A quote\n\n- One\n- Two\n\n1. First\n2. Second\n\n### Details\n";
        let mut document = parse(source).expect("everyday Markdown should open in the rich editor");
        assert_eq!(
            document
                .blocks
                .iter()
                .map(|block| block.style)
                .collect::<Vec<_>>(),
            [
                Style::Title,
                Style::Body,
                Style::Heading,
                Style::Quote,
                Style::Body,
                Style::Body,
                Style::Body,
                Style::Body,
                Style::Subheading,
            ]
        );
        assert!(document.blocks[1]
            .runs
            .iter()
            .any(|run| run.bold && run.text == "bold"));
        assert!(document.blocks[1]
            .runs
            .iter()
            .any(|run| run.italic && run.text == "italic"));
        assert!(document.blocks[1]
            .runs
            .iter()
            .any(|run| run.strikethrough && run.text == "struck"));
        assert!(document.blocks[1]
            .runs
            .iter()
            .any(|run| run.code && run.text == "code"));
        assert!(document.blocks[1]
            .runs
            .iter()
            .any(|run| run.link.as_deref() == Some("../notes.md#topic")));
        document.blocks[0].runs[0].text = "An edited draft".into();
        let saved = write(document.clone()).unwrap();
        assert!(saved.starts_with("# An edited draft\n"), "{saved}");
        assert!(saved.contains("~~struck~~") && saved.contains("`code`"), "{saved}");
        assert_eq!(parse(&saved), Some(document));
    }

    #[test]
    fn inline_code_and_strikethrough_edge_cases_round_trip() {
        let document = Document {
            blocks: vec![Block {
                runs: vec![
                    Run { text: "a `b` c".into(), code: true, ..Run::default() },
                    Run { text: " ".into(), ..Run::default() },
                    Run { text: "`ticks`".into(), code: true, bold: true, ..Run::default() },
                    Run { text: " ".into(), ..Run::default() },
                    Run { text: " padded ".into(), code: true, ..Run::default() },
                    Run { text: " ".into(), ..Run::default() },
                    Run { text: " ".into(), code: true, ..Run::default() },
                    Run { text: " ".into(), ..Run::default() },
                    Run {
                        text: "linked_fn()".into(),
                        code: true,
                        strikethrough: true,
                        link: Some("https://example.com".into()),
                        ..Run::default()
                    },
                    Run { text: " literal `ticks` and ~~tilde~~".into(), ..Run::default() },
                ],
                ..Block::default()
            }],
            ..Document::default()
        };
        let saved = write(document.clone()).unwrap();
        assert_eq!(parse(&saved), Some(normalize(document).unwrap()));
    }

    #[test]
    fn unsupported_constructs_use_source_mode() {
        for source in [
            "---\ntitle: Draft\n---\n\nText\n",
            "+++\ntitle = 'Draft'\n+++\n\nText\n",
            "| A | B |\n| - | - |\n| 1 | 2 |\n",
            "```rust\nfn main() {}\n```\n",
            "![alt](image.png)",
            "- [x] Task",
            "<u>Underline</u>",
            "- parent\n  - child",
            "4. Fourth",
            "#### Level four",
            "A  \nhard break",
            ">\n",
            "[reference]: ./notes.md\n",
            "[title](https://example.com \"tooltip\")",
            "\0",
        ] {
            assert!(
                parse(source).is_none(),
                "must preserve as source: {source:?}"
            );
        }
    }

    #[test]
    fn literal_text_cannot_create_markdown_structure_on_save() {
        let document = Document {
            blocks: [
                "# Not a heading",
                "3. Not a list",
                "<tag> & *text*",
                "   indented",
            ]
            .into_iter()
            .map(|text| Block {
                runs: vec![Run {
                    text: text.into(),
                    ..Run::default()
                }],
                ..Block::default()
            })
            .collect(),
            ..Document::default()
        };
        let saved = write(document.clone()).unwrap();
        assert_eq!(parse(&saved), Some(document));
    }

    #[test]
    fn handles_bom_empty_documents_and_multi_paragraph_quotes() {
        let bom_doc = parse("\u{feff}# Title\n\nBody\n").expect("BOM Markdown should parse");
        assert_eq!(bom_doc.blocks.len(), 2);
        assert_eq!(bom_doc.blocks[0].style, Style::Title);

        let empty = parse("").expect("empty Markdown should open in rich editor");
        assert_eq!(empty.blocks.len(), 1);
        assert!(empty.blocks[0].runs.is_empty());
        assert_eq!(write(empty).unwrap(), "");

        let quote = parse("> First quote\n>\n> Second quote\n").expect("multi-paragraph quote parses");
        assert_eq!(quote.blocks.len(), 2);
        assert!(quote.blocks.iter().all(|b| b.style == Style::Quote));
        let rendered = write(quote.clone()).unwrap();
        assert_eq!(rendered, "> First quote\n>\n> Second quote\n");
        assert_eq!(parse(&rendered), Some(quote));

        assert!(
            parse("> First quote\n\n> Separate quote\n").is_none(),
            "separate adjacent blockquotes must stay in source mode to avoid merging"
        );
    }

    #[test]
    fn round_trips_nested_marks_styled_links_and_special_urls() {
        let document = Document {
            blocks: vec![Block {
                runs: vec![
                    Run { text: "both".into(), bold: true, italic: true, ..Run::default() },
                    Run { text: " then ".into(), ..Run::default() },
                    Run {
                        text: "bold link".into(),
                        bold: true,
                        link: Some("https://example.com/a?x=1&y=<2>".into()),
                        ..Run::default()
                    },
                    Run {
                        text: " italic link".into(),
                        italic: true,
                        link: Some("https://example.com/a?x=1&y=<2>".into()),
                        ..Run::default()
                    },
                    Run { text: " trailing!".into(), ..Run::default() },
                    Run { text: "\ttabbed ".into(), ..Run::default() },
                ],
                ..Block::default()
            }],
            ..Document::default()
        };
        let saved = write(document.clone()).unwrap();
        assert_eq!(parse(&saved), Some(normalize(document).unwrap()));
    }

    #[test]
    fn write_strips_hermes_only_formatting_cleanly() {
        let document = Document {
            appearance: crate::model::Appearance::Mono,
            blocks: vec![
                Block {
                    style: Style::Subtitle,
                    alignment: crate::model::Alignment::Center,
                    line_height: Some(2.0),
                    runs: vec![Run {
                        text: "Sub".into(),
                        underline: true,
                        font_size: Some(24),
                        letter_spacing: Some(1.5),
                        ..Run::default()
                    }],
                    ..Block::default()
                },
                Block {
                    style: Style::Heading,
                    list: Some(ListKind::Bullet),
                    runs: vec![Run { text: "Item".into(), ..Run::default() }],
                    ..Block::default()
                },
                Block::default(),
            ],
        };
        let saved = write(document).unwrap();
        assert_eq!(saved, "Sub\n\n- Item\n");
    }
}
