#!/usr/bin/env python3
"""根据词汇难度为古登堡公版书分级, 生成 App 内推荐书单 recommend_<lang>.json

用法: python3 build_recommendations.py [--lang fr|en] <candidates.json> <CEFR 词库 tsv> <文本缓存目录> <输出 json> [每级本数]
candidates.json 为 gutendex 返回的书目列表。法语词库用 FLELex (FleLex_TT_Beacco.tsv), 英语用 EFLLex。
"""
import json
import os
import re
import subprocess
import sys
from collections import Counter

LEVELS = ["A1", "A2", "B1", "B2", "C1", "C2"]
LANG = "fr"
WORD_RE = re.compile(r"[a-zàâäæçéèêëîïôœùûüÿ]+(?:[-'’][a-zàâäæçéèêëîïôœùûüÿ]+)*", re.I)
ELISION = re.compile(r"^(l|d|j|m|n|s|t|c|qu|jusqu|lorsqu|puisqu)['’]", re.I)
EXCLUDE = re.compile(r"chronique|correspondance|œuvres complètes|oeuvres complètes|bulletin|revue|dictionnaire|grammaire|"
                     r"mémoires|histoire de france|tome \d|volume \d|annales|catalogue|recueil de lois|procès|discours|lettres", re.I)

# 英语
EN_WORD_RE = re.compile(r"[a-z]+(?:['’][a-z]+)?", re.I)
EN_SUFFIX = re.compile(r"['’](s|d|ll|ve|re|m|t)$", re.I)
EN_EXCLUDE = re.compile(r"complete works|collected works|works of|vol\.|volume|index|dictionary|encyclopa|history of|letters of|"
                        r"memoirs|essays|sermons|report|proceedings|manual|cook|journal of|magazine|bible|grammar|census|household words|\bno\. \d", re.I)
EN_RULES = [("ies", "y"), ("ied", "y"), ("ing", ""), ("ing", "e"), ("ed", ""), ("ed", "e"), ("es", ""), ("s", ""),
            ("ier", "y"), ("iest", "y"), ("er", ""), ("est", ""), ("ly", "")]

RULES = [("aux", "al"), ("eaux", "eau"), ("euses", "eux"), ("euse", "eux"), ("ives", "if"), ("ive", "if"),
         ("elles", "el"), ("elle", "el"), ("ennes", "en"), ("enne", "en"),
         ("ées", "er"), ("és", "er"), ("ée", "er"), ("é", "er"),
         ("aient", "er"), ("ais", "er"), ("ait", "er"), ("ions", "er"), ("iez", "er"), ("ons", "er"), ("ez", "er"),
         ("èrent", "er"), ("ent", "er"), ("ant", "er"), ("es", "er"), ("e", "er"),
         ("eront", "er"), ("erons", "er"), ("erez", "er"), ("erai", "er"), ("eras", "er"), ("era", "er"), ("erait", "er"),
         ("issaient", "ir"), ("issait", "ir"), ("issons", "ir"), ("issez", "ir"), ("issent", "ir"), ("issant", "ir"),
         ("is", "ir"), ("it", "ir"), ("ies", "ir"), ("ie", "ir"), ("i", "ir"),
         ("es", ""), ("s", ""), ("x", ""), ("e", "")]


def load_levels(path):
    """词 -> 等级 (1-6). 有 level 列时直接使用, 否则取首次出现频次 > 0 的等级"""
    lv = {}
    for line in open(path, encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) < 8 or p[0] == "word":
            continue
        w = p[0].lower()
        if len(p) >= 10 and p[9] in LEVELS:
            n = LEVELS.index(p[9]) + 1
        else:
            try:
                freqs = [float(x) for x in p[2:8]]
            except ValueError:
                continue
            n = next((i + 1 for i, f in enumerate(freqs) if f > 0), 0)
            if n == 0:
                continue
        lv[w] = min(lv.get(w, 9), n)
    return lv


IRREGULAR = {}
FICTION = re.compile(r"fiction|roman|novel|juvenile|children|fairy|fable|conte|tale|short stor|drama|comed|théâtre|poetry|poésie|adventure|aventure|legend|folklore|literature|littérature", re.I)
# 成人内容: 收录但标记; 非文学类: 排除
ADULT = re.compile(r"erotic|érotique|\bsex(?! role)|kama|libertin|pornograph|chambres du plaisir|homme tout nu|escole des filles", re.I)
ADULT_AUTHORS = re.compile(r"sade|louÿs|mirbeau|rachilde", re.I)
UNSUITABLE = re.compile(r"amateurs italiens|cycle mythologique", re.I)
EN_WORDS = re.compile(r"\b(the|and|of|which|with|this|that|is|was)\b")
NONFICTION = re.compile(r"history|histoire|politic|philosoph|sociolog|religio|theolog|law|droit|econom|science|medic|biograph|education|military|war of|guerre mondiale|manuel|essay|essai|category: art|music|linguist|dialect|language", re.I)


