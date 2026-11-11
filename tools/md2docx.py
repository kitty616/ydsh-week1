#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
md2docx.py —— 把 docs/ 下的 Markdown 交付物转成 Word（.docx）

为什么自己写而不装 pandoc：项目里六份文档的 Markdown 用了大量中文表格、
代码块与引用块，pandoc 默认样式需要额外 Lua/参考文档才能压成统一版式，
不如按第 2 周已成型的排版规格（A4 / 边距 2.1cm / 正文 11pt 宋体 /
标题微软雅黑 + 深蓝）直接用 python-docx 生成，保证六份文档视觉一致。

版式规格取自 docs/第2周作业任务与提交清单（已填写）.docx：
  页面 A4，四边距 2.1 cm
  正文 Normal：11pt，西文 Times New Roman，中文宋体，行距 1.5
  H1 16pt 粗体 #1F3864；H2 13pt #2E5395；H3 11.5pt #333333（均微软雅黑）
  表格：全网格，表头浅蓝底 #DCE6F1 加粗，字号 9.5pt

用法：
  python tools/md2docx.py docs/预测建模分析报告.md
  python tools/md2docx.py docs/*.md          # 批量
"""

from __future__ import annotations

import os
import re
import sys

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

FONT_HEI = "微软雅黑"
FONT_SONG = "宋体"
FONT_EN = "Times New Roman"
FONT_MONO = "Consolas"

C_H1 = RGBColor(0x1F, 0x38, 0x64)
C_H2 = RGBColor(0x2E, 0x53, 0x95)
C_H3 = RGBColor(0x33, 0x33, 0x33)
C_QUOTE = RGBColor(0x59, 0x59, 0x59)
C_CODE = RGBColor(0x1A, 0x1A, 0x1A)


# ------------------------------------------------------------------ 基础排版

def set_run_font(run, size=None, bold=None, color=None, mono=False, italic=None):
    """同时设置西文与中文字体，避免 Word 里中文回退成默认字体。"""
    en = FONT_MONO if mono else FONT_EN
    ea = FONT_MONO if mono else FONT_SONG
    run.font.name = en
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:ascii"), en)
    rfonts.set(qn("w:hAnsi"), en)
    rfonts.set(qn("w:eastAsia"), ea)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.font.bold = bold
    if italic is not None:
        run.font.italic = italic
    if color is not None:
        run.font.color.rgb = color


def shade(element, fill):
    """给段落或单元格加底色。"""
    pr = element.get_or_add_pPr() if hasattr(element, "get_or_add_pPr") else element
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    pr.append(shd)


def para_shade(p, fill):
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    p._p.get_or_add_pPr().append(shd)


def left_bar(p, color="C9D6EA"):
    """代码块 / 引用块的左侧竖线。"""
    ppr = p._p.get_or_add_pPr()
    borders = OxmlElement("w:pBdr")
    left = OxmlElement("w:left")
    left.set(qn("w:val"), "single")
    left.set(qn("w:sz"), "18")
    left.set(qn("w:space"), "6")
    left.set(qn("w:color"), color)
    borders.append(left)
    ppr.append(borders)


# ------------------------------------------------------------------ 行内标记

INLINE = re.compile(r"(`[^`]+`|\*\*[^*]+\*\*)")


def add_inline(p, text, size=11, color=None, base_bold=False):
    """
    处理行内 `code` 与 **bold**。返回段落本身。
    中文标点里的 ** 常紧贴文字，正则已按非贪婪处理。
    """
    for chunk in INLINE.split(text):
        if not chunk:
            continue
        if chunk.startswith("`") and chunk.endswith("`") and len(chunk) > 2:
            r = p.add_run(chunk[1:-1])
            set_run_font(r, size=size - 0.5, mono=True, color=C_CODE, bold=base_bold)
            # 行内代码加浅灰底
            r.font.highlight_color = None
            rpr = r._element.get_or_add_rPr()
            shd = OxmlElement("w:shd")
            shd.set(qn("w:val"), "clear")
            shd.set(qn("w:fill"), "F2F2F2")
            rpr.append(shd)
        elif chunk.startswith("**") and chunk.endswith("**") and len(chunk) > 4:
            r = p.add_run(chunk[2:-2])
            set_run_font(r, size=size, bold=True, color=color)
        else:
            r = p.add_run(chunk)
            set_run_font(r, size=size, bold=base_bold, color=color)
    return p


# ------------------------------------------------------------------ 块级元素

def add_heading(doc, text, level):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(14 if level == 1 else 10)
    p.paragraph_format.space_after = Pt(6 if level == 1 else 4)
    p.paragraph_format.line_spacing = 1.25
    if level == 1:
        # 一级标题加一条下边框，视觉上分区更清楚
        ppr = p._p.get_or_add_pPr()
        borders = OxmlElement("w:pBdr")
        bottom = OxmlElement("w:bottom")
        bottom.set(qn("w:val"), "single")
        bottom.set(qn("w:sz"), "8")
        bottom.set(qn("w:space"), "4")
        bottom.set(qn("w:color"), "1F3864")
        borders.append(bottom)
        ppr.append(borders)
    size, color = {1: (16, C_H1), 2: (13, C_H2), 3: (11.5, C_H3)}.get(level, (11, C_H3))
    r = p.add_run(re.sub(r"`", "", text))
    set_run_font(r, size=size, bold=True, color=color)
    r.font.name = FONT_HEI
    r._element.get_or_add_rPr().find(qn("w:rFonts")).set(qn("w:eastAsia"), FONT_HEI)
    # 让大纲级别生效，Word 导航窗格能看到目录
    ppr = p._p.get_or_add_pPr()
    ol = OxmlElement("w:outlineLvl")
    ol.set(qn("w:val"), str(level - 1))
    ppr.append(ol)
    return p


def add_title(doc, text):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_after = Pt(10)
    r = p.add_run(text)
    set_run_font(r, size=20, bold=True, color=C_H1)
    r.font.name = FONT_HEI
    r._element.get_or_add_rPr().find(qn("w:rFonts")).set(qn("w:eastAsia"), FONT_HEI)
    return p


def add_body(doc, text, indent_first=False):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.line_spacing_rule = WD_LINE_SPACING.MULTIPLE
    pf.line_spacing = 1.5
    pf.space_after = Pt(6)
    if indent_first:
        pf.first_line_indent = Pt(22)
    add_inline(p, text)
    return p


def add_quote(doc, lines):
    for line in lines:
        p = doc.add_paragraph()
        pf = p.paragraph_format
        pf.left_indent = Cm(0.6)
        pf.space_before = Pt(2)
        pf.space_after = Pt(2)
        pf.line_spacing = 1.35
        add_inline(p, line, size=10.5, color=C_QUOTE)
        left_bar(p)


def add_code_block(doc, lines, lang=""):
    for i, line in enumerate(lines):
        p = doc.add_paragraph()
        pf = p.paragraph_format
        pf.left_indent = Cm(0.4)
        pf.line_spacing = 1.15
        pf.space_before = Pt(4 if i == 0 else 0)
        pf.space_after = Pt(4 if i == len(lines) - 1 else 0)
        r = p.add_run(line if line else " ")
        set_run_font(r, size=9, mono=True, color=C_CODE)
        para_shade(p, "F7F7F7")
        left_bar(p, "B7C7DE")


def new_num_id(doc, abstract_id):
    """
    为一段有序列表申请独立的编号实例。

    为什么需要：所有 "List Number" 段落默认共用样式里的同一个 numId，
    Word 会把全文的有序项当成一个连续序列（第二节的列表接着第一节编到 5、6、7）。
    这里复制一份 abstractNum 的引用，并用 startOverride=1 让每个列表块重新从 1 开始。
    """
    numbering = doc.part.numbering_part.element
    existing = [int(n.get(qn("w:numId"))) for n in numbering.findall(qn("w:num"))]
    nid = (max(existing) + 1) if existing else 1

    num = OxmlElement("w:num")
    num.set(qn("w:numId"), str(nid))
    ref = OxmlElement("w:abstractNumId")
    ref.set(qn("w:val"), str(abstract_id))
    num.append(ref)

    override = OxmlElement("w:lvlOverride")
    override.set(qn("w:ilvl"), "0")
    start = OxmlElement("w:startOverride")
    start.set(qn("w:val"), "1")
    override.append(start)
    num.append(override)

    numbering.append(num)
    return nid


def style_num_id(doc, style_name):
    """取出某个列表样式所引用的 numId。"""
    el = doc.styles[style_name].element
    nid = el.find(qn("w:pPr") + "/" + qn("w:numPr") + "/" + qn("w:numId"))
    if nid is None:
        return None
    return int(nid.get(qn("w:val")))


def abstract_id_of(doc, num_id):
    """由 numId 反查 abstractNumId。"""
    numbering = doc.part.numbering_part.element
    for n in numbering.findall(qn("w:num")):
        if n.get(qn("w:numId")) == str(num_id):
            ref = n.find(qn("w:abstractNumId"))
            if ref is not None:
                return int(ref.get(qn("w:val")))
    return 0


def add_bullet(doc, text, ordered=False, level=0, num_id=None):
    p = doc.add_paragraph(style="List Number" if ordered else "List Bullet")
    pf = p.paragraph_format
    pf.line_spacing_rule = WD_LINE_SPACING.MULTIPLE
    pf.line_spacing = 1.5
    pf.space_after = Pt(3)
    pf.left_indent = Cm(0.75 + 0.6 * level)
    if ordered and num_id is not None:
        numpr = p._p.get_or_add_pPr().get_or_add_numPr()
        numpr.get_or_add_ilvl().val = level
        numpr.get_or_add_numId().val = num_id
    add_inline(p, text)
    return p


def set_cell_bg(cell, fill):
    tcpr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    tcpr.append(shd)


def set_table_borders(table):
    tbl = table._tbl
    tblpr = tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        e = OxmlElement(f"w:{edge}")
        e.set(qn("w:val"), "single")
        e.set(qn("w:sz"), "6")
        e.set(qn("w:space"), "0")
        e.set(qn("w:color"), "9BA7B8")
        borders.append(e)
    tblpr.append(borders)


def add_table(doc, header, rows):
    ncol = len(header)
    table = doc.add_table(rows=1, cols=ncol)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = True
    set_table_borders(table)

    hdr = table.rows[0].cells
    for i, h in enumerate(header):
        cell = hdr[i]
        cell.text = ""
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(2)
        p.paragraph_format.space_after = Pt(2)
        add_inline(p, h, size=9.5, base_bold=True)
        set_cell_bg(cell, "DCE6F1")

    for row in rows:
        cells = table.add_row().cells
        for i in range(ncol):
            cell = cells[i]
            txt = row[i] if i < len(row) else ""
            cell.text = ""
            p = cell.paragraphs[0]
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.space_after = Pt(2)
            p.paragraph_format.line_spacing = 1.15
            add_inline(p, txt, size=9.5)

    # 表后留一点空隙
    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    return table


def add_hr(doc):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(2)
    p.paragraph_format.space_after = Pt(2)
    ppr = p._p.get_or_add_pPr()
    borders = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), "6")
    bottom.set(qn("w:space"), "1")
    bottom.set(qn("w:color"), "D0D7E5")
    borders.append(bottom)
    ppr.append(borders)


def add_page_number_footer(section, doc_title):
    footer = section.footer
    p = footer.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run(doc_title + "　·　第 ")
    set_run_font(r, size=8.5, color=C_QUOTE)
    fld_begin = OxmlElement("w:fldChar")
    fld_begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText")
    instr.set(qn("xml:space"), "preserve")
    instr.text = "PAGE"
    fld_end = OxmlElement("w:fldChar")
    fld_end.set(qn("w:fldCharType"), "end")
    run_el = p.add_run()._element
    run_el.append(fld_begin)
    run_el.append(instr)
    run_el.append(fld_end)
    r2 = p.add_run(" 页")
    set_run_font(r2, size=8.5, color=C_QUOTE)


# ------------------------------------------------------------------ XML 规范化

# OOXML 对 pPr / rPr / tcPr / tblPr 的子元素顺序有硬性要求（ECMA-376 CT_PPrBase 等）。
# python-docx 对 pBdr、shd、outlineLvl 没有提供按序插入的 API，直接 append 会排在末尾，
# 严格校验器会判定文档非法。保存前统一按 schema 顺序重排一次，避免个别阅读器打不开。
_PPR_ORDER = [
    "pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl",
    "numPr", "suppressLineNumbers", "pBdr", "shd", "tabs", "suppressAutoHyphens",
    "kinsoku", "wordWrap", "overflowPunct", "topLinePunct", "autoSpaceDE", "autoSpaceDN",
    "bidi", "adjustRightInd", "snapToGrid", "spacing", "ind", "contextualSpacing",
    "mirrorIndents", "suppressOverlap", "jc", "textDirection", "textAlignment",
    "textboxTightWrap", "outlineLvl", "divId", "cnfStyle", "rPr", "sectPr", "pPrChange",
]
_RPR_ORDER = [
    "rStyle", "rFonts", "b", "bCs", "i", "iCs", "caps", "smallCaps", "strike", "dstrike",
    "outline", "shadow", "emboss", "imprint", "noProof", "snapToGrid", "vanish",
    "webHidden", "color", "spacing", "w", "kern", "position", "sz", "szCs", "highlight",
    "u", "effect", "bdr", "shd", "fitText", "vertAlign", "rtl", "cs", "em", "lang",
    "eastAsianLayout", "specVanish", "oMath",
]
_TCPR_ORDER = [
    "cnfStyle", "tcW", "gridSpan", "hMerge", "vMerge", "tcBorders", "shd", "noWrap",
    "tcMar", "textDirection", "tcFitText", "vAlign", "hideMark", "headers", "cellIns",
    "cellDel", "cellMerge", "tcPrChange",
]
_TBLPR_ORDER = [
    "tblStyle", "tblpPr", "tblOverlap", "bidiVisual", "tblStyleRowBandSize",
    "tblStyleColBandSize", "tblW", "jc", "tblCellSpacing", "tblInd", "tblBorders",
    "shd", "tblLayout", "tblCellMar", "tblLook", "tblCaption", "tblDescription",
    "tblPrChange",
]


def _sort_children(el, order):
    rank = {qn("w:" + n): i for i, n in enumerate(order)}
    kids = list(el)
    kids.sort(key=lambda c: rank.get(c.tag, 900))  # sort 是稳定的，未知元素保持相对次序
    for c in kids:
        el.remove(c)
    for c in kids:
        el.append(c)


def normalize_xml_order(doc):
    targets = {
        qn("w:pPr"): _PPR_ORDER,
        qn("w:rPr"): _RPR_ORDER,
        qn("w:tcPr"): _TCPR_ORDER,
        qn("w:tblPr"): _TBLPR_ORDER,
    }
    roots = [doc.element]
    for s in doc.sections:
        roots.append(s.footer._element)
        roots.append(s.header._element)
    for root in roots:
        for el in root.iter():
            order = targets.get(el.tag)
            if order:
                _sort_children(el, order)


# ------------------------------------------------------------------ 主解析

def split_row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    # 支持 \| 转义
    parts = re.split(r"(?<!\\)\|", s)
    return [c.strip().replace("\\|", "|") for c in parts]


def is_sep_row(line):
    cells = split_row(line)
    return all(re.fullmatch(r":?-{2,}:?", c.replace(" ", "")) or c == "" for c in cells) and "-" in line


def convert(md_path, docx_path=None):
    with open(md_path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    docx_path = docx_path or os.path.splitext(md_path)[0] + ".docx"

    doc = Document()
    # 页面与默认样式
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Cm(21.0), Cm(29.7)
    sec.top_margin = sec.bottom_margin = Cm(2.1)
    sec.left_margin = sec.right_margin = Cm(2.1)

    normal = doc.styles["Normal"]
    normal.font.name = FONT_EN
    normal.font.size = Pt(11)
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), FONT_SONG)

    # 有序列表的抽象编号定义：沿用 List Number 样式引用的那一份（缩进 / 编号格式一致）
    _base_nid = style_num_id(doc, "List Number")
    ord_abstract_id = abstract_id_of(doc, _base_nid) if _base_nid is not None else 0

    i = 0
    n = len(lines)
    first_h1_done = False
    while i < n:
        line = lines[i]
        s = line.strip()

        # 空行
        if not s:
            i += 1
            continue

        # 代码块
        if s.startswith("```"):
            lang = s[3:].strip()
            block = []
            i += 1
            while i < n and not lines[i].strip().startswith("```"):
                block.append(lines[i].rstrip())
                i += 1
            i += 1
            add_code_block(doc, block, lang)
            continue

        # 标题
        m = re.match(r"^(#{1,4})\s+(.*)$", s)
        if m:
            level = len(m.group(1))
            text = m.group(2).strip()
            if level == 1 and not first_h1_done:
                add_title(doc, text)
                first_h1_done = True
            else:
                add_heading(doc, text, min(level, 3))
            i += 1
            continue

        # 分隔线
        if re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", s):
            add_hr(doc)
            i += 1
            continue

        # 表格
        if s.startswith("|") and i + 1 < n and is_sep_row(lines[i + 1]):
            header = split_row(s)
            i += 2
            rows = []
            while i < n and lines[i].strip().startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            add_table(doc, header, rows)
            continue

        # 引用块
        if s.startswith(">"):
            q = []
            while i < n and lines[i].strip().startswith(">"):
                q.append(lines[i].strip()[1:].strip())
                i += 1
            add_quote(doc, q)
            continue

        # 有序 / 无序列表
        m = re.match(r"^(\s*)([-*+])\s+(.*)$", line)
        if m:
            add_bullet(doc, m.group(3), ordered=False, level=len(m.group(1)) // 2)
            i += 1
            continue
        if re.match(r"^(\s*)(\d+)\.\s+(.*)$", line):
            # 连续的有序项算同一个列表，共用一个重新从 1 开始的编号
            nid = new_num_id(doc, ord_abstract_id)
            while i < n and re.match(r"^(\s*)(\d+)\.\s+(.*)$", lines[i]):
                mm = re.match(r"^(\s*)(\d+)\.\s+(.*)$", lines[i])
                add_bullet(doc, mm.group(3), ordered=True,
                           level=len(mm.group(1)) // 2, num_id=nid)
                i += 1
            continue

        # 普通段落
        add_body(doc, s)
        i += 1

    add_page_number_footer(sec, os.path.splitext(os.path.basename(docx_path))[0])
    normalize_xml_order(doc)
    doc.save(docx_path)
    return docx_path


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    for path in args:
        if not os.path.exists(path):
            print(f"跳过（不存在）：{path}")
            continue
        out = convert(path)
        size = os.path.getsize(out) / 1024
        print(f"{os.path.basename(path)}  ->  {os.path.basename(out)}  ({size:.1f} KB)")
