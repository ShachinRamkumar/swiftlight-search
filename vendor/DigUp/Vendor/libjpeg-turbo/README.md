# Vendored libjpeg-turbo 3.2.0

Copied offline from `/opt/homebrew/Cellar/jpeg-turbo/3.2.0/`. Only the arm64 static libjpeg archive is linked. No Homebrew runtime paths or dylibs are used. License terms are retained in `share/doc/libjpeg-turbo/LICENSE.md` and `README.ijg`.

Pillow 12.3.0 uses libjpeg-turbo 3.1.4.1 with the JPEG 6.2 ABI. This archive uses the JPEG 8 ABI; the wrapper compiles against the matching vendored headers. Decode parity is checked against Pillow, independent of ABI.

| Copied file | SHA-256 |
| --- | --- |
| `lib/libjpeg.a` | `f6379035aa1961db573f5b429d09f32ca90826d3becd5cfc8620575a24e4f1c4` |
| `include/jpeglib.h` | `dc3e8220f34b7e9f9e48620f5cb8dc070834feb3214bb12bbad78478ebb29e60` |
| `include/jconfig.h` | `84fa4f9f583fea8015bab490024f8dd942f5ed1d58855633d362c9c601ac06f6` |
| `include/jmorecfg.h` | `b86b4abf452d39b737cb45503591e04e9ca38c5fd0e90d429387d0464005a28b` |
| `include/jerror.h` | `b4e8697b3d2e06071f23a3f32c50f62f782cdee03f7b82e4595eed5e33d67288` |
| `share/doc/libjpeg-turbo/LICENSE.md` | `ba6bceebcba0fdd35488477c2cca8c4632ce82c74dbfbc87d886ce6fc4433579` |
| `share/doc/libjpeg-turbo/README.ijg` | `75815e3bf6484201a3c3d17a1bbf10f2e8e3237f84df10a2357ea896db2a81d6` |
