use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::Mutex,
};
use tauri::{AppHandle, Manager, State};

const SAMPLE_SCENE: &str = include_str!("../../../../examples/sample-scene.json");

#[derive(Default)]
struct AppState {
    scene_path: Mutex<Option<PathBuf>>,
}

#[derive(Deserialize)]
struct RenderRequest {
    repo: String,
    base: String,
    target: String,
    timeline: bool,
}

#[derive(Serialize)]
struct CommitOption {
    hash: String,
    short_hash: String,
    date: String,
    subject: String,
    label: String,
}

#[tauri::command]
fn choose_repository() -> Option<String> {
    rfd::FileDialog::new()
        .set_title("Choose Git Repository")
        .pick_folder()
        .map(|path| path.to_string_lossy().into_owned())
}

#[tauri::command]
fn list_commits(repo: String) -> Result<Vec<CommitOption>, String> {
    let repo = validate_repo(repo.trim())?;
    let output = Command::new("git")
        .current_dir(&repo)
        .args([
            "log",
            "--max-count=300",
            "--date=short",
            "--pretty=format:%H%x09%h%x09%cs%x09%s",
        ])
        .output()
        .map_err(|error| format!("Could not run git log: {error}"))?;

    if !output.status.success() {
        return Err(command_error("git log", &output));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let commits = stdout
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(4, '\t');
            let hash = parts.next()?.to_string();
            let short_hash = parts.next()?.to_string();
            let date = parts.next()?.to_string();
            let subject = parts.next().unwrap_or("").to_string();
            let label = format!("{short_hash}  {date}  {subject}");
            Some(CommitOption {
                hash,
                short_hash,
                date,
                subject,
                label,
            })
        })
        .collect::<Vec<_>>();

    if commits.len() < 2 {
        Err("Repository needs at least two commits to compare.".to_string())
    } else {
        Ok(commits)
    }
}

#[tauri::command]
fn load_scene(state: State<'_, AppState>) -> Result<Value, String> {
    let scene_path = state
        .scene_path
        .lock()
        .map_err(|_| "scene state lock was poisoned".to_string())?
        .clone();

    match scene_path {
        Some(path) => read_json_file(&path),
        None => serde_json::from_str(SAMPLE_SCENE).map_err(|error| error.to_string()),
    }
}

#[tauri::command]
fn render_repository(
    app: AppHandle,
    state: State<'_, AppState>,
    request: RenderRequest,
) -> Result<Value, String> {
    let repo = validate_repo(request.repo.trim())?;
    validate_base_target(&repo, request.base.trim(), request.target.trim())?;

    let cli = find_backend_cli(&app)?;
    let cache_dir = app
        .path()
        .app_cache_dir()
        .map_err(|error| format!("Could not resolve app cache directory: {error}"))?;
    fs::create_dir_all(&cache_dir)
        .map_err(|error| format!("Could not create cache directory: {error}"))?;
    let out_path = cache_dir.join("scene.json");

    let mut command = Command::new(&cli);
    command
        .arg("render-repo")
        .arg("--repo")
        .arg(&repo)
        .arg("--base")
        .arg(request.base.trim())
        .arg("--target")
        .arg(request.target.trim())
        .arg("--out")
        .arg(&out_path);

    if request.timeline {
        command.arg("--timeline");
    }

    let output = command.output().map_err(|error| {
        format!(
            "Could not run backend executable {}: {error}",
            cli.display()
        )
    })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let detail = if !stderr.is_empty() { stderr } else { stdout };
        return Err(if detail.is_empty() {
            format!("Backend exited with {}", output.status)
        } else {
            detail
        });
    }

    let json = read_json_file(&out_path)?;
    *state
        .scene_path
        .lock()
        .map_err(|_| "scene state lock was poisoned".to_string())? = Some(out_path);
    Ok(json)
}

fn validate_repo(repo: &str) -> Result<PathBuf, String> {
    let repo = PathBuf::from(repo);
    let output = Command::new("git")
        .current_dir(&repo)
        .args(["rev-parse", "--is-inside-work-tree"])
        .output()
        .map_err(|error| format!("Could not inspect repository: {error}"))?;
    let is_work_tree =
        output.status.success() && String::from_utf8_lossy(&output.stdout).trim() == "true";
    if !is_work_tree {
        return Err(format!("Not a git repository: {}", repo.display()));
    }
    Ok(repo)
}

fn validate_base_target(repo: &Path, base: &str, target: &str) -> Result<(), String> {
    if base == target {
        return Err("Base and target must be different commits.".to_string());
    }

    let output = Command::new("git")
        .current_dir(repo)
        .args(["merge-base", "--is-ancestor", base, target])
        .output()
        .map_err(|error| format!("Could not validate commit order: {error}"))?;

    if output.status.success() {
        Ok(())
    } else {
        Err("Base must be older than target in the selected repository history.".to_string())
    }
}

fn command_error(command: &str, output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        format!("{command} exited with {}", output.status)
    }
}

fn read_json_file(path: &Path) -> Result<Value, String> {
    let text = fs::read_to_string(path)
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    serde_json::from_str(&text)
        .map_err(|error| format!("Invalid JSON in {}: {error}", path.display()))
}

fn find_backend_cli(app: &AppHandle) -> Result<PathBuf, String> {
    if let Ok(path) = std::env::var("GVD_CLI") {
        let path = PathBuf::from(path);
        if path.exists() {
            return Ok(path);
        }
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut candidates = vec![
        manifest_dir.join("resources/git-visualization-diff"),
        manifest_dir.join("binaries/git-visualization-diff-aarch64-apple-darwin"),
        manifest_dir.join("binaries/git-visualization-diff-x86_64-apple-darwin"),
        manifest_dir.join("../../../_build/default/bin/main.exe"),
    ];

    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            candidates.push(exe_dir.join("git-visualization-diff"));
            candidates.push(exe_dir.join("git-visualization-diff-aarch64-apple-darwin"));
            candidates.push(exe_dir.join("git-visualization-diff-x86_64-apple-darwin"));
        }
    }

    if let Ok(resource_dir) = app.path().resource_dir() {
        candidates.push(resource_dir.join("git-visualization-diff"));
        candidates.push(resource_dir.join("resources/git-visualization-diff"));
    }

    candidates
        .into_iter()
        .find(|path| path.exists())
        .ok_or_else(|| {
            "Could not find git-visualization-diff backend. Run npm run prepare-backend."
                .to_string()
        })
}

fn main() {
    tauri::Builder::default()
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            choose_repository,
            list_commits,
            load_scene,
            render_repository
        ])
        .run(tauri::generate_context!())
        .expect("error while running Tauri application");
}
