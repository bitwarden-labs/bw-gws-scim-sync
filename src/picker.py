"""Pick Google groups or users from the Workspace directory instead of typing their emails.

Run by select-groups.sh. It uses the same read-only, keyless directory access as the sync, so it
needs GOOGLE_SA_EMAIL and GOOGLE_ADMIN_EMAIL. The chosen emails are written, comma-separated, to
the --output file; a summary of what changed is printed to stdout.

Exit codes: 0 the selection changed (written to --output), 3 nothing changed, 4 cancelled.
"""
import argparse
import os
import sys
import time
from dataclasses import dataclass

EXIT_UNCHANGED, EXIT_CANCELLED = 3, 4


@dataclass(frozen=True)
class Item:
    key: str  # email, which is what gets saved
    label: str  # display name
    detail: str = ""


def split_emails(raw: str) -> list[str]:
    seen: list[str] = []
    for part in raw.split(","):
        email = part.strip().lower()
        if email and email not in seen:
            seen.append(email)
    return seen


def format_row(item: Item, chosen: set[str], key_width: int) -> str:
    mark = "x" if item.key in chosen else " "
    return f"[{mark}] {item.label[:32]:32}  {item.key:{key_width}}  {item.detail}".rstrip()


def filter_items(items: list[Item], text: str) -> list[Item]:
    text = text.strip().lower()
    if not text:
        return list(items)
    return [i for i in items if text in i.key.lower() or text in i.label.lower()]


def parse_selection(text: str, count: int) -> set[int]:
    """Turns "1,3,5-7" into 0-based indexes {0, 2, 4, 5, 6}. Raises ValueError when out of range."""
    chosen: set[int] = set()
    for part in text.replace(" ", "").split(","):
        if not part:
            continue
        low, sep, high = part.partition("-")
        try:
            start, end = int(low), int(high) if sep else int(low)
        except ValueError:
            raise ValueError(f"{part!r} isn't a number or a range like 5-7") from None
        if not 1 <= start <= end <= count:
            raise ValueError(f"{part} isn't between 1 and {count}")
        chosen.update(range(start - 1, end))
    return chosen


def merge_current(items: list[Item], current: list[str]) -> list[Item]:
    """Keeps saved emails that the directory no longer has, so they can be seen and unselected."""
    known = {i.key for i in items}
    missing = [Item(email, email, "not found in the directory") for email in current if email not in known]
    return missing + items


def pick_plain(title, items, selected, read=input, write=print) -> set[str] | None:
    """Numbered-list picker that works in any terminal."""
    chosen = set(selected)
    text = ""
    while True:
        shown = filter_items(items, text)
        write(f"\n{title}" + (f"   (filter: {text})" if text else ""))
        if not shown:
            write("  No matches.")
        key_width = max((len(i.key) for i in shown), default=0)
        for n, item in enumerate(shown, 1):
            write(f"  {n:3}  {format_row(item, chosen, key_width)}")
        write(f"{len(chosen)} selected. Type numbers to select or unselect (for example 1,3,5-7), "
              "/text to filter, / to clear the filter, s to save, q to cancel.")
        try:
            answer = read("> ").strip()
        except EOFError:
            return None
        if answer.lower() == "s":
            return chosen
        if answer.lower() == "q":
            return None
        if answer.startswith("/"):
            text = answer[1:]
            continue
        try:
            for index in parse_selection(answer, len(shown)):
                chosen ^= {shown[index].key}
        except ValueError as e:
            write(f"  {e}")


