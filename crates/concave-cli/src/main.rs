use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use concave_codegen::write_generated_files;
use concave_core::AppManifest;
use notify::{EventKind, RecursiveMode, Watcher};

#[derive(Debug, Parser)]
#[command(
    name = "concave",
    version,
    about = "Concave — Convex-style reactive platform CLI for Roc"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Compile the Roc backend, run `--introspect`, and generate typed client bindings (`api.ts`, `dataModel.ts`).
    Codegen {
        /// Path to the Roc application entry file (e.g., `backend/main.roc`).
        #[arg(long, default_value = "backend/main.roc")]
        entry: PathBuf,
        /// Output directory for generated TypeScript files.
        #[arg(long, default_value = "frontend/src/_generated")]
        out: PathBuf,
        /// Roc optimization mode (`dev` for fast iteration, `speed` for LLVM).
        #[arg(long, default_value = "dev")]
        opt: String,
    },

    /// Build a standalone native Concave server executable.
    Build {
        #[arg(long, default_value = "backend/main.roc")]
        entry: PathBuf,
        #[arg(long, short, default_value = ".concave/server")]
        output: PathBuf,
        #[arg(long, default_value = "speed")]
        opt: String,
    },

    /// Watch `.roc` files, rebuild, regenerate typed client bindings, and supervise the live server.
    Dev {
        #[arg(long, default_value = "backend/main.roc")]
        entry: PathBuf,
        #[arg(long, default_value = "frontend/src/_generated")]
        out: PathBuf,
        #[arg(long, default_value = "127.0.0.1")]
        host: String,
        #[arg(long, default_value_t = 3210)]
        port: u16,
        #[arg(long, default_value = ".concave/dev.db")]
        db: PathBuf,
        #[arg(long)]
        database_url: Option<String>,
        #[arg(long, default_value = "default")]
        deployment_id: String,
        #[arg(long)]
        static_dir: Option<PathBuf>,
        #[arg(long, default_value = "dev")]
        opt: String,
    },

    /// Scaffold a new external Concave Roc application.
    Init {
        /// Target directory to initialize.
        dir: PathBuf,
        /// Path or URL to the Concave platform `main.roc`.
        #[arg(long, default_value = "./platform/main.roc")]
        platform: String,
        /// Path or URL to `concave-sdk/main.roc`.
        #[arg(long, default_value = "./packages/concave-sdk/main.roc")]
        sdk: String,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Codegen { entry, out, opt } => {
            let bin = default_dev_bin(&entry);
            build_roc_app(&entry, &bin, &opt)?;
            let manifest = introspect_binary(&bin)?;
            write_generated_files(&manifest, &out)
                .with_context(|| format!("failed to write generated files to {}", out.display()))?;
            println!(
                "Generated {} and {} ({} tables, {} components, {} functions)",
                out.join("dataModel.ts").display(),
                out.join("api.ts").display(),
                manifest.tables.len(),
                manifest.components.len(),
                manifest.functions.len()
            );
        }
        Commands::Build { entry, output, opt } => {
            build_roc_app(&entry, &output, &opt)?;
            println!("Built standalone Concave server binary: {}", output.display());
        }
        Commands::Dev {
            entry,
            out,
            host,
            port,
            db,
            database_url,
            deployment_id,
            static_dir,
            opt,
        } => {
            run_dev_loop(DevOptions {
                entry,
                out,
                host,
                port,
                db,
                database_url,
                deployment_id,
                static_dir,
                opt,
            })?;
        }
        Commands::Init { dir, platform, sdk } => {
            scaffold_app(&dir, &platform, &sdk)?;
            println!("Initialized Concave app in {}", dir.display());
        }
    }
    Ok(())
}

fn default_dev_bin(entry: &Path) -> PathBuf {
    let base = entry
        .parent()
        .and_then(|p| p.parent())
        .unwrap_or_else(|| Path::new("."));
    base.join(".concave").join("dev-server")
}

fn build_roc_app(entry: &Path, output: &Path, opt: &str) -> Result<()> {
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    let status = Command::new("roc")
        .arg("build")
        .arg(format!("--opt={opt}"))
        .arg(format!("--output={}", output.display()))
        .arg(entry)
        .status()
        .context("failed to execute `roc build` (is Roc 0.1.0_RC1 on PATH?)")?;
    if !status.success() {
        bail!("`roc build` failed with exit status {status}");
    }
    Ok(())
}

fn introspect_binary(bin: &Path) -> Result<AppManifest> {
    let output = Command::new(bin)
        .arg("--introspect")
        .output()
        .with_context(|| format!("failed to run `{} --introspect`", bin.display()))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("`--introspect` failed: {stderr}");
    }
    let stdout = String::from_utf8(output.stdout).context("non-UTF8 output from `--introspect`")?;
    let manifest: AppManifest = serde_json::from_str(stdout.trim())
        .with_context(|| format!("invalid manifest JSON from `--introspect`:\n{stdout}"))?;
    Ok(manifest)
}

