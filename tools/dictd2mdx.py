#!/usr/bin/env python3
"""把 FreeDict 的 dictd 词典 (.index + .dict.dz) 转换为 MDict 2.0 (.mdx, UTF-8, zlib, 不加密)

用法: python3 dictd2mdx.py <name.index> <name.dict.dz> <输出.mdx> "<标题>" [--strip-ipa]
"""
import gzip
import html
import re
import struct
import sys
import time
import zlib

B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def b64(s):
    v = 0
    for c in s:
        v = v * 64 + B64.index(c)
    return v


def be64(v):
    return struct.pack(">Q", v)


def zblock(data):
    return b"\x02\x00\x00\x00" + struct.pack(">I", zlib.adler32(data) & 0xFFFFFFFF) + zlib.compress(data, 9)


def entry_html(word, text, strip_ipa):
    lines = [l.rstrip() for l in text.strip("\n").split("\n")]
    head, body = lines[0], lines[1:]
    if strip_ipa:
        head = re.sub(r"\s*/[^/]*/", "", head)
        head = re.sub(r"\s*\[[a-z0-9]+\]", "", head)
        head = re.sub(r"\s*\(word containing[^)]*\)", "", head)
        head = re.sub(r"\s+,", ",", head).strip(" ,")
    out = ['<div class="fd-head"><b>%s</b></div>' % html.escape(head)]
    for l in body:
        t = l.strip()
        if not t:
            continue
        cls = "fd-pos" if re.match(r"^(\(|<)", t) else ("fd-num" if re.match(r"^\d+\.", t) else "fd-def")
        out.append('<div class="%s">%s</div>' % (cls, html.escape(t)))
    return "\n".join(out)


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        sys.exit(1)
    index_path, dict_path, out_path, title = sys.argv[1:5]
    strip_ipa = "--strip-ipa" in sys.argv
    data = gzip.open(dict_path).read()
    entries = []
    for line in open(index_path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 3:
            continue
        word = parts[0].strip()
        if not word or word.startswith("00database"):
            continue
        text = data[b64(parts[1]):b64(parts[1]) + b64(parts[2])].decode("utf-8", "replace")
        entries.append((word, entry_html(word, text, strip_ipa)))
    entries.sort(key=lambda e: (e[0].lower(), e[0]))

    # 记录数据与偏移
    records, offsets, pos = [], [], 0
    for _, h in entries:
        b = h.encode("utf-8") + b"\x00"
        offsets.append(pos)
        records.append(b)
        pos += len(b)

    # key blocks
    key_blocks, key_info = [], b""
    cur, cur_keys = b"", []
    for i, (w, _) in enumerate(entries):
        cur += be64(offsets[i]) + w.encode("utf-8") + b"\x00"
        cur_keys.append(w)
        if len(cur) > 32 * 1024 or i == len(entries) - 1:
            comp = zblock(cur)
            first, last = cur_keys[0].encode("utf-8"), cur_keys[-1].encode("utf-8")
            key_info += be64(len(cur_keys)) + struct.pack(">H", len(first)) + first + b"\x00" \
                + struct.pack(">H", len(last)) + last + b"\x00" + be64(len(comp)) + be64(len(cur))
            key_blocks.append(comp)
            cur, cur_keys = b"", []
    key_info_comp = zblock(key_info)
    key_blocks_data = b"".join(key_blocks)

    # record blocks
    rec_blocks, rec_info, cur = [], b"", b""
    for i, r in enumerate(records):
        cur += r
        if len(cur) > 64 * 1024 or i == len(records) - 1:
            comp = zblock(cur)
            rec_info += be64(len(comp)) + be64(len(cur))
            rec_blocks.append(comp)
            cur = b""
    rec_data = b"".join(rec_blocks)

    header = ('<Dictionary GeneratedByEngineVersion="2.0" RequiredEngineVersion="2.0" Encrypted="0" Encoding="UTF-8" '
              'Format="Html" Stripkey="Yes" CreationDate="%s" Compact="No" Compat="No" KeyCaseSensitive="No" '
              'Description="%s (FreeDict, GPL)" Title="%s" DataSourceFormat="106" StyleSheet="" Left2Right="Yes" RegisterBy=""/>\r\n\x00'
              % (time.strftime("%Y-%m-%d"), html.escape(title), html.escape(title))).encode("utf-16-le")

    with open(out_path, "wb") as f:
        f.write(struct.pack(">I", len(header)) + header + struct.pack("<I", zlib.adler32(header) & 0xFFFFFFFF))
        kh = be64(len(key_blocks)) + be64(len(entries)) + be64(len(key_info)) + be64(len(key_info_comp)) + be64(len(key_blocks_data))
        f.write(kh + struct.pack(">I", zlib.adler32(kh) & 0xFFFFFFFF))
        f.write(key_info_comp + key_blocks_data)
        f.write(be64(len(rec_blocks)) + be64(len(entries)) + be64(len(rec_info)) + be64(len(rec_data)))
        f.write(rec_info + rec_data)
    print("%s: %d entries" % (out_path, len(entries)))


if __name__ == "__main__":
    main()
