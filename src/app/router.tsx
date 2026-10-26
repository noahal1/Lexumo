/** Tiny hash-based router: one active page at a time, no dependency. */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";

export type PageId = "words" | "flashcards" | "quiz" | "stats" | "settings";

const PAGES: PageId[] = ["words", "flashcards", "quiz", "stats", "settings"];

interface RouterValue {
  page: PageId;
  navigate: (page: PageId, opts?: { replace?: boolean }) => void;
}

const RouterContext = createContext<RouterValue>({ page: "words", navigate: () => {} });

function readHash(): PageId {
  const raw = window.location.hash.replace(/^#\/?/, "").split("?")[0];
  return (PAGES as string[]).includes(raw) ? (raw as PageId) : "words";
}

export function RouterProvider({ children }: { children: ReactNode }) {
  const [page, setPage] = useState<PageId>(() => readHash());

  useEffect(() => {
    const onHash = () => setPage(readHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const navigate = useCallback((next: PageId, opts?: { replace?: boolean }) => {
    setPage(next);
    const hash = `#/${next}`;
    if (opts?.replace) window.history.replaceState(null, "", hash);
    else window.location.hash = hash;
  }, []);

  const value = useMemo(() => ({ page, navigate }), [page, navigate]);
  return <RouterContext.Provider value={value}>{children}</RouterContext.Provider>;
}

export function useRouter(): RouterValue {
  return useContext(RouterContext);
}
