/** Stroke icon set (24px grid, 1.7 stroke) — keeps the app dependency-free. */
import type { SVGProps } from "react";

export type IconName =
  | "words"
  | "cards"
  | "quiz"
  | "stats"
  | "settings"
  | "search"
  | "plus"
  | "star"
  | "star-filled"
  | "trash"
  | "edit"
  | "play"
  | "volume"
  | "check"
  | "x"
  | "chevron-left"
  | "chevron-right"
  | "chevron-down"
  | "flame"
  | "clock"
  | "more"
  | "upload"
  | "download"
  | "sparkles"
  | "filter"
  | "arrow-right"
  | "refresh"
  | "book"
  | "layers"
  | "target"
  | "calendar"
  | "keyboard"
  | "info"
  | "alert"
  | "sun"
  | "moon"
  | "undo"
  | "cloud"
  | "list";

const PATHS: Record<IconName, string> = {
  words: "M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15.5H6.5A2.5 2.5 0 0 0 4 21V5.5Z M20 18.5H6.5",
  cards: "M8 3h9a2 2 0 0 1 2 2v11 M5 7h9a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2Z",
  quiz: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z M9.2 9.3a2.9 2.9 0 0 1 5.6 1c0 1.9-2.8 2.4-2.8 4 M12 17.5h.01",
  stats: "M4 20V10 M10 20V4 M16 20v-7 M22 20H2",
  settings: "M4 7h10 M18 7h2 M4 17h4 M12 17h8 M15 4.5v5 M8 14.5v5",
  search: "M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16Z M21 21l-4.3-4.3",
  plus: "M12 5v14 M5 12h14",
  star: "m12 3.5 2.6 5.4 5.9.8-4.3 4.2 1 5.9-5.2-2.8-5.2 2.8 1-5.9L3.5 9.7l5.9-.8L12 3.5Z",
  "star-filled": "m12 3.5 2.6 5.4 5.9.8-4.3 4.2 1 5.9-5.2-2.8-5.2 2.8 1-5.9L3.5 9.7l5.9-.8L12 3.5Z",
  trash: "M4 7h16 M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2 M6.5 7l.8 12.2a1 1 0 0 0 1 .8h7.4a1 1 0 0 0 1-.8L17.5 7 M10 11v5 M14 11v5",
  edit: "M12 20h9 M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4 12.5-12.5Z",
  play: "M7 4.5v15l13-7.5-13-7.5Z",
  volume: "M11 5 6 9H3v6h3l5 4V5Z M15.5 8.5a5 5 0 0 1 0 7 M18.5 5.5a9 9 0 0 1 0 13",
  check: "m4.5 12.5 5 5 10-11",
  x: "M6 6l12 12 M18 6 6 18",
  "chevron-left": "m14.5 5-7 7 7 7",
  "chevron-right": "m9.5 5 7 7-7 7",
  "chevron-down": "m5 9.5 7 7 7-7",
  flame: "M12 21c3.9 0 6.5-2.4 6.5-6 0-3.4-2.6-5.6-3.8-8.4-.5 2-1.7 3-3.1 3.4.4-3-1.4-5.4-2.6-7-1.6 3.6-3.5 6.6-3.5 11 0 4.1 2.6 7 6.5 7Z",
  clock: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z M12 7.5V12l3 2",
  more: "M5 12h.01 M12 12h.01 M19 12h.01",
  upload: "M12 16V4 M7 9l5-5 5 5 M4 20h16",
  download: "M12 4v12 M7 11l5 5 5-5 M4 20h16",
  sparkles: "M12 3l1.6 4.4L18 9l-4.4 1.6L12 15l-1.6-4.4L6 9l4.4-1.6L12 3Z M18.5 15l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2Z",
  filter: "M4 6h16 M7 12h10 M10 18h4",
  "arrow-right": "M4 12h15 M13 6l6 6-6 6",
  refresh: "M20 11a8 8 0 1 0-1.2 5.2 M20 5v6h-6",
  book: "M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15.5H6.5A2.5 2.5 0 0 0 4 21V5.5Z",
  layers: "m12 3 9 5-9 5-9-5 9-5Z M3 13l9 5 9-5 M3 17.5l9 5 9-5",
  target: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10Z M12 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z",
  calendar: "M5 5h14a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1Z M4 10h16 M8.5 3v4 M15.5 3v4",
  keyboard: "M4 7h16a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1Z M7 11h.01 M10.5 11h.01 M14 11h.01 M17.5 11h.01 M8 14.5h8",
  info: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z M12 11v5 M12 7.5h.01",
  alert: "M12 4 2.8 20h18.4L12 4Z M12 10v4.5 M12 17.5h.01",
  sun: "M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10Z M12 2v2.2 M12 19.8V22 M2 12h2.2 M19.8 12H22 M4.9 4.9l1.6 1.6 M17.5 17.5l1.6 1.6 M19.1 4.9l-1.6 1.6 M6.5 17.5l-1.6 1.6",
  moon: "M20.5 14.3A8.6 8.6 0 0 1 9.7 3.5a8.6 8.6 0 1 0 10.8 10.8Z",
  undo: "M4 9h9.5a5.5 5.5 0 0 1 0 11H8 M4 9l4-4 M4 9l4 4",
  cloud: "M7 18.5a4.5 4.5 0 0 1-.6-8.96 6 6 0 0 1 11.5 1.1A3.9 3.9 0 0 1 17.5 18.5H7Z",
  list: "M8 6h13 M8 12h13 M8 18h13 M3.5 6h.01 M3.5 12h.01 M3.5 18h.01",
};

interface IconProps extends Omit<SVGProps<SVGSVGElement>, "name"> {
  name: IconName;
  size?: number;
  filled?: boolean;
}

export function Icon({ name, size = 18, filled, strokeWidth = 1.7, ...rest }: IconProps) {
  const isFilled = filled ?? name === "star-filled";
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={isFilled ? "currentColor" : "none"}
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      {...rest}
    >
      <path d={PATHS[name]} />
    </svg>
  );
}
