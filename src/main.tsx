import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./styles/global.css";
import { App } from "./App";
import { RouterProvider } from "./app/router";
import { I18nProvider } from "./i18n";
import { ToastProvider } from "./components/ui";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { initStore } from "./lib/store";
import { initSync } from "./lib/sync";
import { startKeyboardTracking } from "./lib/keyboard";
import { startBackButton } from "./lib/backButton";

async function boot() {
  // Both are facts about the shell rather than about the tree, so they start
  // before React mounts and outlive every re-render: the keyboard publishes its
  // inset as custom properties, and the back button is one listener that
  // overlays claim from.
  startKeyboardTracking();
  startBackButton();
  await initStore();
  // Start the background sync loop only after the local snapshot is loaded, so
  // the first round pushes everything that is still pending.
  initSync();
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <I18nProvider>
        <ErrorBoundary>
          <ToastProvider>
            <RouterProvider>
              <App />
            </RouterProvider>
          </ToastProvider>
        </ErrorBoundary>
      </I18nProvider>
    </StrictMode>,
  );
}

void boot();