struct DevOptions {
    entry: PathBuf,
    out: PathBuf,
    host: String,
    port: u16,
    db: PathBuf,
    database_url: Option<String>,
    deployment_id: String,
    static_dir: Option<PathBuf>,
    opt: String,
}

fn spawn_server(bin: &Path, opts: &DevOptions) -> Result<Child> {
    let mut cmd = Command::new(bin);
    cmd.arg("--serve")
        .arg("--host")
        .arg(&opts.host)
        .arg("--port")
        .arg(opts.port.to_string())
        .arg("--db")
        .arg(&opts.db)
        .arg("--deployment-id")
        .arg(&opts.deployment_id)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());

    if let Some(url) = &opts.database_url {
        cmd.arg("--database-url").arg(url);
    }
    if let Some(dir) = &opts.static_dir {
        cmd.arg("--static-dir").arg(dir);
    }

    cmd.spawn()
        .with_context(|| format!("failed to start server {}", bin.display()))
}

fn run_dev_loop(opts: DevOptions) -> Result<()> {
    let bin = default_dev_bin(&opts.entry);
    let watch_dir = opts
        .entry
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .to_path_buf();

    let (tx, rx) = mpsc::channel();
    let mut watcher = notify::recommended_watcher(move |res| {
        if let Ok(event) = res {
            let _ = tx.send(event);
        }
    })?;
    watcher.watch(&watch_dir, RecursiveMode::Recursive)?;

    let mut child: Option<Child> = None;

    let rebuild_and_start = |child: &mut Option<Child>| -> Result<()> {
        if let Some(mut running) = child.take() {
            let _ = running.kill();
            let _ = running.wait();
        }
        println!("[concave dev] building {}...", opts.entry.display());
        build_roc_app(&opts.entry, &bin, &opts.opt)?;
        let manifest = introspect_binary(&bin)?;
        write_generated_files(&manifest, &opts.out)?;
        println!(
            "[concave dev] codegen updated ({}) — starting server on http://{}:{}",
            opts.out.display(),
            opts.host,
            opts.port
        );
        *child = Some(spawn_server(&bin, &opts)?);
        Ok(())
    };

    if let Err(e) = rebuild_and_start(&mut child) {
        eprintln!("[concave dev] initial build failed: {e:#}");
    }

    let mut last_rebuild = Instant::now();
    loop {
        match rx.recv_timeout(Duration::from_millis(250)) {
            Ok(event) => {
                let is_roc_change = matches!(
                    event.kind,
                    EventKind::Modify(_) | EventKind::Create(_) | EventKind::Remove(_)
                ) && event
                    .paths
                    .iter()
                    .any(|p| p.extension().is_some_and(|e| e == "roc"));

                if is_roc_change && last_rebuild.elapsed() > Duration::from_millis(350) {
                    last_rebuild = Instant::now();
                    if let Err(e) = rebuild_and_start(&mut child) {
                        eprintln!("[concave dev] rebuild failed (watching for fixes): {e:#}");
                    }
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    if let Some(mut running) = child.take() {
        let _ = running.kill();
        let _ = running.wait();
    }
    Ok(())
}

fn scaffold_app(dir: &Path, platform: &str, sdk: &str) -> Result<()> {
    let backend = dir.join("backend");
    fs::create_dir_all(&backend)?;

    let main_roc = format!(
        r#"app [concave_app] {{
    pf: platform "{platform}",
    sdk: "{sdk}",
}}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Schema
import sdk.Table

NoteDoc : {{
    id : Str,
    created_at : I64,
    text : Str,
}}

notes_schema : Schema
notes_schema = Schema.record([
    Schema.field("text", Schema.str),
])

notes_table : Table(NoteDoc)
notes_table = Table.define("notes", notes_schema)

list_notes! : Ctx.QueryCtx, {{}} => Try(List(NoteDoc), Str)
list_notes! = |ctx, _|
    Db.query(notes_table) |> Db.desc() |> Db.collect!(ctx.db)

add_note! : Ctx.MutationCtx, {{ text : Str }} => Try(Str, Str)
add_note! = |ctx, args|
    Db.insert!(ctx.db, notes_table, {{ text: args.text }})

concave_app : () -> App
concave_app = ||
    App.new("my-concave-app")
    |> App.table(notes_table)
    |> App.query("notes.list", Schema.record([]), Schema.list(Table.doc_schema(notes_table)), list_notes!)
    |> App.mutation("notes.add", Schema.record([Schema.field("text", Schema.str)]), Schema.id("notes"), add_note!)
"#
    );

    fs::write(backend.join("main.roc"), main_roc)?;
    Ok(())
}
