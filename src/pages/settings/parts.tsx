import { useEffect, useState, type ReactNode } from "react";
import { Icon, type IconName } from "@/components/Icon";

/** Shared building blocks for the settings page (and the sync section). */

export function Section({
  icon,
  title,
  note,
  id,
  children,
}: {
  icon: IconName;
  title: string;
  note?: string;
  /** Anchor target, so the shell can deep-link to a single section. */
  id?: string;
  children: ReactNode;
}) {
  return (
    <section className="set-section" id={id}>
      <header className="set-section-head">
        <span className="set-section-ico">
          <Icon name={icon} size={14} />
        </span>
        <h2 className="set-section-title">{title}</h2>
        {note && <span className="set-section-note">{note}</span>}
      </header>
      <div className="set-rows">{children}</div>
    </section>
  );
}

export function Row({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
}) {
  return (
    <div className="set-row">
      <div className="set-text">
        <span className="set-label">{label}</span>
        {hint && <span className="set-hint">{hint}</span>}
      </div>
      <div className="set-ctl">{children}</div>
    </div>
  );
}

export function Switch({
  checked,
  onChange,
  label,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      className="switch"
      onClick={() => onChange(!checked)}
    >
      <span className="switch-knob" />
    </button>
  );
}

/** Phone layout, matching the breakpoint the shell uses for the tab bar. */
export function useIsMobile(): boolean {
  const [mobile, setMobile] = useState(
    () => typeof window !== "undefined" && window.innerWidth <= 720,
  );

  useEffect(() => {
    const mq = window.matchMedia("(max-width: 720px)");
    const sync = () => setMobile(mq.matches);
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  return mobile;
}
