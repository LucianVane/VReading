// VReading 阅读脚本: 单词包裹、点击查词、取句、分页、划线笔记、搜索
// 句子提取复用原 App 的 sentence.js (getSelectionSentence)
(function () {
    if (window.ER && window.ER.__ready) { return; }
    var ER = window.ER = { __ready: true };
    var cfg = { clickable: true, paginate: false, levelMap: {}, blockLinks: false, lang: 'en' };
    var CJK_RE = /[\u3040-\u30ff\u3400-\u9fff\uff66-\uff9f]/;
    var segmenter = null;
    var ignoreSelectionUntil = 0;
    var selTimer = null;
    var wordSelected = false;
    var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEXTAREA: 1, INPUT: 1, SELECT: 1, SVG: 1, svg: 1, CODE: 1, PRE: 1, BUTTON: 1, IFRAME: 1, CANVAS: 1, VIDEO: 1, AUDIO: 1, TITLE: 1 };
    var WORD_RE = /[A-Za-zÀ-ɏ][A-Za-zÀ-ɏ'’-]*/g;

    function post(type, data) {
        data = data || {};
        data.type = type;
        try { window.webkit.messageHandlers.er.postMessage(data); } catch (e) { }
    }

    function scroller() { return document.scrollingElement || document.documentElement; }

    // ---------- 单词包裹 ----------
    // 日语没有空格, 使用 Intl.Segmenter 分词后包裹
    function wrapSegmented(node, text) {
        if (!segmenter) { segmenter = new Intl.Segmenter('ja', { granularity: 'word' }); }
        var frag = document.createDocumentFragment(), changed = false;
        var it = segmenter.segment(text)[Symbol.iterator](), r;
        while (!(r = it.next()).done) {
            var seg = r.value;
            if (seg.isWordLike && (CJK_RE.test(seg.segment) || /[A-Za-z]/.test(seg.segment))) {
                var span = document.createElement('span');
                span.className = 'erw';
                span.appendChild(document.createTextNode(seg.segment));
                frag.appendChild(span);
                changed = true;
            } else {
                frag.appendChild(document.createTextNode(seg.segment));
            }
        }
        if (changed) { node.parentNode.replaceChild(frag, node); }
    }

    function wrapTextNode(node) {
        var text = node.nodeValue;
        if (text && cfg.lang === 'ja' && CJK_RE.test(text) && window.Intl && Intl.Segmenter) {
            wrapSegmented(node, text);
            return;
        }
        if (!text || !/[A-Za-zÀ-ɏ]/.test(text)) { return; }
        WORD_RE.lastIndex = 0;
        var frag = document.createDocumentFragment();
        var last = 0, m, changed = false;
        while ((m = WORD_RE.exec(text)) !== null) {
            var w = m[0].replace(/['’-]+$/, '');
            if (!w.length) { continue; }
            if (m.index > last) { frag.appendChild(document.createTextNode(text.slice(last, m.index))); }
            var span = document.createElement('span');
            var cls = 'erw';
            var lv = cfg.levelMap[w.toLowerCase()];
            if (lv) { cls += ' erl erl-' + lv; }
            span.className = cls;
            span.appendChild(document.createTextNode(w));
            frag.appendChild(span);
            last = m.index + w.length;
            changed = true;
        }
        if (!changed) { return; }
        if (last < text.length) { frag.appendChild(document.createTextNode(text.slice(last))); }
        node.parentNode.replaceChild(frag, node);
    }

    function collectTextNodes(root, skipWrapped) {
        var out = [];
        if (!root) { return out; }
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: function (n) {
                var p = n.parentNode;
                while (p && p !== root) {
                    if (SKIP[p.nodeName] || SKIP[p.nodeName.toUpperCase()]) { return NodeFilter.FILTER_REJECT; }
                    if (skipWrapped && p.classList && p.classList.contains('erw')) { return NodeFilter.FILTER_REJECT; }
                    p = p.parentNode;
                }
                return NodeFilter.FILTER_ACCEPT;
            }
        });
        var n;
        while ((n = walker.nextNode())) { out.push(n); }
        return out;
    }

    ER.wrapAll = function () {
        if (!document.body) { return 0; }
        var nodes = collectTextNodes(document.body, true);
        for (var i = 0; i < nodes.length; i++) { wrapTextNode(nodes[i]); }
        return nodes.length;
    };

    ER.setLevelMap = function (map) {
        cfg.levelMap = map || {};
        var spans = document.querySelectorAll('span.erw');
        for (var i = 0; i < spans.length; i++) {
            var s = spans[i];
            var lv = cfg.levelMap[s.textContent.toLowerCase()];
            s.className = lv ? 'erw erl erl-' + lv : 'erw';
        }
    };

    ER.setClickable = function (b) { cfg.clickable = !!b; };
    ER.setBlockLinks = function (b) { cfg.blockLinks = !!b; };

    // ---------- 文本偏移 (笔记定位) ----------
    function allTextNodes() {
        var out = [];
        if (!document.body) { return out; }
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var n;
        while ((n = walker.nextNode())) { out.push(n); }
        return out;
    }

    function pointToOffset(container, offset) {
        var r = document.createRange();
        r.setStart(document.body, 0);
        r.setEnd(container, offset);
        return r.toString().length;
    }

    function rangeFromOffsets(start, end) {
        var nodes = allTextNodes();
        var total = 0, r = document.createRange(), started = false;
        for (var i = 0; i < nodes.length; i++) {
            var len = nodes[i].nodeValue.length;
            if (!started && start <= total + len) {
                r.setStart(nodes[i], Math.max(0, start - total));
                started = true;
            }
            if (started && end <= total + len) {
                r.setEnd(nodes[i], Math.max(0, end - total));
                return r;
            }
            total += len;
        }
        return started ? r : null;
    }

    function selectionInfo() {
        var sel = window.getSelection();
        if (!sel || sel.rangeCount === 0 || sel.isCollapsed) { return null; }
        var range = sel.getRangeAt(0);
        var text = sel.toString();
        if (!text.trim()) { return null; }
        var rect = range.getBoundingClientRect();
        var sentence = '';
        try { sentence = getSelectionSentence(); } catch (e) { }
        return {
            text: text, sentence: sentence,
            start: pointToOffset(range.startContainer, range.startOffset),
            end: pointToOffset(range.endContainer, range.endOffset),
            x: rect.left, y: rect.top, w: rect.width, h: rect.height
        };
    }

    // ---------- 点击 ----------
    function closest(el, sel) {
        while (el && el.nodeType === 1) {
            if (el.matches(sel)) { return el; }
            el = el.parentElement;
        }
        return null;
    }

    document.addEventListener('click', function (e) {
        var sel = window.getSelection();
        if (sel && !sel.isCollapsed) {
            if (!wordSelected && Date.now() > ignoreSelectionUntil) {
                // 用户选中的文本: 点击只取消选择
                sel.removeAllRanges();
                post('selection', { text: '' });
                e.preventDefault();
                e.stopPropagation();
                return;
            }
            sel.removeAllRanges();
            wordSelected = false;
        }
        var hl = closest(e.target, '.erhl');
        if (hl && cfg.paginate) {
            e.preventDefault();
            e.stopPropagation();
            post('note', { id: hl.getAttribute('data-id') });
            return;
        }
        // 只有带 href 的才是链接; <a id> 锚点 (如 Gutenberg 书中的行号) 不影响查词
        var link = closest(e.target, 'a[href]');
        var word = closest(e.target, '.erw');
        if (word && cfg.clickable && (!link || cfg.blockLinks)) {
            e.preventDefault();
            e.stopPropagation();
            var range = document.createRange();
            range.selectNodeContents(word);
            ignoreSelectionUntil = Date.now() + 800;
            sel.removeAllRanges();
            sel.addRange(range);
            wordSelected = true;
            var sentence = '';
            try { sentence = getSelectionSentence(); } catch (err) { }
            var rect = word.getBoundingClientRect();
            post('word', { word: word.textContent, sentence: sentence, level: (word.className.match(/erl-(\S+)/) || [])[1] || '', x: rect.left, y: rect.top, w: rect.width, h: rect.height });
            return;
        }
        if (link) {
            if (cfg.blockLinks) { e.preventDefault(); post('blockedLink', { href: link.href }); }
            return;
        }
        if (cfg.paginate) {
            post('tap', { x: e.clientX, y: e.clientY, w: window.innerWidth, h: window.innerHeight });
        }
    }, true);

    document.addEventListener('selectionchange', function () {
        if (Date.now() < ignoreSelectionUntil) { return; }
        wordSelected = false;
        clearTimeout(selTimer);
        selTimer = setTimeout(function () {
            var info = selectionInfo();
            post('selection', info || { text: '' });
        }, 450);
    });

    ER.clearSelection = function () {
        var s = window.getSelection();
        if (s) { s.removeAllRanges(); }
    };

    // ---------- 分页 ----------
    ER.pageCount = function () {
        var w = window.innerWidth;
        var byScroll = Math.max(1, Math.round(scroller().scrollWidth / w));
        // 以最后一个内容的位置计算页数, 避免末尾出现空白页
        var r = document.createRange();
        r.selectNodeContents(document.body);
        var rects = r.getClientRects(), sl = scroller().scrollLeft, maxRight = 0;
        for (var i = 0; i < rects.length; i++) {
            if (rects[i].width > 0 && rects[i].height > 0) { maxRight = Math.max(maxRight, rects[i].right + sl); }
        }
        if (maxRight <= 0) { return byScroll; }
        return Math.max(1, Math.min(byScroll, Math.ceil((maxRight - 1) / w)));
    };

    ER.goToPage = function (n) {
        var count = ER.pageCount();
        n = Math.max(0, Math.min(n, count - 1));
        scroller().scrollLeft = n * window.innerWidth;
        return { page: n, count: count };
    };

    ER.currentPage = function () {
        return Math.round(scroller().scrollLeft / window.innerWidth);
    };

    function pageOfRect(rect) {
        return Math.floor((rect.left + scroller().scrollLeft + 1) / window.innerWidth);
    }

    ER.pageOfOffset = function (off) {
        var r = rangeFromOffsets(off, off + 1);
        if (!r) { return 0; }
        var rects = r.getClientRects();
        return rects.length ? pageOfRect(rects[0]) : 0;
    };

    ER.pageOfFragment = function (id) {
        var el = document.getElementById(id) || document.getElementsByName(id)[0];
        if (!el) { return 0; }
        return pageOfRect(el.getBoundingClientRect());
    };

    /// 当前页第一个字符的偏移, 用于书签
    ER.pageInfo = function () {
        var w = window.innerWidth, h = window.innerHeight;
        var a = document.caretRangeFromPoint(30, 40);
        var b = document.caretRangeFromPoint(w - 30, h - 40);
        var text = '', start = 0;
        if (a) {
            start = pointToOffset(a.startContainer, a.startOffset);
            if (b) {
                var r = document.createRange();
                r.setStart(a.startContainer, a.startOffset);
                r.setEnd(b.startContainer, b.startOffset);
                text = r.toString();
            }
        }
        return { offset: start, text: text.replace(/\s+/g, ' ').trim().slice(0, 120) };
    };

    // ---------- 笔记 / 划线 ----------
    function wrapRange(range, id, color) {
        var nodes = allTextNodes().filter(function (n) { return range.intersectsNode(n); });
        nodes.forEach(function (n) {
            var s = n === range.startContainer ? range.startOffset : 0;
            var e = n === range.endContainer ? range.endOffset : n.nodeValue.length;
            if (e <= s) { return; }
            var target = n;
            if (s > 0) { target = target.splitText(s); e -= s; }
            if (e < target.nodeValue.length) { target.splitText(e); }
            var span = document.createElement('span');
            span.className = 'erhl erhl-' + color;
            span.setAttribute('data-id', id);
            target.parentNode.replaceChild(span, target);
            span.appendChild(target);
        });
    }

    ER.applyNotes = function (notes) {
        (notes || []).forEach(function (n) {
            var r = rangeFromOffsets(n.start, n.end);
            if (r) { wrapRange(r, n.id, n.color); }
        });
    };

    ER.removeNote = function (id) {
        var spans = document.querySelectorAll('.erhl[data-id="' + id + '"]');
        for (var i = 0; i < spans.length; i++) {
            var s = spans[i], p = s.parentNode;
            while (s.firstChild) { p.insertBefore(s.firstChild, s); }
            p.removeChild(s);
            p.normalize();
        }
    };

    ER.setNoteColor = function (id, color) {
        var spans = document.querySelectorAll('.erhl[data-id="' + id + '"]');
        for (var i = 0; i < spans.length; i++) { spans[i].className = 'erhl erhl-' + color; }
    };

    // ---------- 搜索 ----------
    ER.find = function (q) {
        if (!q) { return -1; }
        var full = allTextNodes().map(function (n) { return n.nodeValue; }).join('');
        var idx = full.toLowerCase().indexOf(q.toLowerCase());
        if (idx < 0) { return -1; }
        var r = rangeFromOffsets(idx, idx + q.length);
        if (!r) { return -1; }
        ignoreSelectionUntil = Date.now() + 1500;
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(r);
        var rects = r.getClientRects();
        return rects.length ? pageOfRect(rects[0]) : 0;
    };

    // ---------- 样式 ----------
    ER.setStyle = function (css) {
        var st = document.getElementById('er-style');
        if (!st) {
            st = document.createElement('style');
            st.id = 'er-style';
            (document.head || document.documentElement).appendChild(st);
        }
        st.textContent = css;
    };

    // epub 的 xhtml 通常没有 viewport, 需强制按设备宽度排版
    ER.fixViewport = function () {
        var m = document.querySelector('meta[name=viewport]');
        if (!m) {
            m = document.createElement('meta');
            m.setAttribute('name', 'viewport');
            (document.head || document.documentElement).appendChild(m);
        }
        m.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no');
    };

    ER.setup = function (opts) {
        if (opts.paginate) { ER.fixViewport(); }
        cfg.paginate = !!opts.paginate;
        cfg.clickable = opts.clickable !== false;
        cfg.blockLinks = !!opts.blockLinks;
        cfg.levelMap = opts.levelMap || {};
        cfg.lang = opts.lang || 'en';
        if (opts.css) { ER.setStyle(opts.css); }
        ER.wrapAll();
        ER.applyNotes(opts.notes);
        if (cfg.paginate) {
            var lastCount = ER.pageCount();
            var check = function () {
                var c = ER.pageCount();
                if (c !== lastCount) { lastCount = c; post('pages', { count: c, page: ER.currentPage() }); }
            };
            window.addEventListener('load', check);
            var imgs = document.images;
            for (var i = 0; i < imgs.length; i++) { imgs[i].addEventListener('load', check); }
        }
        return { count: ER.pageCount() };
    };
})();
