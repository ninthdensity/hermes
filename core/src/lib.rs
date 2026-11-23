pub mod ffi;
pub mod format;
mod markdown;
pub mod model;

pub use format::{decode_file, encode_file, plain_text, word_count, Error};
pub use model::{Appearance, Block, Document, ListKind, Run, Style};
