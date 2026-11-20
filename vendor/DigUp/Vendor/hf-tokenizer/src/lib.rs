use std::{panic::{catch_unwind, AssertUnwindSafe}, slice, str::{self, FromStr}};
use tokenizers::{Tokenizer, TokenizerImpl, models::bpe::BPE,
    normalizers::NormalizerWrapper, pre_tokenizers::PreTokenizerWrapper,
    processors::PostProcessorWrapper, decoders::DecoderWrapper};

type BpeTokenizer = TokenizerImpl<BPE, NormalizerWrapper, PreTokenizerWrapper,
    PostProcessorWrapper, DecoderWrapper>;

fn parse_tokenizer(content: &str) -> tokenizers::Result<Tokenizer> {
    // BPE can deserialize directly, without ModelWrapper's intermediate JSON tree.
    BpeTokenizer::from_str(content).map(Tokenizer::from)
        .or_else(|_| Tokenizer::from_str(content))
}

fn boundary(f: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(255)
}

unsafe fn utf8<'a>(ptr: *const u8, len: usize) -> Result<&'a str, i32> {
    if len > isize::MAX as usize || (ptr.is_null() && len != 0) { return Err(1); }
    let bytes = if len == 0 { &[] } else { unsafe { slice::from_raw_parts(ptr, len) } };
    str::from_utf8(bytes).map_err(|_| 1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tok_load(path: *const u8, path_len: usize, out: *mut *mut Tokenizer) -> i32 {
    boundary(|| {
        if out.is_null() { return 1; }
        unsafe { *out = std::ptr::null_mut(); }
        let path = match unsafe { utf8(path, path_len) } { Ok(x) => x, Err(e) => return e };
        tokenizers::utils::parallelism::set_parallelism(false);
        let content = match std::fs::read_to_string(path) { Ok(x) => x, Err(_) => return 3 };
        let mut tok = match parse_tokenizer(&content) { Ok(x) => x, Err(_) => return 3 };
        if tok.with_truncation(None).is_err() { return 3; }
        tok.with_padding(None);
        unsafe { *out = Box::into_raw(Box::new(tok)); }
        0
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tok_load_json(content: *const u8, len: usize, out: *mut *mut Tokenizer) -> i32 {
    boundary(|| {
        if out.is_null() { return 1; }
        unsafe { *out = std::ptr::null_mut(); }
        let content = match unsafe { utf8(content, len) } { Ok(x) => x, Err(e) => return e };
        tokenizers::utils::parallelism::set_parallelism(false);
        let mut tok = match parse_tokenizer(content) { Ok(x) => x, Err(_) => return 3 };
        if tok.with_truncation(None).is_err() { return 3; }
        tok.with_padding(None);
        unsafe { *out = Box::into_raw(Box::new(tok)); }
        0
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_matches_generic(model: &str) {
        let content = format!(r#"{{"version":"1.0","truncation":null,"padding":null,"added_tokens":[],"normalizer":null,"pre_tokenizer":null,"post_processor":null,"decoder":null,"model":{model}}}"#);
        let parsed = parse_tokenizer(&content).unwrap();
        let generic = Tokenizer::from_str(&content).unwrap();
        assert_eq!(parsed.get_vocab(true), generic.get_vocab(true));
        for text in ["", "a", "ab", "é", "你好", "👩🏽‍💻", "a b", "<unk>"] {
            assert_eq!(parsed.encode(text, true).unwrap().get_ids(),
                generic.encode(text, true).unwrap().get_ids());
        }
    }

    #[test]
    fn typed_bpe_preserves_vocabulary_and_token_ids() {
        assert_matches_generic(r#"{"type":"BPE","unk_token":"<unk>","vocab":{"<unk>":0,"a":1,"b":2,"ab":3,"é":4},"merges":[["a","b"]]}"#);
    }

    #[test]
    fn other_model_types_keep_the_generic_loader() {
        assert_matches_generic(r#"{"type":"WordLevel","unk_token":"<unk>","vocab":{"<unk>":0,"a":1,"ab":2,"é":3}}"#);
    }

    #[test]
    fn invalid_tokenizer_is_rejected() {
        assert!(parse_tokenizer("{}").is_err());
        assert!(parse_tokenizer("not JSON").is_err());
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tok_encode(handle: *mut Tokenizer, text: *const u8, len: usize,
    add: i32, split: i32, out: *mut u32, cap: usize, out_len: *mut usize) -> i32 {
    boundary(|| {
        if handle.is_null() || out_len.is_null() || cap > isize::MAX as usize / 4
            || (out.is_null() && cap != 0) || !(0..=1).contains(&add) || !(0..=1).contains(&split) { return 1; }
        unsafe { *out_len = 0; }
        let text = match unsafe { utf8(text, len) } { Ok(x) => x, Err(e) => return e };
        let tok = unsafe { &mut *handle };
        tok.set_encode_special_tokens(split != 0);
        let encoded = match tok.encode(text, add != 0) { Ok(x) => x, Err(_) => return 3 };
        let ids = encoded.get_ids();
        unsafe { *out_len = ids.len(); }
        if cap < ids.len() { return 2; }
        if !ids.is_empty() { unsafe { std::ptr::copy_nonoverlapping(ids.as_ptr(), out, ids.len()); } }
        0
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tok_free(handle: *mut Tokenizer) -> i32 {
    boundary(|| {
        if !handle.is_null() { unsafe { drop(Box::from_raw(handle)); } }
        0
    })
}
