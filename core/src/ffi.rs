//! C ABI consumed by the Swift app. Documents cross the boundary as UTF-8 JSON in the
//! interchange shape of `model::Document`; file bytes never leave Rust unvalidated.

use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::{format, markdown};
use crate::model::Document;

#[repr(C)]
pub struct HermesBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    /// When false, the buffer holds a UTF-8 error message instead of a result.
    pub ok: bool,
}

impl HermesBuffer {
    fn from_vec(bytes: Vec<u8>, ok: bool) -> Self {
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        let ptr = Box::into_raw(boxed) as *mut u8;
        HermesBuffer { ptr, len, ok }
    }

    fn from_result(result: Result<Vec<u8>, String>) -> Self {
        match result {
            Ok(bytes) => Self::from_vec(bytes, true),
            Err(message) => Self::from_vec(message.into_bytes(), false),
        }
    }
}

unsafe fn input<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

fn guarded(f: impl FnOnce() -> Result<Vec<u8>, String>) -> HermesBuffer {
    let result = catch_unwind(AssertUnwindSafe(f))
        .unwrap_or_else(|_| Err("Internal error in the document core.".to_owned()));
    HermesBuffer::from_result(result)
}

fn parse_interchange(bytes: &[u8]) -> Result<Document, String> {
    serde_json::from_slice(bytes).map_err(|e| format!("Invalid document data: {e}"))
}

/// File bytes → current-version interchange JSON.
#[no_mangle]
pub unsafe extern "C" fn hermes_decode_file(ptr: *const u8, len: usize) -> HermesBuffer {
    let bytes = input(ptr, len);
    guarded(|| {
        let doc = format::decode_file(bytes).map_err(|e| e.to_string())?;
        serde_json::to_vec(&doc).map_err(|e| e.to_string())
    })
}

/// Interchange JSON → validated, normalized file bytes.
#[no_mangle]
pub unsafe extern "C" fn hermes_encode_file(ptr: *const u8, len: usize) -> HermesBuffer {
    let bytes = input(ptr, len);
    guarded(|| format::encode_file(parse_interchange(bytes)?).map_err(|e| e.to_string()))
}

/// Interchange JSON → plain text export.
#[no_mangle]
pub unsafe extern "C" fn hermes_plain_text(ptr: *const u8, len: usize) -> HermesBuffer {
    let bytes = input(ptr, len);
    guarded(|| Ok(format::plain_text(&parse_interchange(bytes)?).into_bytes()))
}

/// UTF-8 text → word count. Invalid UTF-8 is counted lossily.
#[no_mangle]
pub unsafe extern "C" fn hermes_decode_markdown(ptr: *const u8, len: usize) -> HermesBuffer {
    let bytes = input(ptr, len);
    guarded(|| {
        let source = std::str::from_utf8(bytes).map_err(|_| "Markdown files must use UTF-8 text.")?;
        serde_json::to_vec(&markdown::parse(source)).map_err(|e| e.to_string())
    })
}

#[no_mangle]
pub unsafe extern "C" fn hermes_encode_markdown(ptr: *const u8, len: usize) -> HermesBuffer {
    let bytes = input(ptr, len);
    guarded(|| markdown::write(parse_interchange(bytes)?).map(String::into_bytes))
}

#[no_mangle]
pub unsafe extern "C" fn hermes_word_count(ptr: *const u8, len: usize) -> u64 {
    let bytes = input(ptr, len);
    catch_unwind(|| format::word_count(&String::from_utf8_lossy(bytes))).unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn hermes_buffer_free(buffer: HermesBuffer) {
    if !buffer.ptr.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.ptr, buffer.len)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe fn take(buffer: HermesBuffer) -> (bool, String) {
        let s = String::from_utf8(std::slice::from_raw_parts(buffer.ptr, buffer.len).to_vec()).unwrap();
        let ok = buffer.ok;
        hermes_buffer_free(buffer);
        (ok, s)
    }

    #[test]
    fn encode_then_decode_over_the_c_abi() {
        unsafe {
            let json = br#"{"appearance":"mono","blocks":[{"style":"heading","runs":[{"text":"Hi","bold":false}]}]}"#;
            let (ok, file) = take(hermes_encode_file(json.as_ptr(), json.len()));
            assert!(ok, "{file}");
            let (ok, back) = take(hermes_decode_file(file.as_ptr(), file.len()));
            assert!(ok);
            assert_eq!(back, r#"{"appearance":"mono","blocks":[{"style":"heading","runs":[{"text":"Hi"}]}]}"#);
        }
    }

    #[test]
    fn errors_come_back_as_messages() {
        unsafe {
            let (ok, message) = take(hermes_decode_file(b"{}".as_ptr(), 2));
            assert!(!ok);
            assert_eq!(message, "This file isn't a hermes document.");
            let (ok, _) = take(hermes_decode_file(std::ptr::null(), 0));
            assert!(!ok);
        }
    }

    #[test]
    fn markdown_plain_text_and_word_count_over_the_c_abi() {
        unsafe {
            let md = b"# Hello\n\nWorld\n";
            let (ok, json) = take(hermes_decode_markdown(md.as_ptr(), md.len()));
            assert!(ok, "{json}");
            let (ok, back) = take(hermes_encode_markdown(json.as_ptr(), json.len()));
            assert!(ok, "{back}");
            assert_eq!(back, "# Hello\n\nWorld\n");

            let (ok, plain) = take(hermes_plain_text(json.as_ptr(), json.len()));
            assert!(ok, "{plain}");
            assert_eq!(plain, "Hello\nWorld\n");

            let fenced = b"```rust\nfn main() {}\n```\n";
            let (ok, source_mode) = take(hermes_decode_markdown(fenced.as_ptr(), fenced.len()));
            assert!(ok, "{source_mode}");
            assert_eq!(source_mode, "null");

            let invalid_utf8: [u8; 2] = [0xFF, 0xFE];
            let (ok, message) = take(hermes_decode_markdown(invalid_utf8.as_ptr(), invalid_utf8.len()));
            assert!(!ok);
            assert_eq!(message, "Markdown files must use UTF-8 text.");

            assert_eq!(hermes_word_count(std::ptr::null(), 0), 0);
            assert_eq!(hermes_word_count(invalid_utf8.as_ptr(), invalid_utf8.len()), 0);
        }
    }
}
