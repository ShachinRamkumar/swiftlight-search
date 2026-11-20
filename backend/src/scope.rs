use serde::Deserialize;
use std::{
    fs,
    path::{Component, Path, PathBuf},
    sync::OnceLock,
};

#[derive(Clone, Deserialize)]
pub struct Config {
    pub home: PathBuf,
    pub helper: PathBuf,
    pub index: PathBuf,
    #[serde(default = "yes")]
    pub auto_index: bool,
    #[serde(default)]
    pub excluded: Vec<PathBuf>,
    #[serde(default)]
    pub embedding: Option<EmbeddingConfig>,
    #[serde(default)]
    pub semantic_modalities: Option<Vec<SemanticModality>>,
    /// `file_roots` and `app_roots`, built once: name search checks every hit against them.
    #[serde(skip)]
    pub root_cache: OnceLock<(Vec<PathBuf>, Vec<PathBuf>)>,
}
#[derive(Clone, Copy, Default, Deserialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum EmbeddingEngine {
    #[default]
    Coreai,
}

#[derive(Clone, Copy, Deserialize, Debug)]
#[serde(rename_all = "lowercase")]
pub enum SemanticModality {
    Text,
    Image,
    Audio,
    Video,
}
impl SemanticModality {
    pub fn sql(self) -> &'static str {
        match self {
            Self::Text => "'text'",
            Self::Image => "'image'",
            Self::Audio => "'audio'",
            Self::Video => "'video'",
        }
    }
}

#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ImageVectors {
    #[default]
    Legacy,
    Coreai,
}

#[derive(Clone, Default, Deserialize)]
pub struct EmbeddingConfig {
    #[serde(default)]
    pub engine: EmbeddingEngine,
    pub runtime: Option<PathBuf>,
    pub model_key: Option<String>,
    #[serde(default)]
    pub image_vectors: ImageVectors,
    #[serde(default)]
    pub audio_vectors: ImageVectors,
    #[serde(default)]
    pub video_clip_vectors: bool,
    #[serde(default)]
    pub index_audio: bool,
    #[serde(default)]
    pub index_video: bool,
    // Verification only: partial shadow coverage cannot be enabled for production search.
    #[serde(default)]
    pub allow_incomplete: bool,
    #[serde(default)]
    pub pause_indexing_while_searching: bool,
}

fn yes() -> bool {
    true
}

