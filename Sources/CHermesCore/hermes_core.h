#ifndef HERMES_CORE_H
#define HERMES_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Owned by Rust; release with hermes_buffer_free. When ok is false, the bytes are a UTF-8 error message.
typedef struct {
    uint8_t *ptr;
    size_t len;
    bool ok;
} HermesBuffer;

HermesBuffer hermes_decode_file(const uint8_t *ptr, size_t len);
HermesBuffer hermes_encode_file(const uint8_t *ptr, size_t len);
HermesBuffer hermes_plain_text(const uint8_t *ptr, size_t len);
HermesBuffer hermes_decode_markdown(const uint8_t *ptr, size_t len);
HermesBuffer hermes_encode_markdown(const uint8_t *ptr, size_t len);
uint64_t hermes_word_count(const uint8_t *ptr, size_t len);
void hermes_buffer_free(HermesBuffer buffer);

#endif