def word_level(w, lv, cache):
    if w in cache:
        return cache[w]
    if "-" in w:
        w = w.split("-")[0]
    base = IRREGULAR.get(w)
    r = lv.get(base) if base else None
    if r is None:
        r = lv.get(w)
    if r is None:
        for suf, rep in (EN_RULES if LANG == "en" else RULES):
            if w.endswith(suf) and len(w) > len(suf) + 2:
                r = lv.get(w[: -len(suf)] + rep)
                if r:
                    break
    cache[w] = r or 7
    return cache[w]


def fetch_text(book, cache_dir):
    path = os.path.join(cache_dir, "%d.txt" % book["id"])
    if os.path.exists(path) and os.path.getsize(path) > 0:
        raw = open(path, "rb").read()
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            return raw.decode("latin-1")
    url = None
    for k, v in book["formats"].items():
        if k.startswith("text/plain") and not v.endswith(".zip"):
            url = v
            break
    if not url:
        return ""
    r = subprocess.run(["curl", "-sL", "-m", "120", url], capture_output=True)
    with open(path, "wb") as f:
        f.write(r.stdout)
    try:
        return r.stdout.decode("utf-8")
    except UnicodeDecodeError:
        return r.stdout.decode("latin-1")


def strip_gutenberg(text):
    m = re.search(r"\*\*\* ?START OF.*?\*\*\*", text)
    if m:
        text = text[m.end():]
    m = re.search(r"\*\*\* ?END OF", text)
    if m:
        text = text[: m.start()]
    return text


def analyze(text, lv):
    cache = {}
    tokens = (EN_WORD_RE if LANG == "en" else WORD_RE).findall(text)
    caps = Counter()
    total = Counter()
    for t in tokens:
        b = EN_SUFFIX.sub("", t) if LANG == "en" else ELISION.sub("", t)
        k = b.lower()
        if len(k) == 1 and k not in ("a", "à", "y", "ô", "i"):
            continue
        total[k] += 1
        if b[:1].isupper():
            caps[k] += 1
    counts = Counter()
    n = 0
    for k, c in total.items():
        # 大部分出现时都大写的视为专有名词 (英语的 I 除外)
        if caps[k] / c > 0.8 and c >= 2 and k != "i":
            continue
        counts[word_level(k, lv, cache)] += c
        n += c
    if n == 0:
        return None
    coverage = []
    acc = 0
    for L in range(1, 7):
        acc += counts[L]
        coverage.append(round(100.0 * acc / n, 1))
    # 平均句长 (词)
    sentences = max(1, len(re.findall(r"[.!?…]+", text)))
    asl = min(60.0, len(tokens) / sentences)
    # 难度分数: 词汇 (超出 A2/B1/B2 的比例) + 句法 (平均句长)
    score = 0.5 * (100 - coverage[1]) + (100 - coverage[2]) + 0.5 * (100 - coverage[3]) + 0.5 * asl
    return {"words": len(tokens), "coverage": coverage, "score": round(score, 2), "asl": round(asl, 1)}


def clean_title(t):
    t = re.sub(r"\s*:\s*\$b.*", "", t)
    t = t.replace("$b", "").strip()
    return t[:80]


def author_name(b):
    if not b.get("authors"):
        return "佚名"
    n = b["authors"][0]["name"]
    if "," in n:
        last, first = n.split(",", 1)
        n = (first.strip() + " " + last.strip()).strip()
    return n


def genre(b):
    for s in b.get("bookshelves", []) + b.get("subjects", []):
        s = s.replace("Browsing: ", "").replace("FR ", "")
        if "--" in s:
            s = s.split("--")[-1].strip()
        if len(s) < 40:
            return s
    return ""


