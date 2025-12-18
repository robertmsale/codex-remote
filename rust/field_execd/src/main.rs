use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::env;
use std::fs;
use std::hash::{Hash, Hasher};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use async_ssh2_tokio::Error as SshError;
use rand_core::{OsRng, RngCore};
use russh::keys;
use serde::{Deserialize, Serialize};
use ssh_key::{Algorithm, LineEnding, PrivateKey};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;
use tokio::time::timeout;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
enum PoolAuthKind {
    Key,
    Password,
}

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
struct PoolKey {
    host: String,
    port: u16,
    username: String,
    auth_kind: PoolAuthKind,
    secret_hash: u64,
}

#[derive(Clone)]
struct SshConnectionPool {
    clients: Arc<Mutex<HashMap<PoolKey, async_ssh2_tokio::Client>>>,
}

impl SshConnectionPool {
    fn new() -> Self {
        Self {
            clients: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn hash_secret(secret: &str) -> u64 {
        let mut hasher = DefaultHasher::new();
        secret.trim().hash(&mut hasher);
        hasher.finish()
    }

    fn should_reconnect(err: &SshError) -> bool {
        match err {
            SshError::SshError(_) | SshError::SendError(_) | SshError::ChannelSendError(_) => true,
            SshError::IoError(e) => matches!(
                e.kind(),
                io::ErrorKind::BrokenPipe
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::ConnectionAborted
                    | io::ErrorKind::NotConnected
                    | io::ErrorKind::UnexpectedEof
                    | io::ErrorKind::TimedOut
            ),
            _ => false,
        }
    }

    async fn get(&self, key: &PoolKey) -> Option<async_ssh2_tokio::Client> {
        self.clients.lock().await.get(key).cloned()
    }

    async fn insert(&self, key: PoolKey, client: async_ssh2_tokio::Client) {
        self.clients.lock().await.insert(key, client);
    }

    async fn remove(&self, key: &PoolKey) {
        self.clients.lock().await.remove(key);
    }

    async fn clear_all(&self) -> usize {
        let mut g = self.clients.lock().await;
        let n = g.len();
        g.clear();
        n
    }

    async fn connect_key(
        &self,
        host: &str,
        port: u16,
        username: &str,
        private_key_pem: &str,
        passphrase: Option<&str>,
        connect_timeout: Duration,
    ) -> Result<async_ssh2_tokio::Client, SshError> {
        let auth_method = async_ssh2_tokio::AuthMethod::with_key(private_key_pem, passphrase);
        timeout(
            connect_timeout,
            async_ssh2_tokio::Client::connect(
                (host, port),
                username,
                auth_method,
                async_ssh2_tokio::ServerCheckMethod::NoCheck,
            ),
        )
        .await
        .map_err(|_| {
            SshError::IoError(io::Error::new(
                io::ErrorKind::TimedOut,
                "SSH connect timeout",
            ))
        })?
    }

    async fn connect_password(
        &self,
        host: &str,
        port: u16,
        username: &str,
        password: &str,
        connect_timeout: Duration,
    ) -> Result<async_ssh2_tokio::Client, SshError> {
        let auth_method = async_ssh2_tokio::AuthMethod::with_password(password);
        timeout(
            connect_timeout,
            async_ssh2_tokio::Client::connect(
                (host, port),
                username,
                auth_method,
                async_ssh2_tokio::ServerCheckMethod::NoCheck,
            ),
        )
        .await
        .map_err(|_| {
            SshError::IoError(io::Error::new(
                io::ErrorKind::TimedOut,
                "SSH connect timeout",
            ))
        })?
    }

    async fn get_or_connect_key(
        &self,
        host: &str,
        port: u16,
        username: &str,
        private_key_pem: &str,
        passphrase: Option<&str>,
        connect_timeout: Duration,
    ) -> Result<(PoolKey, async_ssh2_tokio::Client), SshError> {
        let key = PoolKey {
            host: host.to_owned(),
            port,
            username: username.to_owned(),
            auth_kind: PoolAuthKind::Key,
            secret_hash: Self::hash_secret(private_key_pem),
        };
        if let Some(client) = self.get(&key).await {
            return Ok((key, client));
        }
        let client = self
            .connect_key(host, port, username, private_key_pem, passphrase, connect_timeout)
            .await?;
        self.insert(key.clone(), client.clone()).await;
        Ok((key, client))
    }

    async fn get_or_connect_password(
        &self,
        host: &str,
        port: u16,
        username: &str,
        password: &str,
        connect_timeout: Duration,
    ) -> Result<(PoolKey, async_ssh2_tokio::Client), SshError> {
        let key = PoolKey {
            host: host.to_owned(),
            port,
            username: username.to_owned(),
            auth_kind: PoolAuthKind::Password,
            secret_hash: Self::hash_secret(password),
        };
        if let Some(client) = self.get(&key).await {
            return Ok((key, client));
        }
        let client = self
            .connect_password(host, port, username, password, connect_timeout)
            .await?;
        self.insert(key.clone(), client.clone()).await;
        Ok((key, client))
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind")]
enum SshAuth {
    #[serde(rename = "key")]
    Key {
        private_key_pem: String,
        private_key_passphrase: Option<String>,
    },
    #[serde(rename = "password")]
    Password { password: String },
}

#[derive(Debug, Clone, Deserialize)]
struct SshTarget {
    host: String,
    port: u16,
    username: String,
    auth: SshAuth,
}

#[derive(Debug, Clone, Deserialize)]
struct SshExecParams {
    target: SshTarget,
    command: String,
    connect_timeout_ms: u64,
    command_timeout_ms: u64,
}

#[derive(Debug, Clone, Deserialize)]
struct SshStartParams {
    target: SshTarget,
    command: String,
    connect_timeout_ms: u64,
}

#[derive(Debug, Clone, Deserialize)]
struct SshCancelParams {
    stream_id: u64,
}

#[derive(Debug, Clone, Deserialize)]
struct SshResetAllParams {
    reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct SshWriteFileParams {
    target: SshTarget,
    remote_path: String,
    contents: String,
    connect_timeout_ms: u64,
    command_timeout_ms: u64,
}

#[derive(Debug, Clone, Deserialize)]
struct SshGenerateKeyParams {
    comment: String,
}

#[derive(Debug, Clone, Deserialize)]
struct SshAuthorizedKeyLineParams {
    private_key_pem: String,
    private_key_passphrase: Option<String>,
    comment: String,
}

#[derive(Debug, Clone, Deserialize)]
struct SshInstallPublicKeyParams {
    user_at_host: String,
    port: u16,
    password: String,
    private_key_pem: String,
    private_key_passphrase: Option<String>,
    comment: String,
}

#[derive(Debug, Deserialize)]
struct RequestEnvelope {
    id: u64,
    method: String,
    #[serde(default)]
    params: serde_json::Value,
}

#[derive(Debug, Serialize)]
struct ResponseEnvelope<T: Serialize> {
    id: u64,
    ok: bool,
    result: Option<T>,
    error: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum EventEnvelope<'a> {
    #[serde(rename = "stream_line")]
    StreamLine {
        stream_id: u64,
        is_stderr: bool,
        line: &'a str,
    },
    #[serde(rename = "stream_exit")]
    StreamExit {
        stream_id: u64,
        exit_status: i32,
        error: Option<&'a str>,
    },
}

#[derive(Clone)]
struct DaemonState {
    pool: SshConnectionPool,
    next_stream_id: Arc<std::sync::atomic::AtomicU64>,
}

impl DaemonState {
    fn new() -> Self {
        Self {
            pool: SshConnectionPool::new(),
            next_stream_id: Arc::new(std::sync::atomic::AtomicU64::new(1)),
        }
    }
}

#[derive(Clone, Default)]
struct ConnectionStreams {
    tasks: Arc<Mutex<HashMap<u64, JoinHandle<()>>>>,
}

#[derive(Clone)]
struct Outbox {
    tx: mpsc::Sender<String>,
}

impl Outbox {
    async fn send_json<T: Serialize>(&self, value: &T) -> Result<(), ()> {
        let line = match serde_json::to_string(value) {
            Ok(s) => s,
            Err(_) => return Err(()),
        };
        self.tx.send(line).await.map_err(|_| ())
    }

    async fn send_response_ok<T: Serialize>(&self, id: u64, result: T) -> Result<(), ()> {
        self.send_json(&ResponseEnvelope::<T> {
            id,
            ok: true,
            result: Some(result),
            error: None,
        })
        .await
    }

    async fn send_response_err(&self, id: u64, error: impl Into<String>) -> Result<(), ()> {
        self.send_json(&ResponseEnvelope::<serde_json::Value> {
            id,
            ok: false,
            result: None,
            error: Some(error.into()),
        })
        .await
    }
}

#[derive(Serialize)]
struct HelloResult {
    protocol: u32,
}

#[derive(Deserialize)]
struct HelloParams {
    token: String,
    protocol: u32,
}

#[derive(Serialize)]
struct SshExecResult {
    stdout: String,
    stderr: String,
    exit_code: i32,
}

#[derive(Serialize)]
struct SshStartResult {
    stream_id: u64,
}

#[derive(Serialize)]
struct SshResetAllResult {
    cleared_connections: usize,
    cancelled_streams: usize,
}

#[derive(Serialize)]
struct SshGenerateKeyResult {
    private_key_pem: String,
}

#[derive(Serialize)]
struct SshAuthorizedKeyLineResult {
    authorized_key_line: String,
}

#[derive(Serialize)]
struct SshInstallPublicKeyResult {}

#[derive(Serialize)]
struct SshWriteFileResult {}

#[derive(Clone)]
struct ServerConfig {
    token: String,
    protocol: u32,
}

fn hex_token(bytes_len: usize) -> String {
    let mut bytes = vec![0_u8; bytes_len];
    OsRng.fill_bytes(&mut bytes);
    let mut out = String::with_capacity(bytes_len * 2);
    for b in bytes {
        use std::fmt::Write;
        let _ = write!(&mut out, "{:02x}", b);
    }
    out
}

#[derive(Serialize)]
struct StateFile {
    version: u32,
    pid: u32,
    port: u16,
    token: String,
    protocol: u32,
}

fn write_state_file(path: &Path, port: u16, token: &str, protocol: u32) -> io::Result<()> {
    let Some(dir) = path.parent() else {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "missing parent dir"));
    };
    fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).ok();
    }

    let tmp_path = PathBuf::from(format!("{}.tmp", path.display()));
    let payload = StateFile {
        version: 1,
        pid: std::process::id(),
        port,
        token: token.to_owned(),
        protocol,
    };
    let json = serde_json::to_string(&payload)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    fs::write(&tmp_path, json)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o600)).ok();
    }
    fs::rename(&tmp_path, path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).ok();
    }
    Ok(())
}

