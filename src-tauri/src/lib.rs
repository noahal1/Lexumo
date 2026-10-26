//! Lexilo desktop shell.
//!
//! The UI is a plain Vite/React frontend; this crate only hosts the webview
//! window. All persistence happens in the frontend (IndexedDB), so no custom
//! Tauri commands are registered yet. The lib/binary split follows the Tauri 2
//! convention and keeps a future mobile entry point possible.

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("error while running the Lexilo window");
}