def pick_curses(title, items, selected) -> set[str] | None:
    """Arrow-key checklist with a type-to-filter box."""
    import curses

    os.environ.setdefault("ESCDELAY", "25")

    def put(scr, y, text, width, attr=0):
        try:
            scr.addnstr(y, 0, text, max(1, width - 1), attr)
        except curses.error:
            pass

    def ui(scr):
        curses.curs_set(0)
        scr.keypad(True)
        chosen, text, typing, cursor, top = set(selected), "", False, 0, 0
        while True:
            shown = filter_items(items, text)
            height, width = scr.getmaxyx()
            rows = max(1, height - 5)
            cursor = max(0, min(cursor, len(shown) - 1))
            top = min(top, cursor)
            top = max(top, cursor - rows + 1)
            scr.erase()
            put(scr, 0, title, width, curses.A_BOLD)
            put(scr, 1, f"Filter: {text}" + ("_" if typing else ""), width)
            if not shown:
                put(scr, 2, "  No matches.", width)
            key_width = max((len(i.key) for i in shown), default=0)
            for row, item in enumerate(shown[top:top + rows]):
                line = " " + format_row(item, chosen, key_width)
                put(scr, 2 + row, line, width, curses.A_REVERSE if top + row == cursor else 0)
            put(scr, height - 2, f"{len(chosen)} selected", width)
            put(scr, height - 1, "Type to filter, Enter when done" if typing else
                "Up/Down move  Space select  / filter  Enter save  q cancel", width)
            key = scr.get_wch()
            if typing:
                if key in ("\n", "\r", "\x1b", curses.KEY_ENTER):
                    typing = False
                elif key in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                    text = text[:-1]
                elif isinstance(key, str) and key.isprintable():
                    text, cursor = text + key, 0
            elif key in (curses.KEY_UP, "k"):
                cursor -= 1
            elif key in (curses.KEY_DOWN, "j"):
                cursor += 1
            elif key == curses.KEY_PPAGE:
                cursor -= rows
            elif key == curses.KEY_NPAGE:
                cursor += rows
            elif key == " " and shown:
                chosen ^= {shown[cursor].key}
            elif key == "/":
                typing = True
            elif key in ("\n", "\r", curses.KEY_ENTER):
                return chosen
            elif key in ("q", "Q"):  # Not Esc: stray escape sequences shouldn't discard choices.
                return None

    try:
        return curses.wrapper(ui)
    except curses.error as e:  # e.g. a terminal type curses can't drive
        raise RuntimeError(str(e)) from e


def load_items(kind: str, directory) -> list[Item]:
    if kind == "groups":
        items = [Item(g["email"].lower(), g["name"], f'{g["members"]} member' + ("" if g["members"] == 1 else "s")) for g in directory.list_groups()]
    else:
        items = [Item(u.email.lower(), u.full_name) for u in directory.list_users().values() if not u.suspended]
    return sorted(items, key=lambda i: (i.label.lower(), i.key))


def with_retry(load, attempts: int = 12, wait: int = 15):
    """Retries while a just-granted permission to sign as the service account takes effect."""
    from google.auth import exceptions

    for attempt in range(1, attempts + 1):
        try:
            return load()
        except exceptions.RefreshError as e:
            if "unauthorized_client" in str(e):
                raise SystemExit(
                    "Google rejected the directory access: domain-wide delegation isn't set up or isn't "
                    "active yet (README Step 3). Check the Client ID and scopes, wait a few minutes, "
                    "and try again."
                ) from None
            raise
        except exceptions.TransportError as e:
            if "signBlob" not in str(e) or attempt == attempts:
                raise
            print(f"  Waiting for permission to sign as the service account ({attempt}/{attempts})...",
                  file=sys.stderr)
            time.sleep(wait)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["groups", "users"])
    parser.add_argument("--current", default="", help="Comma-separated emails selected now")
    parser.add_argument("--title", default="Choose from your directory")
    parser.add_argument("--output", required=True, help="File that receives the chosen emails")
    parser.add_argument("--plain", action="store_true", help="Use the numbered list, not arrow keys")
    args = parser.parse_args(argv)

    from .google_directory import GoogleDirectory, build_credentials

    sa_email, admin = os.environ.get("GOOGLE_SA_EMAIL", ""), os.environ.get("GOOGLE_ADMIN_EMAIL", "")
    if not sa_email or not admin:
        raise SystemExit("GOOGLE_SA_EMAIL and GOOGLE_ADMIN_EMAIL must be set")
    directory = GoogleDirectory(build_credentials(sa_email, admin))
    print(f"Reading {args.kind} from your Google Workspace directory...", file=sys.stderr)
    current = split_emails(args.current)
    items = merge_current(with_retry(lambda: load_items(args.kind, directory)), current)

    use_curses = (not args.plain and sys.stdin.isatty() and sys.stdout.isatty()
                  and os.environ.get("TERM", "dumb") != "dumb")
    result = None
    if use_curses:
        try:
            result = pick_curses(args.title, items, current)
        except (ImportError, RuntimeError) as e:
            print(f"Arrow-key list unavailable ({e}); using the numbered list.", file=sys.stderr)
            use_curses = False
    if not use_curses:
        result = pick_plain(args.title, items, current)
    if result is None:
        print("Cancelled. Nothing was changed.")
        return EXIT_CANCELLED

    chosen = [i.key for i in items if i.key in result]
    added = [e for e in chosen if e not in current]
    removed = [e for e in current if e not in result]
    print(f"Selected {len(chosen)}.")
    for email in added:
        print(f"  + {email}")
    for email in removed:
        print(f"  - {email}")
    if not added and not removed:
        print("  No changes.")
        return EXIT_UNCHANGED
    with open(args.output, "w") as f:
        f.write(",".join(chosen))
    return 0


if __name__ == "__main__":
    sys.exit(main())