fn parse_args() -> (u16, PathBuf) {
    let mut port: u16 = 0;
    let mut state_file: Option<PathBuf> = None;
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => {
                if let Some(v) = args.next() {
                    if let Ok(p) = v.parse::<u16>() {
                        port = p;
                    }
                }
            }
            "--state-file" => {
                if let Some(v) = args.next() {
                    state_file = Some(PathBuf::from(v));
                }
            }
            _ => {}
        }
    }

    let state_file = state_file.unwrap_or_else(|| {
        let home = env::var("HOME").unwrap_or_default();
        let base = if home.trim().is_empty() {
            PathBuf::from(".")
        } else {
            PathBuf::from(home).join(".config/field_exec")
        };
        base.join("field_execd.json")
    });

    (port, state_file)
}

fn sh_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".to_owned();
    }
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '/' | ':' | '=' | '@' | '-'))
    {
        return s.to_owned();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn parse_target(target: SshTarget) -> Result<(String, u16, String, SshAuth), String> {
    if target.host.trim().is_empty() {
        return Err("host is empty".to_owned());
    }
    if target.username.trim().is_empty() {
        return Err("username is empty".to_owned());
    }
    if target.port == 0 {
        return Err("invalid port".to_owned());
    }
    Ok((target.host, target.port, target.username, target.auth))
}

async fn ssh_get_client(
    pool: &SshConnectionPool,
    target: SshTarget,
    connect_timeout: Duration,
) -> Result<(PoolKey, async_ssh2_tokio::Client), String> {
    let (host, port, username, auth) = parse_target(target)?;
    match auth {
        SshAuth::Key {
            private_key_pem,
            private_key_passphrase,
        } => {
            if private_key_pem.trim().is_empty() {
                return Err("private_key_pem is empty".to_owned());
            }
            pool.get_or_connect_key(
                &host,
                port,
                &username,
                &private_key_pem,
                private_key_passphrase.as_deref(),
                connect_timeout,
            )
            .await
            .map_err(|e| e.to_string())
        }
        SshAuth::Password { password } => {
            if password.trim().is_empty() {
                return Err("password is empty".to_owned());
            }
            pool.get_or_connect_password(&host, port, &username, &password, connect_timeout)
                .await
                .map_err(|e| e.to_string())
        }
    }
}

async fn ssh_exec(
    state: &DaemonState,
    params: SshExecParams,
) -> Result<SshExecResult, String> {
    let connect_timeout = Duration::from_millis(params.connect_timeout_ms.max(1));
    let command_timeout = Duration::from_millis(params.command_timeout_ms.max(1));

    let target = params.target.clone();
    let (pool_key, client) = ssh_get_client(&state.pool, target.clone(), connect_timeout).await?;

    let first = timeout(command_timeout, client.execute(&params.command))
        .await
        .map_err(|_| "SSH command timeout".to_owned());
    match first {
        Ok(Ok(res)) => Ok(SshExecResult {
            stdout: res.stdout,
            stderr: res.stderr,
            exit_code: i32::try_from(res.exit_status).unwrap_or(-1),
        }),
        Ok(Err(e)) if SshConnectionPool::should_reconnect(&e) => {
            state.pool.remove(&pool_key).await;
            let (_pool_key2, client2) =
                ssh_get_client(&state.pool, target, connect_timeout).await?;
            let res = timeout(command_timeout, client2.execute(&params.command))
                .await
                .map_err(|_| "SSH command timeout".to_owned())?
                .map_err(|e| e.to_string())?;
            Ok(SshExecResult {
                stdout: res.stdout,
                stderr: res.stderr,
                exit_code: i32::try_from(res.exit_status).unwrap_or(-1),
            })
        }
        Ok(Err(e)) => Err(e.to_string()),
        Err(e) => Err(e),
    }
}

async fn ssh_write_file(state: &DaemonState, params: SshWriteFileParams) -> Result<(), String> {
    let connect_timeout = Duration::from_millis(params.connect_timeout_ms.max(1));
    let command_timeout = Duration::from_millis(params.command_timeout_ms.max(1));
    let (pool_key, client) = ssh_get_client(&state.pool, params.target, connect_timeout).await?;

    let remote_path_q = sh_quote(&params.remote_path);
    let command = [
        "umask 077",
        &format!("dir=$(dirname {remote_path_q})"),
        r#"mkdir -p "$dir""#,
        r#"chmod 700 "$dir" >/dev/null 2>&1 || true"#,
        &format!("cat > {remote_path_q}"),
        &format!("chmod 600 {remote_path_q} >/dev/null 2>&1 || true"),
    ]
    .join("; ");

    let (stdout_tx, mut stdout_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(1);
    let (stderr_tx, mut stderr_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(1);
    let (stdin_tx, stdin_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(2);

    let write_task: JoinHandle<Result<u32, async_ssh2_tokio::Error>> =
        tokio::spawn(async move {
            client
                .execute_io(&command, stdout_tx, Some(stderr_tx), Some(stdin_rx), false, None)
                .await
        });

    // Send file contents then EOF (empty vec).
    stdin_tx
        .send(params.contents.into_bytes())
        .await
        .map_err(|_| "stdin send failed".to_owned())?;
    stdin_tx
        .send(Vec::new())
        .await
        .map_err(|_| "stdin send failed".to_owned())?;

    // Drain any stdout/stderr to avoid deadlocks.
    let drain = tokio::spawn(async move {
        while stdout_rx.recv().await.is_some() {}
        while stderr_rx.recv().await.is_some() {}
    });

    let status = timeout(command_timeout, write_task)
        .await
        .map_err(|_| "SSH command timeout".to_owned())?
        .map_err(|_| "SSH write task join failed".to_owned())?
        .map_err(|e| e.to_string());

    let _ = drain.await;

    match status {
        Ok(code) if code == 0 => Ok(()),
        Ok(code) => Err(format!("write failed (exit={code})")),
        Err(e) if e.contains("Broken pipe") || e.contains("Connection reset") => {
            state.pool.remove(&pool_key).await;
            Err(e)
        }
        Err(e) => Err(e),
    }
}

fn ssh_generate_key(params: SshGenerateKeyParams) -> Result<SshGenerateKeyResult, String> {
    let mut rng = OsRng;
    let mut key = PrivateKey::random(&mut rng, Algorithm::Ed25519).map_err(|e| e.to_string())?;
    key.set_comment(params.comment);
    let pem = key
        .to_openssh(LineEnding::LF)
        .map_err(|e| e.to_string())?;
    Ok(SshGenerateKeyResult {
        private_key_pem: pem.to_string(),
    })
}

fn ssh_authorized_key_line(
    params: SshAuthorizedKeyLineParams,
) -> Result<SshAuthorizedKeyLineResult, String> {
    let parsed = keys::decode_secret_key(
        &params.private_key_pem,
        params.private_key_passphrase.as_deref(),
    )
    .map_err(|e| e.to_string())?;
    let mut key = parsed;
    key.set_comment(params.comment);
    let line = key.public_key().to_openssh().map_err(|e| e.to_string())?;
    Ok(SshAuthorizedKeyLineResult {
        authorized_key_line: line,
    })
}

async fn ssh_install_public_key(params: SshInstallPublicKeyParams) -> Result<(), String> {
    let at = params.user_at_host.find('@').ok_or_else(|| {
        "user_at_host must be username@host".to_owned()
    })?;
    let username = &params.user_at_host[..at];
    let host = &params.user_at_host[at + 1..];
    if username.trim().is_empty() || host.trim().is_empty() {
        return Err("user_at_host must be username@host".to_owned());
    }

    let parsed = keys::decode_secret_key(
        &params.private_key_pem,
        params.private_key_passphrase.as_deref(),
    )
    .map_err(|e| e.to_string())?;
    let mut key = parsed;
    key.set_comment(params.comment);
    let public_line = key.public_key().to_openssh().map_err(|e| e.to_string())?;
    let escaped = public_line.replace('\'', "'\\''");
    let remote_command = [
        "umask 077",
        "mkdir -p ~/.ssh",
        "chmod 700 ~/.ssh",
        "touch ~/.ssh/authorized_keys",
        "chmod 600 ~/.ssh/authorized_keys",
        &format!(
            "grep -qxF '{}' ~/.ssh/authorized_keys || printf '%s\\n' '{}' >> ~/.ssh/authorized_keys",
            escaped, escaped
        ),
    ]
    .join("; ");

    let connect_timeout = Duration::from_secs(10);
    let command_timeout = Duration::from_secs(30);
    let auth_method = async_ssh2_tokio::AuthMethod::with_password(&params.password);
    let client = timeout(
        connect_timeout,
        async_ssh2_tokio::Client::connect(
            (host, params.port),
            username,
            auth_method,
            async_ssh2_tokio::ServerCheckMethod::NoCheck,
        ),
    )
    .await
    .map_err(|_| "SSH connect timeout".to_owned())?
    .map_err(|e| e.to_string())?;

    timeout(command_timeout, client.execute(&remote_command))
        .await
        .map_err(|_| "SSH command timeout".to_owned())?
        .map_err(|e| e.to_string())?;

    Ok(())
}

async fn handle_request(
    server_cfg: &ServerConfig,
    state: &DaemonState,
    streams: &ConnectionStreams,
    outbox: Outbox,
    req: RequestEnvelope,
) -> Result<(), ()> {
    let id = req.id;
    match req.method.as_str() {
        "hello" => {
            let params: HelloParams =
                serde_json::from_value(req.params).map_err(|_| ())?;
            if params.protocol != server_cfg.protocol {
                let _ = outbox
                    .send_response_err(
                        id,
                        format!(
                            "protocol mismatch (client={}, server={})",
                            params.protocol, server_cfg.protocol
                        ),
                    )
                    .await;
                return Err(());
            }
            if params.token != server_cfg.token {
                let _ = outbox.send_response_err(id, "unauthorized").await;
                return Err(());
            }
            outbox
                .send_response_ok(id, HelloResult { protocol: server_cfg.protocol })
                .await?;
            Ok(())
        }
        "ssh.exec" => {
            let params: SshExecParams = serde_json::from_value(req.params).map_err(|e| {
                let _ = e;
                ()
            })?;
            match ssh_exec(state, params).await {
                Ok(res) => outbox.send_response_ok(id, res).await,
                Err(e) => outbox.send_response_err(id, e).await,
            }
        }
        "ssh.start" => {
            let params: SshStartParams = serde_json::from_value(req.params).map_err(|_| ())?;
            let connect_timeout = Duration::from_millis(params.connect_timeout_ms.max(1));
            let (pool_key, client) =
                ssh_get_client(&state.pool, params.target.clone(), connect_timeout)
                    .await
                    .map_err(|e| {
                        let _ = outbox.send_response_err(id, e);
                        ()
                    })?;

            let stream_id = state
                .next_stream_id
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);

            let cmd = params.command.clone();
            let outbox2 = outbox.clone();
            let streams2 = streams.clone();
            let pool = state.pool.clone();
            let handle = tokio::spawn(async move {
                tokio::task::yield_now().await;
                let (stdout_tx, mut stdout_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(16);
                let (stderr_tx, mut stderr_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(16);
                let exec_future = client.execute_io(&cmd, stdout_tx, Some(stderr_tx), None, false, None);

                let mut out_pending = String::new();
                let mut err_pending = String::new();

                tokio::pin!(exec_future);
                let exit_status = loop {
                    tokio::select! {
                        result = &mut exec_future => break result,
                        Some(bytes) = stdout_rx.recv() => {
                            let chunk = String::from_utf8_lossy(&bytes);
                            out_pending.push_str(&chunk);
                            while let Some(idx) = out_pending.find('\n') {
                                let line = out_pending[..idx].trim_end_matches('\r').to_owned();
                                out_pending.drain(..idx + 1);
                                let _ = outbox2.send_json(&EventEnvelope::StreamLine {
                                    stream_id,
                                    is_stderr: false,
                                    line: &line,
                                }).await;
                            }
                        }
                        Some(bytes) = stderr_rx.recv() => {
                            let chunk = String::from_utf8_lossy(&bytes);
                            err_pending.push_str(&chunk);
                            while let Some(idx) = err_pending.find('\n') {
                                let line = err_pending[..idx].trim_end_matches('\r').to_owned();
                                err_pending.drain(..idx + 1);
                                let _ = outbox2.send_json(&EventEnvelope::StreamLine {
                                    stream_id,
                                    is_stderr: true,
                                    line: &line,
                                }).await;
                            }
                        }
                    }
                };

                while let Some(bytes) = stdout_rx.recv().await {
                    let chunk = String::from_utf8_lossy(&bytes);
                    out_pending.push_str(&chunk);
                    while let Some(idx) = out_pending.find('\n') {
                        let line = out_pending[..idx].trim_end_matches('\r').to_owned();
                        out_pending.drain(..idx + 1);
                        let _ = outbox2.send_json(&EventEnvelope::StreamLine {
                            stream_id,
                            is_stderr: false,
                            line: &line,
                        }).await;
                    }
                }
                while let Some(bytes) = stderr_rx.recv().await {
                    let chunk = String::from_utf8_lossy(&bytes);
                    err_pending.push_str(&chunk);
                    while let Some(idx) = err_pending.find('\n') {
                        let line = err_pending[..idx].trim_end_matches('\r').to_owned();
                        err_pending.drain(..idx + 1);
                        let _ = outbox2.send_json(&EventEnvelope::StreamLine {
                            stream_id,
                            is_stderr: true,
                            line: &line,
                        }).await;
                    }
                }

                let pending = out_pending.trim().to_owned();
                out_pending.clear();
                if !pending.is_empty() {
                    let _ = outbox2.send_json(&EventEnvelope::StreamLine {
                        stream_id,
                        is_stderr: false,
                        line: &pending,
                    }).await;
                }
                let pending = err_pending.trim().to_owned();
                err_pending.clear();
                if !pending.is_empty() {
                    let _ = outbox2.send_json(&EventEnvelope::StreamLine {
                        stream_id,
                        is_stderr: true,
                        line: &pending,
                    }).await;
                }

                match exit_status {
                    Ok(code) => {
                        let _ = outbox2.send_json(&EventEnvelope::StreamExit {
                            stream_id,
                            exit_status: i32::try_from(code).unwrap_or(-1),
                            error: None,
                        }).await;
                    }
                    Err(e) => {
                        if SshConnectionPool::should_reconnect(&e) {
                            pool.remove(&pool_key).await;
                        }
                        let msg = e.to_string();
                        let _ = outbox2.send_json(&EventEnvelope::StreamExit {
                            stream_id,
                            exit_status: -1,
                            error: Some(&msg),
                        }).await;
                    }
                }

                streams2.tasks.lock().await.remove(&stream_id);
            });

            streams.tasks.lock().await.insert(stream_id, handle);
            outbox
                .send_response_ok(id, SshStartResult { stream_id })
                .await
        }
        "ssh.cancel" => {
            let params: SshCancelParams = serde_json::from_value(req.params).map_err(|_| ())?;
            if let Some(handle) = streams.tasks.lock().await.remove(&params.stream_id) {
                handle.abort();
                let _ = outbox.send_json(&EventEnvelope::StreamExit {
                    stream_id: params.stream_id,
                    exit_status: -1,
                    error: Some("cancelled"),
                }).await;
            }
            outbox.send_response_ok(id, serde_json::json!({"cancelled": true})).await
        }
        "ssh.reset_all" => {
            let params: SshResetAllParams = serde_json::from_value(req.params).unwrap_or(SshResetAllParams { reason: None });
            let reason = params.reason.unwrap_or_else(|| "reset".to_owned());
            let mut g = streams.tasks.lock().await;
            let cancelled_streams = g.len();
            for (stream_id, handle) in g.drain() {
                handle.abort();
                let _ = outbox.send_json(&EventEnvelope::StreamExit {
                    stream_id,
                    exit_status: -1,
                    error: Some(&reason),
                }).await;
            }
            let cleared_connections = state.pool.clear_all().await;
            outbox
                .send_response_ok(
                    id,
                    SshResetAllResult {
                        cleared_connections,
                        cancelled_streams,
                    },
                )
                .await
        }
        "ssh.write_file" => {
            let params: SshWriteFileParams = serde_json::from_value(req.params).map_err(|_| ())?;
            match ssh_write_file(state, params).await {
                Ok(()) => outbox.send_response_ok(id, SshWriteFileResult {}).await,
                Err(e) => outbox.send_response_err(id, e).await,
            }
        }
        "ssh.generate_key" => {
            let params: SshGenerateKeyParams = serde_json::from_value(req.params).map_err(|_| ())?;
            match ssh_generate_key(params) {
                Ok(res) => outbox.send_response_ok(id, res).await,
                Err(e) => outbox.send_response_err(id, e).await,
            }
        }
        "ssh.authorized_key_line" => {
            let params: SshAuthorizedKeyLineParams =
                serde_json::from_value(req.params).map_err(|_| ())?;
            match ssh_authorized_key_line(params) {
                Ok(res) => outbox.send_response_ok(id, res).await,
                Err(e) => outbox.send_response_err(id, e).await,
            }
        }
        "ssh.install_public_key" => {
            let params: SshInstallPublicKeyParams =
                serde_json::from_value(req.params).map_err(|_| ())?;
            match ssh_install_public_key(params).await {
                Ok(()) => outbox.send_response_ok(id, SshInstallPublicKeyResult {}).await,
                Err(e) => outbox.send_response_err(id, e).await,
            }
        }
        _ => outbox.send_response_err(id, "unknown method").await,
    }
}

async fn handle_connection(
    server_cfg: ServerConfig,
    state: DaemonState,
    stream: TcpStream,
) -> io::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    let (tx, mut rx) = mpsc::channel::<String>(256);

    let writer_task: JoinHandle<()> = tokio::spawn(async move {
        while let Some(line) = rx.recv().await {
            if writer.write_all(line.as_bytes()).await.is_err() {
                break;
            }
            if writer.write_all(b"\n").await.is_err() {
                break;
            }
            if writer.flush().await.is_err() {
                break;
            }
        }
    });

    let outbox = Outbox { tx };
    let streams = ConnectionStreams::default();
    let mut authed = false;

    while let Some(line) = lines.next_line().await? {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let req: RequestEnvelope = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => {
                // Ignore malformed lines to avoid bricking the connection.
                continue;
            }
        };

        if !authed {
            if req.method != "hello" {
                let _ = outbox.send_response_err(req.id, "unauthorized").await;
                break;
            }
            if handle_request(&server_cfg, &state, &streams, outbox.clone(), req)
                .await
                .is_err()
            {
                break;
            }
            authed = true;
            continue;
        }

        let _ = handle_request(&server_cfg, &state, &streams, outbox.clone(), req).await;
    }

    let mut g = streams.tasks.lock().await;
    for (stream_id, handle) in g.drain() {
        handle.abort();
        let _ = outbox
            .send_json(&EventEnvelope::StreamExit {
                stream_id,
                exit_status: -1,
                error: Some("connection closed"),
            })
            .await;
    }

    writer_task.abort();
    Ok(())
}

#[tokio::main]
async fn main() -> io::Result<()> {
    let (port, state_file) = parse_args();

    let listener = TcpListener::bind(("127.0.0.1", port)).await?;
    let addr = listener.local_addr()?;
    let actual_port = addr.port();

    let protocol: u32 = 1;
    let token = hex_token(32);
    write_state_file(&state_file, actual_port, &token, protocol)?;

    let server_cfg = ServerConfig { token, protocol };
    let state = DaemonState::new();

    loop {
        let (stream, _) = listener.accept().await?;
        let cfg = server_cfg.clone();
        let st = state.clone();
        tokio::spawn(async move {
            let _ = handle_connection(cfg, st, stream).await;
        });
    }
}