impl Config {
    pub fn load() -> Result<Self, String> {
        let args: Vec<_> = std::env::args().collect();
        if let Some(i) = args.iter().position(|s| s == "--config") {
            let path = args.get(i + 1).ok_or("--config needs a path")?;
            return serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string());
        }
        let home = PathBuf::from(std::env::var("HOME").map_err(|_| "HOME missing")?);
        let support = home.join("Library/Application Support/Swiftlight");
        let installed_config = support.join("config.json");
        if installed_config.exists() {
            let mut config: Self =
                serde_json::from_slice(&fs::read(installed_config).map_err(|e| e.to_string())?)
                    .map_err(|e| e.to_string())?;
            let legacy = home.join("Library/Application Support/SpotlightFSearch");
            if let Ok(relative) = config.index.strip_prefix(&legacy) {
                config.index = support.join(relative);
            }
            if let Some(embedding) = &mut config.embedding
                && let Some(runtime) = &mut embedding.runtime
                && let Ok(relative) = runtime.strip_prefix(&legacy)
            {
                *runtime = support.join(relative);
            }
            if config
                .helper
                .ends_with("Spotlight FSearch.app/Contents/Helpers/digup")
            {
                config.helper = std::env::current_exe()
                    .map_err(|e| e.to_string())?
                    .parent()
                    .ok_or("no executable directory")?
                    .join("Swiftlight Indexer");
            }
            return Ok(config);
        }
        let helper = std::env::current_exe()
            .map_err(|e| e.to_string())?
            .parent()
            .ok_or("no executable directory")?
            .join("Swiftlight Indexer");
        let bundled_exclusions = helper
            .parent()
            .unwrap()
            .join("../Resources/scope-exclusions.json");
        let excluded = if bundled_exclusions.exists() {
            serde_json::from_slice(&fs::read(bundled_exclusions).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?
        } else {
            vec![]
        };
        Ok(Self {
            home,
            helper,
            index: support.join("Index"),
            auto_index: true,
            embedding: Some(EmbeddingConfig {
                model_key: Some("coreai-eg2-v1".into()),
                image_vectors: ImageVectors::Coreai,
                ..EmbeddingConfig::default()
            }),
            semantic_modalities: None,
            excluded,
            root_cache: OnceLock::new(),
        })
    }
    pub fn coreai(&self) -> Option<&EmbeddingConfig> {
        self.embedding
            .as_ref()
            .filter(|e| e.engine == EmbeddingEngine::Coreai)
    }
    pub fn coreai_runtime(&self) -> PathBuf {
        self.coreai()
            .and_then(|e| e.runtime.clone())
            .unwrap_or_else(|| {
                self.home
                    .join("Library/Application Support/Swiftlight/CoreAI/coreai-eg2-v1")
            })
    }
    pub fn coreai_audio_installed(&self) -> bool {
        let runtime = self.coreai_runtime();
        let Ok(bytes) = std::fs::read(runtime.join("manifest.json")) else {
            return false;
        };
        let Ok(manifest) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            return false;
        };
        let source_available = if manifest["storage_layout"] == "single-model-v2" {
            manifest["production_assets"]
                .as_array()
                .is_some_and(|assets| {
                    assets.len() == 1 && assets[0]["path"] == "EmbeddingGemma2.aimodel"
                })
        } else {
            runtime.join("audio.aimodel/main.mlirb").is_file()
        };
        manifest
            .get("audio_identity")
            .is_some_and(|v| v.is_object())
            && source_available
            && runtime.join("audio-host/identity.json").is_file()
    }
    pub fn models_installed(&self) -> bool {
        self.coreai().is_some() && self.coreai_runtime().join("manifest.json").is_file()
    }
    pub fn cooperative_pause(&self) -> bool {
        self.embedding
            .as_ref()
            .is_some_and(|e| e.pause_indexing_while_searching)
    }
    fn roots(&self) -> &(Vec<PathBuf>, Vec<PathBuf>) {
        self.root_cache.get_or_init(|| {
            (
                ["Documents", "Desktop", "Downloads"]
                    .iter()
                    .map(|p| self.home.join(p))
                    .collect(),
                vec![
                    "/Applications".into(),
                    "/System/Applications".into(),
                    "/System/Library/CoreServices/Applications".into(),
                    self.home.join("Applications"),
                ],
            )
        })
    }
    pub fn file_roots(&self) -> &[PathBuf] {
        &self.roots().0
    }
    pub fn app_roots(&self) -> &[PathBuf] {
        &self.roots().1
    }
    pub fn semantic_lexical(&self, path: &Path) -> bool {
        path.starts_with(&self.home)
            && safe_components(path.strip_prefix(&self.home).unwrap_or(path))
            && ![
                "Library",
                "Music/Music",
                "Movies/TV",
                "Pictures/Photo Booth Library",
            ]
            .iter()
            .any(|relative| path.starts_with(self.home.join(relative)))
            && !self.excluded.iter().any(|p| path.starts_with(p))
    }
    pub fn semantic_allowed(&self, path: &Path) -> bool {
        self.semantic_lexical(path)
            && visible(path, &self.home)
            && fs::canonicalize(path).is_ok_and(|real| self.semantic_lexical(&real))
    }
    pub fn fast_allowed(&self, path: &Path) -> bool {
        if self.app_roots().iter().any(|root| path.starts_with(root)) {
            // System app aliases can resolve into the signed cryptex.
            return path.extension().is_some_and(|s| s == "app")
                && path.exists()
                && !path.components().any(
                    |c| matches!(c, Component::Normal(n) if n.to_string_lossy().starts_with('.')),
                )
                && !path
                    .ancestors()
                    .skip(1)
                    .any(|p| p.extension().is_some_and(|s| s == "app"));
        }
        self.file_roots().iter().any(|root| {
            path.starts_with(root)
                && safe_components(path.strip_prefix(root).unwrap_or(path))
                && visible(path, root)
                && fs::canonicalize(path)
                    .is_ok_and(|real| real.starts_with(root) && self.semantic_lexical(&real))
        })
    }
    pub fn fast_candidate(&self, path: &Path) -> bool {
        if self.app_roots().iter().any(|root| path.starts_with(root)) {
            return path.extension().is_some_and(|s| s == "app")
                && !path.components().any(
                    |c| matches!(c, Component::Normal(n) if n.to_string_lossy().starts_with('.')),
                )
                && !path
                    .ancestors()
                    .skip(1)
                    .any(|p| p.extension().is_some_and(|s| s == "app"));
        }
        self.file_roots().iter().any(|root| {
            path.starts_with(root) && safe_components(path.strip_prefix(root).unwrap_or(path))
        })
    }
}

