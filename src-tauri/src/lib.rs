//! Lexilo desktop shell.
//!
//! The UI is a plain Vite/React frontend and all persistence happens in
//! IndexedDB, so this crate is mostly a webview host. The one thing the
//! frontend cannot do by itself is call third-party HTTP APIs that do not send
//! permissive CORS headers — the Youdao dictionary endpoint being the important
//! one. Those two commands below are thin proxies: they fetch, and hand the raw
//! JSON back so the parsing stays in TypeScript where it is easy to test.

use std::time::Duration;

use serde::Serialize;

/// A desktop client should identify itself honestly rather than pretend to be
/// a browser, but some public endpoints reject obviously non-browser agents.
const USER_AGENT: &str = "Lexilo/0.1 (+https://github.com/noahal1/lingueez-web)";

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Serialize)]
pub struct ProxyResponse {
    pub ok: bool,
    /// HTTP status code, or 0 when the request never completed.
    pub status: u16,
    pub body: String,
    pub error: Option<String>,
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .user_agent(USER_AGENT)
        .build()
        .map_err(|e| e.to_string())
}

async fn fetch_json(url: &str, query: &[(&str, &str)]) -> ProxyResponse {
    let client = match client() {
        Ok(c) => c,
        Err(e) => {
            return ProxyResponse {
                ok: false,
                status: 0,
                body: String::new(),
                error: Some(format!("client: {e}")),
            }
        }
    };

    match client.get(url).query(query).send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();
            match resp.text().await {
                Ok(body) => ProxyResponse {
                    ok: (200..300).contains(&status),
                    status,
                    body,
                    error: None,
                },
                Err(e) => ProxyResponse {
                    ok: false,
                    status,
                    body: String::new(),
                    error: Some(format!("body: {e}")),
                },
            }
        }
        Err(e) => ProxyResponse {
            ok: false,
            status: 0,
            body: String::new(),
            error: Some(format!("request: {e}")),
        },
    }
}

/// Dictionary lookup for a single term (word or short phrase).
///
/// Youdao's `jsonapi` endpoint sends no `Access-Control-Allow-Origin` header,
/// so a browser fetch is rejected even though the endpoint itself is public.
/// Doing it here sidesteps CORS and also lets the app stay useful when the
/// webview runs from a `tauri://` origin.
#[tauri::command]
async fn lookup_word(term: String) -> Result<ProxyResponse, String> {
    let term = term.trim().to_string();
    if term.is_empty() {
        return Err("empty term".into());
    }
    if term.chars().count() > 120 {
        return Err("term too long".into());
    }
    Ok(fetch_json("https://dict.youdao.com/jsonapi", &[("q", &term)]).await)
}

/// Plain text translation between two language codes (`en`, `zh-CHS`, …).
///
/// Used for language pairs the dictionary does not cover, and as a fallback
/// when the dictionary has no entry for the term.
#[tauri::command]
async fn translate_text(q: String, from: String, to: String) -> Result<ProxyResponse, String> {
    let q = q.trim().to_string();
    if q.is_empty() {
        return Err("empty text".into());
    }
    if q.chars().count() > 500 {
        return Err("text too long".into());
    }
    Ok(fetch_json(
        "https://aidemo.youdao.com/trans",
        &[("q", &q), ("from", &from), ("to", &to)],
    )
    .await)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![lookup_word, translate_text])
        .run(tauri::generate_context!())
        .expect("error while running the Lexilo window");
}