def load_irregular():
    data_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "VReading", "Resources", "Data")
    if LANG == "en":
        # word_changed.txt: abandoning@@@LINK=abandon
        for line in open(os.path.join(data_dir, "word_changed.txt"), encoding="utf-8-sig"):
            if "@@@LINK=" in line:
                a, b = line.strip().split("@@@LINK=", 1)
                IRREGULAR[a.lower()] = b.lower()
        for form, base in {"was": "be", "were": "be", "is": "be", "are": "be", "am": "be", "been": "be", "being": "be",
                           "has": "have", "had": "have", "having": "have", "does": "do", "did": "do", "done": "do",
                           "went": "go", "gone": "go", "said": "say", "made": "make", "came": "come", "took": "take",
                           "taken": "take", "saw": "see", "seen": "see", "knew": "know", "known": "know", "thought": "think",
                           "got": "get", "gave": "give", "given": "give", "told": "tell", "found": "find", "felt": "feel",
                           "left": "leave", "heard": "hear", "brought": "bring", "began": "begin", "begun": "begin",
                           "kept": "keep", "held": "hold", "stood": "stand", "sat": "sit", "ran": "run", "spoke": "speak",
                           "spoken": "speak", "wrote": "write", "written": "write", "men": "man", "women": "woman",
                           "children": "child", "feet": "foot", "teeth": "tooth", "mice": "mouse", "people": "person",
                           "him": "he", "his": "he", "her": "she", "them": "they", "their": "they", "me": "i", "my": "i",
                           "us": "we", "our": "we", "an": "a", "these": "this", "those": "that"}.items():
            IRREGULAR.setdefault(form, base)
    else:
        IRREGULAR.update(json.load(open(os.path.join(data_dir, "fr_irregular.json"), encoding="utf-8")))


def main():
    global LANG
    args = sys.argv[1:]
    if args and args[0] == "--lang":
        LANG = args[1]
        args = args[2:]
    cand_path, lexicon, cache_dir, out_path = args[:4]
    per_level = int(args[4]) if len(args) > 4 else 18
    os.makedirs(cache_dir, exist_ok=True)
    lv = load_levels(lexicon)
    load_irregular()
    books = json.load(open(cand_path, encoding="utf-8"))
    exclude = EN_EXCLUDE if LANG == "en" else EXCLUDE
    rows = []
    for i, b in enumerate(books):
        title = clean_title(b["title"])
        if exclude.search(title) or LANG not in b.get("languages", []) or len(b.get("languages", [])) > 1:
            continue
        if not any(k.startswith("application/epub") for k in b["formats"]):
            continue
        tags = " ".join(b.get("subjects", []) + b.get("bookshelves", []))
        # 只推荐文学类作品
        if not FICTION.search(tags) or (NONFICTION.search(tags) and not re.search(r"fiction|juvenile|conte|tale", tags, re.I)):
            continue
        if UNSUITABLE.search(tags + " " + title):
            continue
        adult = bool(ADULT.search(tags + " " + title) or ADULT_AUTHORS.search(author_name(b)))
        text = strip_gutenberg(fetch_text(b, cache_dir))
        # 法语书: 带大量英文注释的教学版不适合
        if LANG == "fr" and text and len(re.findall(r"\bthe\b", text, re.I)) > 80:
            continue
        a = analyze(text, lv) if text else None
        if not a or a["words"] < 1500 or a["words"] > 220000:
            continue
        cover = b["formats"].get("image/jpeg", "")
        rows.append({
            "id": b["id"], "title": title, "author": author_name(b), "score": a["score"], "words": a["words"],
            "coverage": a["coverage"], "epub": "https://www.gutenberg.org/ebooks/%d.epub3.images" % b["id"],
            "cover": cover.replace("small", "medium"), "genre": genre(b), "downloads": b.get("download_count", 0),
            "adult": adult,
        })
        if i % 25 == 0:
            print("analyzed", i, "/", len(books), "kept", len(rows), flush=True)

    # 同名作品只保留下载量最高的版本
    best = {}
    for r in rows:
        # 去掉冠词和副标题 (分号/冒号之后) 再比较
        base = re.split(r"[;:]", r["title"].lower())[0]
        key = re.sub(r"[^a-zà-ÿ]", "", re.sub(r"^(the|a|an)\s+", "", base))[:24]
        if key not in best or r["downloads"] > best[key]["downloads"]:
            best[key] = r
    rows = sorted(best.values(), key=lambda r: r["score"])
    # 按难度排序后均分为六档, 每档取下载量最高的若干本, 篇幅适中者优先
    n = len(rows)
    result = []
    for li, level in enumerate(LEVELS):
        band = rows[n * li // 6: n * (li + 1) // 6]
        if li <= 1:  # 初级读者优先较短的书
            band.sort(key=lambda r: (r["words"] > 40000, -r["downloads"]))
        else:
            band.sort(key=lambda r: -r["downloads"])
        for r in band[:per_level]:
            r = dict(r)
            r["level"] = level
            r.pop("downloads", None)
            result.append(r)
    json.dump(result, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("candidates", n, "->", len(result))
    for level in LEVELS:
        sel = [r for r in result if r["level"] == level]
        if sel:
            print(level, len(sel), "score %.1f-%.1f" % (min(r["score"] for r in sel), max(r["score"] for r in sel)),
                  "B1 coverage %.1f" % (sum(r["coverage"][2] for r in sel) / len(sel)), "|", "; ".join(r["title"][:28] for r in sel[:4]))


if __name__ == "__main__":
    main()
