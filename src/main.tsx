import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./styles/global.css";
import { App } from "./App";
import { RouterProvider } from "./app/router";
import { I18nProvider } from "./i18n";
import { ToastProvider } from "./components/ui";
import { initStore } from "./lib/store";

async function boot() {
  await initStore();
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <I18nProvider>
        <ToastProvider>
          <RouterProvider>
            <App />
          </RouterProvider>
        </ToastProvider>
      </I18nProvider>
    </StrictMode>,
  );
}

void boot();
