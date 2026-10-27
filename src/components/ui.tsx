/**
 * Shared UI primitives used by every page.
 *
 * The heavier pieces live next door and are re-exported here so call sites
 * keep importing from one place:
 *   - `Modal.tsx`    — focus-trapped dialog + ConfirmDialog
 *   - `Toast.tsx`    — toast queue and its provider
 *   - `TagInput.tsx` — tag chip and the inline tag editor
 */
import { useId, type ReactNode } from "react";
import { cx } from "@/lib/utils";
import { Icon, type IconName } from "@/components/Icon";

export { ConfirmDialog, Modal } from "@/components/Modal";
export { ToastProvider, useToast } from "@/components/Toast";
export type { ToastAction, ToastFn, ToastKind, ToastOptions } from "@/components/Toast";
export { TagChip, TagInput } from "@/components/TagInput";

/* ------------------------------------------------------------------ */
/* Page shell — every page uses this so headers stay consistent        */
/* ------------------------------------------------------------------ */
export function PageShell({
  title,
  subtitle,
  actions,
  children,
  wide,
}: {
  title: string;
  subtitle?: string;
  actions?: ReactNode;
  children: ReactNode;
  wide?: boolean;
}) {
  const id = useId();
  return (
    <>
      <header className="topbar">
        <div style={{ minWidth: 0 }}>
          <h1 className="topbar-title" id={id}>
            {title}
          </h1>
          {subtitle && <div className="topbar-sub">{subtitle}</div>}
        </div>
        {actions && <div className="topbar-actions">{actions}</div>}
      </header>
      <div className="page" role="region" aria-labelledby={id}>
        <div className="page-inner" style={wide ? { maxWidth: 1360 } : undefined}>
          {children}
        </div>
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Segmented control                                                   */
/* ------------------------------------------------------------------ */
export function Segmented<T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
}: {
  value: T;
  options: Array<{ value: T; label: string; count?: number }>;
  onChange: (v: T) => void;
  ariaLabel?: string;
}) {
  return (
    <div className="segmented" role="tablist" aria-label={ariaLabel}>
      {options.map((o) => (
        <button
          key={o.value}
          role="tab"
          type="button"
          aria-selected={o.value === value}
          className={cx(o.value === value && "active")}
          onClick={() => onChange(o.value)}
        >
          {o.label}
          {o.count !== undefined && <span className="seg-count">{o.count}</span>}
        </button>
      ))}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Empty state                                                         */
/* ------------------------------------------------------------------ */
export function EmptyState({
  icon = "sparkles",
  title,
  text,
  action,
}: {
  icon?: IconName;
  title: string;
  text?: string;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      <div className="empty-icon">
        <Icon name={icon} size={22} />
      </div>
      <div className="empty-title">{title}</div>
      {text && <p className="empty-text">{text}</p>}
      {action}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Progress                                                            */
/* ------------------------------------------------------------------ */
export function ProgressBar({
  value,
  max = 1,
  thick,
  label,
}: {
  value: number;
  max?: number;
  thick?: boolean;
  label?: string;
}) {
  const pct = max <= 0 ? 0 : Math.max(0, Math.min(100, (value / max) * 100));
  return (
    <div
      className={cx("progress", thick && "thick")}
      role="progressbar"
      aria-valuenow={Math.round(pct)}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label={label}
    >
      <div className="progress-fill" style={{ width: `${pct}%` }} />
    </div>
  );
}

export function Ring({
  value,
  max = 1,
  size = 96,
  stroke = 8,
  children,
}: {
  value: number;
  max?: number;
  size?: number;
  stroke?: number;
  children?: ReactNode;
}) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const pct = max <= 0 ? 0 : Math.max(0, Math.min(1, value / max));
  return (
    <div className="ring" style={{ width: size, height: size }}>
      <svg width={size} height={size}>
        <circle
          className="ring-track"
          cx={size / 2}
          cy={size / 2}
          r={r}
          fill="none"
          strokeWidth={stroke}
        />
        <circle
          className="ring-fill"
          cx={size / 2}
          cy={size / 2}
          r={r}
          fill="none"
          strokeWidth={stroke}
          strokeLinecap="round"
          strokeDasharray={c}
          strokeDashoffset={c * (1 - pct)}
        />
      </svg>
      <div className="ring-center">{children}</div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Chips                                                               */
/* ------------------------------------------------------------------ */
export function StatusChip({ status, label }: { status: string; label: string }) {
  return (
    <span className={cx("chip", `chip-${status}`)}>
      <span className="dot" />
      {label}
    </span>
  );
}

/* ------------------------------------------------------------------ */
/* Stat tile                                                           */
/* ------------------------------------------------------------------ */
export function StatTile({
  label,
  value,
  sub,
  accent,
  icon,
}: {
  label: string;
  value: ReactNode;
  sub?: string;
  accent?: string;
  icon?: IconName;
}) {
  return (
    <div className="stat-tile">
      <div className="row-flex" style={{ gap: 6 }}>
        {icon && (
          <span style={{ color: accent ?? "var(--ink-3)", display: "grid", placeItems: "center" }}>
            <Icon name={icon} size={14} />
          </span>
        )}
        <div className="stat-label">{label}</div>
      </div>
      <div className="stat-value" style={accent ? { color: accent } : undefined}>
        {value}
      </div>
      {sub && <div className="stat-sub">{sub}</div>}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Keyboard shortcut rows                                              */
/* ------------------------------------------------------------------ */
export function ShortcutRow({ keys, label }: { keys: string[]; label: string }) {
  return (
    <div className="shortcut-row">
      <span>{label}</span>
      <span className="row-flex" style={{ gap: 4, flex: "0 0 auto" }}>
        {keys.map((k) => (
          <span key={k} className="kbd">
            {k}
          </span>
        ))}
      </span>
    </div>
  );
}
