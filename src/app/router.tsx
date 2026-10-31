/** Tiny hash-based router: one active page at a time, no dependency. */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { registerBackClaim } from "@/lib/backButton";

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

  /* How many pages *this app* has put in the session history.
     `history.length` is not that number: the WebView's own initial navigation
     is in there, so on the phone it reads 8 with a single page visited, and
     `history.back()` then walked straight out of the document. Back is only
     ours to spend while this counter is above one. */
  const depth = useRef(1);

  useEffect(() => {
    const onHash = () => setPage(readHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const navigate = useCallback((next: PageId, opts?: { replace?: boolean }) => {
    setPage(next);
    const hash = `#/${next}`;
    if (opts?.replace) {
      window.history.replaceState(null, "", hash);
    } else {
      depth.current += 1;
      window.location.hash = hash;
    }
  }, []);

  /* Android's back affordance, answered by the router rather than by the shell:
     only the router knows whether the previous entry is one of its own pages.
     Returns false when there is nothing of ours to undo, which leaves the press
     for the shell to turn into an exit. */
  const goBack = useCallback((): boolean => {
    if (depth.current <= 1) return false;
    depth.current -= 1;
    window.history.back();
    return true;
  }, []);

  useEffect(() => registerBackClaim(goBack), [goBack]);

  const value = useMemo(() => ({ page, navigate }), [page, navigate]);
  return <RouterContext.Provider value={value}>{children}</RouterContext.Provider>;
}

export function useRouter(): RouterValue {
  return useContext(RouterContext);
}