pub fn secret(name: &str) -> bool {
    let lower = name.to_lowercase();
    let ext = lower.rsplit('.').next().unwrap_or("");
    [
        "pem",
        "key",
        "p12",
        "pfx",
        "keystore",
        "jks",
        "ppk",
        "kdbx",
        "gpg",
        "asc",
        "crt",
        "cer",
        "der",
        "p8",
        "mobileprovision",
    ]
    .contains(&ext)
        || [
            "id_rsa",
            "id_dsa",
            "id_ecdsa",
            "id_ed25519",
            ".env",
            "secret",
            "credential",
            ".netrc",
            ".npmrc",
            ".pypirc",
            "htpasswd",
        ]
        .iter()
        .any(|p| lower.starts_with(p))
}
fn safe_components(path: &Path) -> bool {
    path.components().all(|component| match component {
        Component::Normal(n) => {
            let n = n.to_string_lossy();
            !n.starts_with('.')
                && !n.ends_with(".noindex")
                && !secret(&n)
                && ![
                    "node_modules",
                    "bower_components",
                    "venv",
                    "site-packages",
                    "__pycache__",
                    "DerivedData",
                    "Pods",
                    "Carthage",
                    "build",
                    "Build",
                    "dist",
                    "target",
                    "vendor",
                    "coverage",
                    "out",
                ]
                .contains(&n.as_ref())
                && ![
                    "app",
                    "framework",
                    "bundle",
                    "photoslibrary",
                    "photolibrary",
                    "musiclibrary",
                    "migratedphotolibrary",
                    "aplibrary",
                    "tvlibrary",
                    "imovielibrary",
                    "theater",
                    "lrlibrary",
                    "xcodeproj",
                    "xcworkspace",
                ]
                .contains(
                    &Path::new(n.as_ref())
                        .extension()
                        .and_then(|s| s.to_str())
                        .unwrap_or("")
                        .to_ascii_lowercase()
                        .as_str(),
                )
        }
        Component::CurDir | Component::ParentDir => false,
        _ => true,
    })
}
fn visible(path: &Path, root: &Path) -> bool {
    for p in path.ancestors().take_while(|p| p.starts_with(root)) {
        let Ok(m) = fs::symlink_metadata(p) else {
            return false;
        };
        #[cfg(target_os = "macos")]
        {
            use std::os::macos::fs::MetadataExt;
            if m.st_flags() & 0x8000 != 0 {
                return false;
            }
            use std::os::unix::ffi::OsStrExt;
            if let Ok(c) = std::ffi::CString::new(p.as_os_str().as_bytes()) {
                let mut finder = [0u8; 32];
                let size = unsafe {
                    libc::getxattr(
                        c.as_ptr(),
                        c"com.apple.FinderInfo".as_ptr(),
                        finder.as_mut_ptr().cast(),
                        32,
                        0,
                        0,
                    )
                };
                if size == 32 && u16::from_be_bytes([finder[8], finder[9]]) & 0x4000 != 0 {
                    return false;
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = m;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn embedding_is_opt_in_and_config_rejects_unknown_variants() {
        let base = serde_json::json!({"home":"/sample", "helper":"/sample/digup",
            "index":"/sample/unit-index", "models":"/sample/models", "auto_index":false});
        let legacy: Config = serde_json::from_value(base.clone()).unwrap();
        assert!(legacy.coreai().is_none());
        assert!(!legacy.cooperative_pause());
        assert!(legacy.semantic_modalities.is_none());
        let mut raw = base.clone();
        raw["embedding"] = serde_json::json!({"engine":"llama"});
        assert!(serde_json::from_value::<Config>(raw.clone()).is_err());
        raw["embedding"] = serde_json::json!({"engine":"coreai", "runtime":"/runtime", "model_key":"coreai-eg2-text-v1", "pause_indexing_while_searching":true});
        raw["semantic_modalities"] = serde_json::json!(["text"]);
        let coreai: Config = serde_json::from_value(raw.clone()).unwrap();
        assert!(coreai.coreai().is_some());
        assert!(coreai.cooperative_pause());
        assert!(!coreai.coreai().unwrap().allow_incomplete);
        raw["embedding"]["engine"] = serde_json::json!("other");
        assert!(serde_json::from_value::<Config>(raw).is_err());
        let mut raw = base;
        raw["semantic_modalities"] = serde_json::json!(["typo"]);
        assert!(serde_json::from_value::<Config>(raw).is_err());
    }

    #[test]
    fn descendants_cannot_reenable_hidden_or_generated_content() {
        for p in [
            "Notes/.private/a.txt",
            "Notes/node_modules/readme.md",
            "Library/x",
            "x/../y",
            "app.app/a",
            "credentials.txt",
        ] {
            let c = Config {
                home: "/tmp/home".into(),
                helper: "x".into(),
                index: "x".into(),
                auto_index: false,
                embedding: None,
                semantic_modalities: None,
                excluded: vec![],
                root_cache: OnceLock::new(),
            };
            assert!(
                !c.semantic_lexical(&PathBuf::from("/tmp/home").join(p)),
                "{p}"
            );
        }
        assert!(safe_components(Path::new("Project/notes.md")));
    }
    #[test]
    fn visible_symlink_cannot_escape_into_library() {
        use std::os::unix::fs::symlink;
        let home =
            std::env::temp_dir().join(format!("spotlight-scope-test-{}", std::process::id()));
        fs::create_dir_all(home.join("Documents")).unwrap();
        fs::create_dir_all(home.join("Library")).unwrap();
        fs::write(home.join("Library/private.txt"), b"synthetic").unwrap();
        let link = home.join("Documents/visible.txt");
        symlink(home.join("Library/private.txt"), &link).unwrap();
        let c = Config {
            home: home.clone(),
            helper: "x".into(),
            index: "x".into(),
            auto_index: false,
            embedding: None,
            semantic_modalities: None,
            excluded: vec![],
            root_cache: OnceLock::new(),
        };
        assert!(!c.fast_allowed(&link));
        assert!(!c.semantic_allowed(&link));
        fs::remove_dir_all(home).unwrap();
    }
}
