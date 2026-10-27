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

async function boot() {
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
