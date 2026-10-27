/** Dialog primitives: the focus-trapped Modal and the ConfirmDialog built on it. */
import { useEffect, useId, useMemo, useRef, type ReactNode } from "react";
import { cx } from "@/lib/utils";
import { Icon } from "@/components/Icon";
import { useT } from "@/i18n";
import { SHORTCUTS, useShortcutScope, type ShortcutBinding } from "@/lib/shortcuts";

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function Modal({
  open,
  onClose,
  title,
  subtitle,
  children,
  footer,
  width,
  dismissible = true,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  subtitle?: string;
  children: ReactNode;
  footer?: ReactNode;
  width?: number;
  /** false blocks the two "accidental" exits (Esc and backdrop click). */
  dismissible?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const t = useT();

  /* A modal outranks the page it covers: while open it declares the modal
     scope, so Escape is consumed here before any page binding sees the key. */
  const modalShortcuts = useMemo<ShortcutBinding[]>(
    () =>
      open
        ? [
            {
              ...SHORTCUTS.closeModal,
              match: (event) => event.key === "Escape",
              run: () => {
                if (dismissible) onClose();
              },
              /* Escape must work while a field inside the dialog has focus. */
              allowWhenTyping: true,
            },
          ]
        : [],
    [open, onClose, dismissible],
  );
  useShortcutScope("modal", modalShortcuts);

  useEffect(() => {
    if (!open) return;
    const previous = document.activeElement as HTMLElement | null;

    const onKey = (e: KeyboardEvent) => {
      // Keep Tab inside the dialog — otherwise focus escapes to the page behind.
      if (e.key !== "Tab" || !ref.current) return;
      const nodes = Array.from(ref.current.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
        (el) => el.offsetParent !== null || el === document.activeElement,
      );
      if (nodes.length === 0) return;
      const first = nodes[0];
      const last = nodes[nodes.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    };

    document.addEventListener("keydown", onKey, true);
    const first = ref.current?.querySelector<HTMLElement>(
      "input, textarea, select, button:not(.modal-close)",
    );
    first?.focus();

    return () => {
      document.removeEventListener("keydown", onKey, true);
      previous?.focus?.();
    };
  }, [open, onClose, dismissible]);

  if (!open) return null;
  return (
    <div
      className="overlay"
      onMouseDown={(e) => {
        if (dismissible && e.target === e.currentTarget) onClose();
      }}
    >
      <div
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        ref={ref}
        tabIndex={-1}
        style={width ? { width: `min(${width}px, 100%)` } : undefined}
      >
        <div className="modal-head">
          <div style={{ minWidth: 0 }}>
            <div className="modal-title" id={titleId}>
              {title}
            </div>
            {subtitle && <div className="modal-sub">{subtitle}</div>}
          </div>
          <button className="modal-close" onClick={onClose} aria-label={t("common.close")} type="button">
            <Icon name="x" size={17} />
          </button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-foot">{footer}</div>}
      </div>
    </div>
  );
}

export function ConfirmDialog({
  open,
  title,
  body,
  confirmLabel,
  cancelLabel,
  danger = true,
  onConfirm,
  onCancel,
}: {
  open: boolean;
  title: string;
  body?: string;
  confirmLabel: string;
  cancelLabel: string;
  danger?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <Modal
      open={open}
      onClose={onCancel}
      title={title}
      width={440}
      footer={
        <>
          <button className="btn" onClick={onCancel} type="button">
            {cancelLabel}
          </button>
          <button
            className={cx("btn", danger ? "btn-danger" : "btn-primary")}
            onClick={onConfirm}
            type="button"
          >
            {confirmLabel}
          </button>
        </>
      }
    >
      {body && (
        <p className="muted" style={{ margin: 0, lineHeight: 1.6 }}>
          {body}
        </p>
      )}
    </Modal>
  );
}
