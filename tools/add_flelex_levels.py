#!/usr/bin/env python3
"""把 FLELex (CEFR 分级法语词库, CC BY-NC-SA 4.0) 合并进 fr_words.db, 新增 TCF/TEF A1-C2 分级

用法: python3 add_flelex_levels.py <FleLex_TT_Beacco.tsv> <fr_words.db> <fra-zho.index> <fra-zho.dict.dz>
"""
import gzip
import re
import sqlite3
import sys

B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
LEVELS = [("CEFR_A1", "TCF/TEF A1", "#43A047", "#2E7D32"), ("CEFR_A2", "TCF/TEF A2", "#00897B", "#00695C"),
          ("CEFR_B1", "TCF/TEF B1", "#1E88E5", "#1565C0"), ("CEFR_B2", "TCF/TEF B2", "#8E24AA", "#6A1B9A"),
          ("CEFR_C1", "TCF/TEF C1", "#F4511E", "#BF360C"), ("CEFR_C2", "TCF/TEF C2", "#E53935", "#B71C1C")]
POS = {"NOM": "n.", "VER": "v.", "ADJ": "adj.", "ADV": "adv.", "PRO": "pron.", "INT": "interj.", "PRP": "prép.", "KON": "conj."}


def b64(s):
    v = 0
    for c in s:
        v = v * 64 + B64.index(c)
    return v


def zh_glosses(index_path, dict_path):
    """法汉词典中每个词的中文释义"""
    data = gzip.open(dict_path).read()
    out = {}
    for line in open(index_path, encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) < 3 or p[0].startswith("00database"):
            continue
        text = data[b64(p[1]):b64(p[1]) + b64(p[2])].decode("utf-8", "replace")
        zh = []
        for l in text.split("\n")[1:]:
            l = re.sub(r"^\s*\d+\.\s*", "", l).strip()
            if re.search(r"[一-鿿]", l) and len(l) < 60:
                zh.append(l)
        if zh:
            out.setdefault(p[0].lower(), "; ".join(zh[:3]))
    return out


def main():
    tsv, db_path, idx, dz = sys.argv[1:5]
    zh = zh_glosses(idx, dz)
    db = sqlite3.connect(db_path)
    existing = {}
    for w, m in db.execute("SELECT word, meaning FROM words"):
        existing.setdefault(w.lower(), m)
    db.execute("DELETE FROM words WHERE _level LIKE 'CEFR_%'")
    db.execute("DELETE FROM word_levels WHERE level LIKE 'CEFR_%'")
    for code, name, day, night in LEVELS:
        db.execute("INSERT INTO word_levels (level, name, day_text_color, night_text_color) VALUES (?,?,?,?)", (code, name, day, night))
    n = 0
    for line in open(tsv, encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) < 10 or p[0] == "word" or p[9] not in ("A1", "A2", "B1", "B2", "C1", "C2"):
            continue
        word = p[0].strip()
        if not re.match(r"^[a-zàâäèéêëîïôœùûüÿç'’ -]+$", word.lower()) or len(word) < 2:
            continue
        meaning = existing.get(word.lower()) or zh.get(word.lower()) or ""
        pos = POS.get(p[1].split(":")[0], "")
        if meaning and pos and not meaning.startswith(pos[:2]):
            meaning = pos + " " + meaning
        db.execute("INSERT OR IGNORE INTO words (word, _level, pronounce, meaning, cls, oxf) VALUES (?,?,?,?,0,0)",
                   (word, "CEFR_" + p[9], "", meaning or pos))
        n += 1
    total = db.execute("SELECT COUNT(DISTINCT word) FROM words").fetchone()[0]
    db.execute("UPDATE meta_info SET word_count = ?, _desc = ?", (total, "法语透析词库, 含 TCF/TEF A1-C2 (FLELex)、TEF、大学法语四级等分级词汇."))
    db.commit()
    db.execute("VACUUM")
    print("added", n, "CEFR words; total distinct", total)
    for r in db.execute("SELECT _level, COUNT(*), SUM(meaning != '' AND meaning NOT IN ('n.','v.','adj.','adv.')) FROM words GROUP BY _level"):
        print(r)


if __name__ == "__main__":
    main()
