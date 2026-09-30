// Toasts carried across a navigation the session asks for (docs/65 §6.3).
//
// A screen commonly notifies and then navigates in one step ("Customer
// saved", then the list page). The navigation replaces the page, so the
// toasts still on screen are stashed in session storage and shown again once
// the next page loads. The store is a parameter so the logic runs under node.

export interface CarriedToast {
  m: string;
  level: string;
}

export interface ToastStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

const KEY = "lyric-ui:toasts";

// Storage can be unavailable (a private window, blocked site data); a lost
// toast is then the only consequence, never a failed navigation.
export function stashToasts(store: ToastStore, toasts: readonly CarriedToast[]): void {
  if (toasts.length === 0) {
    return;
  }
  try {
    store.setItem(KEY, JSON.stringify(toasts));
  } catch {
    // Nothing to carry them in.
  }
}

export function takeStashedToasts(store: ToastStore): CarriedToast[] {
  let raw: string | null;
  try {
    raw = store.getItem(KEY);
    store.removeItem(KEY);
  } catch {
    return [];
  }
  if (raw === null) {
    return [];
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) {
    return [];
  }
  return parsed.filter(
    (t): t is CarriedToast =>
      typeof t === "object" && t !== null && typeof t.m === "string" && typeof t.level === "string",
  );
}
