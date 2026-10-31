/** Dialog primitives: the focus-trapped Modal and the ConfirmDialog built on it. */
import { useEffect, useId, useMemo, useRef, type ReactNode } from "react";
import { cx } from "@/lib/utils";
import { Icon } from "@/components/Icon";
import { useT } from "@/i18n";
import { SHORTCUTS, useShortcutScope, type ShortcutBinding } from "@/lib/shortcuts";
import { registerBackClaim } from "@/lib/backButton";

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

  /* Android's back affordance means "dismiss the thing on top". A dialog is
     always that thing, so it claims the press before the shell can decide to
     walk history or leave the app. The claim reads the newest props through a
     ref so opening and closing do not re-register it on every render. */
  const latestClose = useRef(onClose);
  latestClose.current = onClose;
  const latestDismissible = useRef(dismissible);
  latestDismissible.current = dismissible;

  useEffect(() => {
    if (!open) return;
    return registerBackClaim(() => {
      /* A dialog that refuses Esc and the backdrop must refuse back too — but
         it still consumes the press, because the alternative is leaving the app
         from inside an unresolved question. */
      if (latestDismissible.current) latestClose.current();
      return true;
    });
  }, [open]);

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
    /* Put the caret in the first text field, not in the first enabled button:
       a button that is disabled on open (nothing to look up yet) matches the
       selector but cannot take focus, so the dialog used to open with focus on
       the container. */
    const first =
      ref.current?.querySelector<HTMLElement>(
        "input:not([disabled]):not([type='hidden']), textarea:not([disabled]), select:not([disabled])",
      ) ?? ref.current?.querySelector<HTMLElement>("button:not(.modal-close)");
    first?.focus();

    return () => {
      document.removeEventListener("keydown", onKey, true);
      previous?.focus?.();
    };
    /* Deps are `open` alone on purpose. This effect moves the caret, so it may
       only run when the dialog opens. `onClose` is a fresh closure on every
       parent render, and while it was a dependency the effect re-ran on every
       keystroke: each character re-focused the first control in the dialog and
       pulled the caret out of the field being typed into. */
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

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
