/** Tag chips and the inline editable tag input. */
import { useState } from "react";
import { cx } from "@/lib/utils";
import { Icon } from "@/components/Icon";
import { useT } from "@/i18n";

export function TagChip({ tag }: { tag: string }) {
  return <span className="chip chip-tag">#{tag}</span>;
}

export function TagInput({
  value,
  onChange,
  placeholder,
  hint,
}: {
  value: string[];
  onChange: (tags: string[]) => void;
  placeholder?: string;
  hint?: string;
}) {
  const t = useT();
  const [draft, setDraft] = useState("");

  const commit = () => {
    const tag = draft.trim().replace(/^#/, "");
    if (!tag) return;
    if (!value.some((t) => t.toLowerCase() === tag.toLowerCase())) {
      onChange([...value, tag]);
    }
    setDraft("");
  };

  return (
    <div className="field">
      <div
        className="input"
        style={{ display: "flex", flexWrap: "wrap", gap: 6, alignItems: "center", height: "auto", minHeight: 40, padding: "5px 8px" }}
      >
        {value.map((tag) => (
          <span key={tag} className={cx("chip", "chip-tag")} style={{ gap: 4 }}>
            #{tag}
            <button
              type="button"
              onClick={() => onChange(value.filter((t) => t !== tag))}
              className="btn-quiet"
              style={{
                border: 0,
                background: "transparent",
                color: "inherit",
                cursor: "pointer",
                padding: 0,
                display: "grid",
                placeItems: "center",
              }}
              aria-label={t("common.removeTag", { tag })}
            >
              <Icon name="x" size={11} />
            </button>
          </span>
        ))}
        <input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" || e.key === ",") {
              e.preventDefault();
              commit();
            } else if (e.key === "Backspace" && !draft && value.length) {
              onChange(value.slice(0, -1));
            }
          }}
          onBlur={commit}
          placeholder={value.length ? "" : placeholder}
          style={{
            flex: 1,
            minWidth: 100,
            border: 0,
            outline: "none",
            background: "transparent",
            color: "var(--ink)",
            padding: "3px 0",
            height: 24,
          }}
        />
      </div>
      {hint && <span className="hint">{hint}</span>}
    </div>
  );
}
