# DigUp HF tokenizer bridge

Run `sh Vendor/hf-tokenizer/build-offline.sh` from the package, then
`swift build --jobs 2 --disable-automatic-resolution --product coreai-check`.
The script changes to the crate directory so Cargo reads `.cargo/config.toml`.
The crate sources are in `crates/`; no build needs a registry or network.

The static library is `target/release/libdigup_tokenizer.a`. `CTokenizer` links it.
Each tokenizer handle has one caller at a time. The C header specifies ownership,
byte lengths and error codes. Swift owns truncation and preserves BOS and EOS.
The Rust boundary catches unwinding panics. It cannot validate arbitrary forged
pointers; callers must honor the header's pointer and ownership contract.

Python reference package version: 0.23.3. The Rust release pinned here is 0.23.2.
crates.io has no 0.23.3 release. The crate records upstream source commit
88a4498ad4ea1a9487b0a9b0ff881383fd5a06a3. The installed Python wheel does not
record that commit, so upstream correspondence is unconfirmed. Exact parity
against that Python wheel is a separate required gate, recorded in P3a results.

Default crate features are disabled. `fancy-regex` supplies the required regex
backend without Oniguruma. Gemma uses BPE, string replacement and splitting,
byte fallback and template BOS/EOS. There is no HTTP feature, progress UI or C++
trainer feature. `esaxx-rs` is a transitive pure Rust dependency with its C++
feature disabled. All 77 locked packages, including non-macOS packages, are
listed with registry checksums in `vendored-crates.json`.

License files shipped by dependencies are retained in `crates/` and copied to
`licenses/`. r-efi is a non-macOS transitive dependency. Its package omits a
standalone license file; its SPDX expression, AUTHORS and licensing declaration
are preserved with an Apache-2.0 license text, chosen from its offered licenses.
