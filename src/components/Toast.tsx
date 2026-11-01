/** Toast queue: one provider, one stack, one card that owns its own timer. */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { cx } from "@/lib/utils";
import { Icon, type IconName } from "@/components/Icon";
import { prefersReducedMotion } from "@/lib/motion";
import { useT } from "@/i18n";

type ToastKind = "ok" | "err" | "info";

interface ToastAction {
  label: string;
  onClick: () => void;
}

interface ToastOptions {
  /** Optional inline action, e.g. 撤销. */
  action?: ToastAction;
  /** Override the auto-dismiss delay in ms. */
  duration?: number;
}

interface ToastItem {
  id: number;
  text: string;
  kind: ToastKind;
  action?: ToastAction;
  duration: number;
}

type ToastFn = (text: string, kind?: ToastKind, opts?: ToastOptions) => void;

const ToastContext = createContext<ToastFn>(() => {});

const TOAST_ICON: Record<ToastKind, IconName> = {
  ok: "check",
  err: "alert",
  info: "info",
};

const TOAST_MS: Record<ToastKind, number> = { ok: 3200, info: 3200, err: 6000 };

/**
 * One toast. Owns its own timer so hover/focus can hold it open — an error
 * that vanishes mid-sentence is worse than no message at all.
 */
function ToastCard({ item, onDismiss }: { item: ToastItem; onDismiss: (id: number) => void }) {
  const t = useT();
  const [held, setHeld] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const remaining = useRef(item.duration);
  const startedAt = useRef(0);
  const exitTimer = useRef<number | null>(null);
  const leavingRef = useRef(false);
  const { id, kind, action, text } = item;

  /**
   * Leave through a short exit animation instead of vanishing. `leavingRef`
   * guards re-entry because the auto-dismiss timer and a click can both fire.
   */
  const close = useCallback(() => {
    if (leavingRef.current) return;
    if (prefersReducedMotion()) {
      onDismiss(id);
      return;
    }
    leavingRef.current = true;
    setLeaving(true);
    exitTimer.current = window.setTimeout(() => onDismiss(id), 170);
  }, [id, onDismiss]);

  useEffect(
    () => () => {
      if (exitTimer.current !== null) window.clearTimeout(exitTimer.current);
    },
    [],
  );

  useEffect(() => {
    if (held || leaving) return;
    startedAt.current = Date.now();
    const handle = window.setTimeout(close, Math.max(400, remaining.current));
    return () => {
      window.clearTimeout(handle);
      remaining.current = Math.max(400, remaining.current - (Date.now() - startedAt.current));
    };
  }, [held, leaving, close]);

  return (
    <div
      className={cx("toast", `toast-${kind}`, action && "has-action", leaving && "is-leaving")}
      role={kind === "err" ? "alert" : "status"}
      aria-live={kind === "err" ? "assertive" : "polite"}
      onMouseEnter={() => setHeld(true)}
      onMouseLeave={() => setHeld(false)}
      onFocusCapture={() => setHeld(true)}
      onBlurCapture={() => setHeld(false)}
      onClick={() => {
        if (!action) close();
      }}
      style={{ pointerEvents: "auto", cursor: action ? "default" : "pointer" }}
    >
      <span className="toast-ico" aria-hidden="true">
        <Icon name={TOAST_ICON[kind]} size={14} />
      </span>
      <span className="toast-text">{text}</span>
      {action && (
        <button
          className="toast-action"
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            action.onClick();
            close();
          }}
        >
          {action.label}
        </button>
      )}
      <button
        className="toast-close"
        type="button"
        aria-label={t("common.close")}
        onClick={(e) => {
          e.stopPropagation();
          close();
        }}
      >
        <Icon name="x" size={12} />
      </button>
    </div>
  );
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const seq = useRef(0);

  const dismiss = useCallback((id: number) => {
    setItems((prev) => prev.filter((x) => x.id !== id));
  }, []);

  const push = useCallback<ToastFn>((text, kind = "info", opts) => {
    const id = ++seq.current;
    setItems((prev) => [
      ...prev.slice(-2),
      {
        id,
        text,
        kind,
        action: opts?.action,
        duration: opts?.duration ?? TOAST_MS[kind],
      },
    ]);
  }, []);

  return (
    <ToastContext.Provider value={push}>
      {children}
      <div className="toast-stack">
        {items.map((item) => (
          <ToastCard key={item.id} item={item} onDismiss={dismiss} />
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast(): ToastFn {
  return useContext(ToastContext);
}
