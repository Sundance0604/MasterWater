import argparse
import html
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse, parse_qs


CLI = Path(r"C:\Users\32599\AppData\Local\ZhihuCLI\current\zhihu-cli.exe")
TZ = timezone(timedelta(hours=8))


def run_cli(*args):
    completed = subprocess.run(
        [str(CLI), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    payload = None
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        pass
    if completed.returncode != 0 or not payload or payload.get("Code") != 0:
        message = payload.get("Message") if isinstance(payload, dict) else completed.stderr.strip()
        code = payload.get("Code") if isinstance(payload, dict) else completed.returncode
        raise RuntimeError(f"CLI_ERROR {code}: {message}")
    return payload


def safe_name(title):
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", title).strip().rstrip(".")
    value = re.sub(r"\s+", " ", value)
    return value[:100] or "untitled"


class MarkdownHTMLParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.links = []
        self.list_stack = []
        self.in_pre = False
        self.in_code = False
        self.in_table = False
        self.table = []
        self.row = None
        self.cell = None

    def write(self, value):
        if self.in_table and self.cell is not None:
            self.cell.append(value)
        else:
            self.out.append(value)

    def block(self):
        if self.out and not self.out[-1].endswith("\n\n"):
            self.out.append("\n\n")

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
            self.block()
            self.write("#" * int(tag[1]) + " ")
        elif tag in {"p", "div", "figure", "blockquote"}:
            self.block()
            if tag == "blockquote":
                self.write("> ")
        elif tag == "br":
            self.write("  \n")
        elif tag in {"strong", "b"}:
            self.write("**")
        elif tag in {"em", "i"}:
            self.write("*")
        elif tag == "del":
            self.write("~~")
        elif tag == "a":
            self.write("[")
            self.links.append(attrs.get("href", ""))
        elif tag == "img":
            src = attrs.get("data-original") or attrs.get("src") or ""
            alt = attrs.get("alt") or attrs.get("data-caption") or "图片"
            if "zhihu.com/equation" in src:
                tex = parse_qs(urlparse(src).query).get("tex", [alt])[0]
                self.write(f"${tex}$")
            elif src:
                self.write(f"![{alt}]({src})")
        elif tag in {"ul", "ol"}:
            self.block()
            self.list_stack.append([tag, 0])
        elif tag == "li":
            self.block()
            if self.list_stack:
                self.list_stack[-1][1] += 1
                marker = "-" if self.list_stack[-1][0] == "ul" else f"{self.list_stack[-1][1]}."
                self.write("  " * (len(self.list_stack) - 1) + marker + " ")
        elif tag == "pre":
            self.block()
            self.in_pre = True
            self.write("```\n")
        elif tag == "code" and not self.in_pre:
            self.in_code = True
            self.write("`")
        elif tag == "table":
            self.block()
            self.in_table = True
            self.table = []
        elif tag == "tr":
            self.row = []
        elif tag in {"th", "td"}:
            self.cell = []

    def handle_endtag(self, tag):
        if tag in {"h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "figure", "blockquote"}:
            self.block()
        elif tag in {"strong", "b"}:
            self.write("**")
        elif tag in {"em", "i"}:
            self.write("*")
        elif tag == "del":
            self.write("~~")
        elif tag == "a":
            href = self.links.pop() if self.links else ""
            self.write(f"]({href})")
        elif tag in {"ul", "ol"}:
            if self.list_stack:
                self.list_stack.pop()
            self.block()
        elif tag == "pre":
            self.write("\n```\n\n")
            self.in_pre = False
        elif tag == "code" and not self.in_pre:
            self.write("`")
            self.in_code = False
        elif tag in {"th", "td"}:
            value = "".join(self.cell or []).strip().replace("|", "\\|").replace("\n", " ")
            if self.row is not None:
                self.row.append(value)
            self.cell = None
        elif tag == "tr":
            if self.row:
                self.table.append(self.row)
            self.row = None
        elif tag == "table":
            self.in_table = False
            if self.table:
                width = max(map(len, self.table))
                rows = [row + [""] * (width - len(row)) for row in self.table]
                self.out.append("| " + " | ".join(rows[0]) + " |\n")
                self.out.append("| " + " | ".join(["---"] * width) + " |\n")
                for row in rows[1:]:
                    self.out.append("| " + " | ".join(row) + " |\n")
                self.out.append("\n")
            self.table = []

    def handle_data(self, data):
        if self.in_pre:
            self.write(data)
        else:
            self.write(re.sub(r"\s+", " ", data))

    def markdown(self):
        value = html.unescape("".join(self.out))
        value = re.sub(r"[ \t]+\n", "\n", value)
        value = re.sub(r"\n{3,}", "\n\n", value)
        return value.strip() + "\n"


def html_to_markdown(source):
    parser = MarkdownHTMLParser()
    parser.feed(source)
    parser.close()
    return parser.markdown()


def article_list():
    payload = run_cli("me", "contents", "--type", "article", "--sort", "ts", "--order", "desc", "--offset", "0", "--limit", "50")
    return payload["Data"]["Items"], payload["Data"].get("Paging", {})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--count", type=int, default=5)
    parser.add_argument("--delay", type=float, default=4.0)
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="overwrite existing local Markdown; disabled by default to protect the local source of truth",
    )
    args = parser.parse_args()

    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    items, paging = article_list()
    selected = items[args.start: args.start + args.count]
    manifest_path = output / "manifest.json"
    manifest = {"api_total": paging.get("Totals"), "is_end": paging.get("IsEnd"), "items": []}
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    existing = {entry["url"]: entry for entry in manifest.get("items", [])}
    for index, item in enumerate(selected):
        date = datetime.fromtimestamp(item["CreatedAt"], TZ).strftime("%Y-%m-%d")
        expected_filename = f"{date} - {safe_name(item['Title'])} - {item['Url'].rstrip('/').split('/')[-1]}.md"
        expected_path = output / expected_filename
        if expected_path.exists() and not args.overwrite:
            print(f"SKIPPED {args.start + index + 1}/{len(items)} {expected_filename} (local file exists)")
            continue

        try:
            payload = run_cli("me", "content", "--content-url", item["Url"])
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 4
        detail = payload["Data"]
        filename = f"{date} - {safe_name(detail['Title'])} - {detail['ContentToken']}.md"
        frontmatter_title = detail["Title"].replace('"', '\\"')
        body = html_to_markdown(detail["Body"])
        document = (
            "---\n"
            f'title: "{frontmatter_title}"\n'
            f"date: {date}\n"
            f"source: {detail['Url']}\n"
            f"zhihu_token: {detail['ContentToken']}\n"
            "---\n\n"
            f"# {detail['Title']}\n\n"
            f"> 原文：[知乎专栏]({detail['Url']})\n\n"
            + body
        )
        (output / filename).write_text(document, encoding="utf-8", newline="\n")
        existing[item["Url"]] = {
            "title": detail["Title"],
            "date": date,
            "url": detail["Url"],
            "file": filename,
        }
        manifest["api_total"] = paging.get("Totals")
        manifest["is_end"] = paging.get("IsEnd")
        manifest["items"] = sorted(existing.values(), key=lambda value: (value["date"], value["title"]), reverse=True)
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8", newline="\n")
        print(f"EXPORTED {args.start + index + 1}/{len(items)} {filename}")
        if index + 1 < len(selected):
            time.sleep(args.delay)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
