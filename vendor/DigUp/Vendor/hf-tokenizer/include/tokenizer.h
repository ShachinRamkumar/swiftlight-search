#ifndef DIGUP_TOKENIZER_H
#define DIGUP_TOKENIZER_H
#include <stddef.h>
#include <stdint.h>
/* Single caller per handle. Bytes are borrowed for the duration of the call.
   Handles must come from tok_load; tok_free consumes the handle exactly once.
   0 success, 1 invalid argument/UTF-8, 2 insufficient capacity (out_len set),
   3 load/encode error, 255 caught Rust panic. No partial ID writes. */
int32_t tok_load(const uint8_t *path, size_t path_len, void **out_handle);
int32_t tok_load_json(const uint8_t *content, size_t len, void **out_handle);
int32_t tok_encode(void *handle, const uint8_t *utf8, size_t utf8_len,
                   int32_t add_special_tokens, int32_t split_special_tokens,
                   uint32_t *out_ids, size_t out_cap, size_t *out_len);
int32_t tok_free(void *handle);
#endif
