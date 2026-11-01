#!/usr/bin/env python3
"""从 gutendex 抓取某语言的候选书目 (热门 + 儿童/童话/寓言/短篇等易读类型)

用法: python3 fetch_gutendex.py <语言代码 en|fr> <输出 candidates.json> [热门页数]
"""
import json
import subprocess
import sys
import time
import urllib.parse


def get(url):
    for _ in range(3):
        r = subprocess.run(["curl", "-sL", "-m", "90", url], capture_output=True)
        try:
            return json.loads(r.stdout)
        except ValueError:
            time.sleep(2)
    return {"results": [], "next": None}


def main():
    lang, out_path = sys.argv[1], sys.argv[2]
    popular_pages = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    books = {}
    queries = [("popular", "languages=%s&sort=popular" % lang, popular_pages)]
    for topic in ["children", "juvenile", "fairy tales", "fables", "short stories", "adventure", "school stories", "animals"]:
        queries.append((topic, "languages=%s&topic=%s" % (lang, urllib.parse.quote(topic)), 4))
    for name, q, pages in queries:
        url = "https://gutendex.com/books/?" + q
        for _ in range(pages):
            d = get(url)
            for b in d.get("results", []):
                books.setdefault(b["id"], b)
            url = d.get("next")
            if not url:
                break
        print(name, len(books), flush=True)
    json.dump(list(books.values()), open(out_path, "w", encoding="utf-8"), ensure_ascii=False)


if __name__ == "__main__":
    main()
