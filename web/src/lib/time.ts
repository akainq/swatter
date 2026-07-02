// [порог для перехода, юнит ПОСЛЕ деления на порог]
const UNITS: Array<[number, string]> = [
  [60, "m"],
  [60, "h"],
  [24, "d"],
];

export function timeAgo(iso: string): string {
  let value = (Date.now() - new Date(iso).getTime()) / 1000;
  if (value < 1) return "just now";

  let unit = "s";
  for (const [step, next] of UNITS) {
    if (value < step) break;
    value /= step;
    unit = next;
  }
  return `${Math.floor(value)}${unit} ago`;
}

export function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString();
}
