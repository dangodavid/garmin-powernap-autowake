import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

//! Colour policy. Instinct 3 Solar (the only semi-octagon screen in the
//! manifest) is a 1-bit black/white display: every colour except black is
//! drawn white there, otherwise blue/red/grey text quantises to black and
//! disappears.
module Palette {

    var _mono as Boolean? = null;

    function isMono() as Boolean {
        if (_mono == null) {
            var mono = false;
            try {
                mono = (System.getDeviceSettings().screenShape == System.SCREEN_SHAPE_SEMI_OCTAGON);
            } catch (e instanceof Lang.Exception) {
                mono = false;
            }
            _mono = mono;
        }
        return _mono as Boolean;
    }

    //! Foreground colour to use for `color`. `invert` draws black (used for
    //! text on top of a flashing light background).
    function fg(color as Graphics.ColorType, invert as Boolean) as Graphics.ColorType {
        if (invert) {
            return Graphics.COLOR_BLACK;
        }
        if (isMono()) {
            return (color == Graphics.COLOR_BLACK) ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        }
        return color;
    }
}

//! One line of a screen: a text (with shorter alternatives), a divider, or
//! an empty spacer the view draws into (the start-screen arrows).
class LayoutLine {
    var texts as Array<String>;                    // longest first
    var fonts as Array<Graphics.FontDefinition>;   // largest first
    var color as Graphics.ColorType;
    var priority as Number;                        // >= ScreenLayout.KEEP is never dropped
    var isDivider as Boolean;                      // divider or spacer: no text
    var dividerHalf as Number = 0;
    var spacerH as Number = 0;                     // > 0: spacer of this height, drawn by the view
    var linkedTo as Number = -1;                   // divider: hidden whenever this line is hidden
    var gapAfter as Number = -1;                   // -1 = layout default

    // Solved by ScreenLayout.solve()
    var forceHidden as Boolean = false;   // optional line too wide for its row
    var visible as Boolean = true;
    var fontIndex as Number = 0;
    var y as Number = 0;          // slot top
    var slotH as Number = 0;
    var drawFont as Graphics.FontDefinition;
    var drawText as String;
    var drawX as Number = 0;                       // text centre, or divider start
    var drawX1 as Number = 0;                      // divider end
    var drawY as Number = 0;
    var fits as Boolean = true;
    var shortened as Boolean = false;              // a shorter text variant had to be used

    function initialize(texts as Array<String>, fonts as Array<Graphics.FontDefinition>,
                        color as Graphics.ColorType, priority as Number, isDivider as Boolean) {
        self.texts = texts;
        self.fonts = fonts;
        self.color = color;
        self.priority = priority;
        self.isDivider = isDivider;
        drawFont = fonts[0];
        drawText = texts[0];
    }
}

//! Vertical list layout that fits any supported screen.
//!
//! * The footer is placed as low as possible where its text still fits the
//!   visible width of the display (round bezel, octagon corners).
//! * Lines are centred in the band between the top margin and the footer.
//!   If they do not fit, lines below IMPORTANT are dropped first (lowest
//!   priority first), then lines move to smaller fonts, and only then are
//!   IMPORTANT lines dropped. Lines at or above KEEP are never dropped.
//! * A KEEP line too wide for its row (e.g. next to the Instinct lens) makes
//!   the layout hide optional lines until the block moves to rows it fits.
//! * Next to the Instinct lens the block first moves down (the rows below
//!   the lens are wider) before any line is hidden.
//! * Lines hidden for their row width on the way are brought back at the end
//!   (highest priority first) when the final layout has room for them, if
//!   need be by hiding lower-priority lines instead.
//! * The footer is solved once per solve(): the longest variant that fits
//!   within the bottom rows (it never climbs above FOOTER_MIN_PCT).
//! * A divider belongs to the line above it and is clipped to its row.
//! * Each text line then picks the largest font/text variant whose ink fits
//!   the visible width at its own rows (round chord, Instinct subscreen).
class ScreenLayout {

    static const KEEP = 100;
    //! Lines from this priority on (the alarm promise, warnings) survive
    //! until every font has shrunk.
    static const IMPORTANT = 90;
    //! The footer never moves above this share of the height: a hint that
    //! does not fit lower uses a shorter variant instead of eating the band.
    private const FOOTER_MIN_PCT = 72;

    private var _w as Number;
    private var _h as Number;
    private var _cx as Number;
    private var _cy as Number;
    private var _shape as Number;
    private var _hasSub as Boolean = false;          // Instinct subscreen window
    private var _subX as Number = 0;
    private var _subY as Number = 0;
    private var _subW as Number = 0;
    private var _subH as Number = 0;
    private var _lines as Array<LayoutLine> = [] as Array<LayoutLine>;
    private var _gap as Number;
    private var _topPct as Number;
    private var _edgeMargin as Number = 6;
    private var _clipRadius as Number = 0;           // > 0: keep text inside this circle

    private var _footerText as String? = null;       // the variant chosen by solve()
    private var _footerTexts as Array<String>? = null;
    private var _footerPreferBottom as Boolean = false;  // see setFooterChoices
    private var _footerColor as Graphics.ColorType = Graphics.COLOR_LT_GRAY;
    private var _footerFont as Graphics.FontDefinition = Graphics.FONT_XTINY;
    private var _footerX as Number = 0;
    private var _footerY as Number = 0;
    private var _footerFits as Boolean = true;

    private var _bandTop as Number = 0;
    private var _bandBottom as Number = 0;
    private var _overflow as Boolean = false;
    private var _passes as Number = 0;               // solveOnce() calls in the last solve()
    private var _fitCalls as Number = 0;             // fitLine() + probe calls in the last solve()
    // inkBounds() results for the current solve(), keyed y * 1024 + fh: the
    // same rows are measured again and again across passes (and every
    // screen is solved once a second, against the Instinct watchdog).
    private var _inkCache as Dictionary<Number, Array<Number> >? = null;

    function initialize(w as Number, h as Number, topPct as Number) {
        _w = w;
        _h = h;
        _cx = w / 2;
        _cy = h / 2;
        _topPct = topPct;
        _gap = h / 45;
        if (_gap < 3) { _gap = 3; }
        _shape = System.SCREEN_SHAPE_ROUND;
        try {
            _shape = System.getDeviceSettings().screenShape as Number;
        } catch (e instanceof Lang.Exception) {
            // keep round
        }
        if (WatchUi has :getSubscreen) {
            try {
                var sub = WatchUi.getSubscreen();
                if (sub != null) {
                    var sx = sub.x;
                    var sy = sub.y;
                    var sw = sub.width;
                    var sh = sub.height;
                    if (sx != null && sy != null && sw != null && sh != null) {
                        _subX = sx as Number;
                        _subY = sy as Number;
                        _subW = sw as Number;
                        _subH = sh as Number;
                        _hasSub = (_subW > 0 && _subH > 0);
                    }
                }
            } catch (e instanceof Lang.Exception) {
                _hasSub = false;
            }
        }
    }

    // -- Building -------------------------------------------------------

    function addText(texts as Array<String>, fonts as Array<Graphics.FontDefinition>,
                     color as Graphics.ColorType, priority as Number) as LayoutLine {
        var line = new LayoutLine(texts, fonts, color, priority, false);
        _lines.add(line);
        return line;
    }

    //! A thin line under the previous line (the title): it is hidden with it.
    function addDivider(halfWidthPct as Number, color as Graphics.ColorType, priority as Number) as LayoutLine {
        var line = new LayoutLine([""] as Array<String>,
            [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, color, priority, true);
        line.dividerHalf = _w * halfWidthPct / 100;
        line.linkedTo = _lines.size() - 1;
        _lines.add(line);
        return line;
    }

    //! Empty slot of the given height; after solve() its y tells the view
    //! where to draw (e.g. an arrow). Never drawn by the layout itself.
    function addSpacer(height as Number, priority as Number) as LayoutLine {
        var line = new LayoutLine([""] as Array<String>,
            [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, Graphics.COLOR_TRANSPARENT, priority, true);
        line.spacerH = (height > 0) ? height : 1;
        _lines.add(line);
        return line;
    }

    function setFooter(text as String, color as Graphics.ColorType) as Void {
        setFooterTexts([text] as Array<String>, color);
    }

    //! Footer with shorter alternatives (longest first) for a hint whose full
    //! wording matters: the longest one that fits, moving up as far as
    //! FOOTER_MIN_PCT of the height (round bottoms are narrow).
    function setFooterTexts(texts as Array<String>, color as Graphics.ColorType) as Void {
        _footerTexts = texts;
        _footerText = texts[0];
        _footerColor = color;
        _footerPreferBottom = false;
    }

    //! Footer alternatives on a screen whose content matters more than the
    //! hint's wording (the summary): the longest one that fits the bottom
    //! row, else the shortest one moved up as little as needed.
    function setFooterChoices(texts as Array<String>, color as Graphics.ColorType) as Void {
        setFooterTexts(texts, color);
        _footerPreferBottom = true;
    }

    //! Extra clearance from the display edge.
    function setEdgeMargin(px as Number) as Void {
        _edgeMargin = px;
    }

    //! Keep all text inside a circle of this radius around the centre (the
    //! inner edge of a progress ring drawn by the view).
    function setClipRadius(r as Number) as Void {
        _clipRadius = r;
    }

    // -- Solving --------------------------------------------------------

    //! Lay out; optional lines that cannot fit their row even with the
    //! smallest font and shortest text are hidden and the layout re-solved.
    function solve(dc as Graphics.Dc) as Void {
        _passes = 0;
        _fitCalls = 0;
        _inkCache = {} as Dictionary<Number, Array<Number> >;
        // The footer does not depend on the lines: once per solve.
        solveFooter(dc);
        for (var pass = 0; pass < 8; pass++) {
            solveOnce(dc);
            var anyHidden = false;
            var keepMisfit = false;
            for (var i = 0; i < _lines.size(); i++) {
                var line = _lines[i];
                if (line.visible && !line.isDivider && !line.fits) {
                    if (line.priority < KEEP) {
                        line.forceHidden = true;
                        anyHidden = true;
                    } else {
                        keepMisfit = true;
                    }
                }
            }
            if (!anyHidden && keepMisfit) {
                // A must-keep line is too wide for its row: a shorter block
                // sits lower, away from the narrow top rows and the lens.
                // Hide the lowest visible optional line, and keep the lines
                // already dropped for height (all lower) from refilling the
                // space, or the block would never get shorter.
                var idx = lowestDroppable(KEEP);
                if (idx >= 0) {
                    var cut = _lines[idx].priority;
                    for (var i = 0; i < _lines.size(); i++) {
                        var line = _lines[i];
                        if (i == idx || (!line.visible && !line.isDivider && line.priority <= cut)) {
                            line.forceHidden = true;
                        }
                    }
                    anyHidden = true;
                }
            }
            if (!anyHidden) { break; }
        }
        restoreHidden(dc);
        _inkCache = null;
    }

    //! A line hidden because it did not fit its row at an intermediate block
    //! position may fit where the final layout would put it. Try each hidden
    //! line again, highest priority first, and keep it when the whole layout
    //! still fits with it (no overflow, every visible line fits its row). If
    //! it does not, hide lower-priority lines (lowest first) to make room; if
    //! that does not help either, everything is put back.
    private function restoreHidden(dc as Graphics.Dc) as Void {
        var retry = [] as Array<Number>;
        for (var i = 0; i < _lines.size(); i++) {
            if (_lines[i].forceHidden) { retry.add(i); }
        }
        if (retry.size() == 0) {
            return;
        }
        // The accepted state (the current solve) is kept, so a failed last
        // retry is undone without solving again.
        var accepted = snapshot();
        var solved = true;    // is the current solve the accepted state?
        while (retry.size() > 0) {
            var best = 0;
            for (var j = 1; j < retry.size(); j++) {
                if (_lines[retry[j]].priority > _lines[retry[best]].priority) { best = j; }
            }
            var idx = retry[best];
            retry.remove(idx);
            _lines[idx].forceHidden = false;
            solveOnce(dc);
            var ok = restoredFits(idx);
            var madeRoom = [] as Array<Number>;
            while (!ok) {
                var low = lowestVisibleBelow(_lines[idx].priority, idx);
                if (low < 0) { break; }
                _lines[low].forceHidden = true;
                madeRoom.add(low);
                solveOnce(dc);
                ok = restoredFits(idx);
            }
            if (ok) {
                accepted = snapshot();
                solved = true;
            } else {
                _lines[idx].forceHidden = true;
                for (var k = 0; k < madeRoom.size(); k++) {
                    _lines[madeRoom[k]].forceHidden = false;
                }
                solved = false;
            }
        }
        if (!solved) {
            restoreSnapshot(accepted);
        }
    }

    //! Everything solveOnce() decides for the lines, to put it back later.
    private function snapshot() as Array<Array> {
        var out = [] as Array<Array>;
        for (var i = 0; i < _lines.size(); i++) {
            var l = _lines[i];
            out.add([l.visible, l.fontIndex, l.fits, l.shortened, l.y, l.slotH, l.drawFont, l.drawText,
                l.drawX, l.drawX1, l.drawY] as Array);
        }
        out.add([_overflow] as Array);
        return out;
    }

    private function restoreSnapshot(snap as Array<Array>) as Void {
        for (var i = 0; i < _lines.size(); i++) {
            var l = _lines[i];
            var v = snap[i];
            l.visible = v[0] as Boolean;
            l.fontIndex = v[1] as Number;
            l.fits = v[2] as Boolean;
            l.shortened = v[3] as Boolean;
            l.y = v[4] as Number;
            l.slotH = v[5] as Number;
            l.drawFont = v[6] as Graphics.FontDefinition;
            l.drawText = v[7] as String;
            l.drawX = v[8] as Number;
            l.drawX1 = v[9] as Number;
            l.drawY = v[10] as Number;
        }
        _overflow = snap[_lines.size()][0] as Boolean;
    }

    //! Line idx is on screen and the whole layout fits.
    private function restoredFits(idx as Number) as Boolean {
        return !_overflow && _lines[idx].visible && allLinesFit();
    }

    //! Visible optional text line (not idx) with the lowest priority below
    //! `below` (the later one on ties), or -1.
    private function lowestVisibleBelow(below as Number, idx as Number) as Number {
        var best = -1;
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (i == idx || !line.visible || line.isDivider || line.priority >= below || line.priority >= KEEP) {
                continue;
            }
            if (best < 0 || line.priority <= _lines[best].priority) { best = i; }
        }
        return best;
    }

    //! Some visible text line shows a shorter variant than its first text.
    private function anyShortened() as Boolean {
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (line.visible && !line.isDivider && line.shortened) { return true; }
        }
        return false;
    }

    //! Every visible text line fits the width of its row.
    private function allLinesFit() as Boolean {
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (line.visible && !line.isDivider && !line.fits) { return false; }
        }
        return true;
    }

    private function solveOnce(dc as Graphics.Dc) as Void {
        _passes += 1;
        _bandTop = (_h * _topPct) / 100;
        var avail = _bandBottom - _bandTop;

        for (var i = 0; i < _lines.size(); i++) {
            _lines[i].visible = !_lines[i].forceHidden;
            _lines[i].fontIndex = 0;
            _lines[i].fits = true;
        }
        var total = totalHeight(dc);

        // 1. Drop the less important optional lines, lowest priority first
        //    (later lines first on ties).
        while (total > avail) {
            var idx = lowestDroppable(IMPORTANT);
            if (idx < 0) { break; }
            _lines[idx].visible = false;
            total = totalHeight(dc);
        }
        // 2. Shrink the tallest shrinkable line, one font step at a time.
        total = shrinkToFit(dc, total, avail);
        // 3. Only then drop the important optional lines. After each drop
        //    start again from full-size fonts: nothing stays smaller than
        //    the remaining lines need.
        while (total > avail) {
            var idx = lowestDroppable(KEEP);
            if (idx < 0) { break; }
            _lines[idx].visible = false;
            for (var i = 0; i < _lines.size(); i++) {
                _lines[i].fontIndex = 0;
            }
            total = shrinkToFit(dc, totalHeight(dc), avail);
        }
        // A divider goes with the line above it.
        if (hideOrphanDividers()) {
            total = totalHeight(dc);
        }
        _overflow = (total > avail);

        // 4. Vertical positions centred in the band, 5. horizontal fit.
        var slack = avail - total;
        var y0 = _bandTop + ((slack > 0) ? slack / 2 : 0);
        placeAndFit(dc, y0);
        if (_hasSub && slack > 0 && (!allLinesFit() || anyShortened())) {
            // Next to the Instinct lens the top rows are narrow: before any
            // line is hidden or shortened, try lower block positions within
            // the band (cheap probes). Best: every line fits with its full
            // text; else the first position where every line fits at all.
            var best = -1;
            var fallback = allLinesFit() ? y0 : -1;
            for (var y = y0 + 4; y <= _bandTop + slack; y += 4) {
                var p = probeAt(dc, y);
                if (p == 2) {
                    best = y;
                    break;
                }
                if (p == 1 && fallback < 0) {
                    fallback = y;
                }
            }
            if (best < 0) {
                best = fallback;
            }
            if (best >= 0 && best != y0) {
                placeAndFit(dc, best);
            }
        }
    }

    //! Stack the visible lines from y0 and fit each one to its rows.
    private function placeAndFit(dc as Graphics.Dc, y0 as Number) as Void {
        var y = y0;
        var last = lastVisible();
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible) { continue; }
            line.y = y;
            line.slotH = slotHeight(dc, line);
            y += line.slotH;
            if (i != last) { y += gapAfter(line); }
        }
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible) { continue; }
            if (line.isDivider) {
                fitDivider(line);
                continue;
            }
            fitLine(dc, line);
        }
    }

    //! How the visible lines would fit with the block starting at y0, without
    //! changing them: 0 = some line does not fit, 1 = all fit but some need
    //! a shorter text, 2 = all fit with their full text. Stops at the first
    //! line that does not fit.
    private function probeAt(dc as Graphics.Dc, y0 as Number) as Number {
        var y = y0;
        var last = lastVisible();
        var result = 2;
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible) { continue; }
            var slotH = slotHeight(dc, line);
            if (!line.isDivider) {
                var f = probeLine(dc, line, y, slotH);
                if (f == 0) {
                    return 0;
                }
                if (f == 1) {
                    result = 1;
                }
            }
            y += slotH;
            if (i != last) { y += gapAfter(line); }
        }
        return result;
    }

    //! fitLine's choice at a given slot, without storing it: 2 = the first
    //! text fits, 1 = only a shorter text fits, 0 = nothing fits.
    private function probeLine(dc as Graphics.Dc, line as LayoutLine, y as Number, slotH as Number) as Number {
        _fitCalls += 1;
        for (var ti = 0; ti < line.texts.size(); ti++) {
            for (var fi = line.fontIndex; fi < line.fonts.size(); fi++) {
                var font = line.fonts[fi];
                var fh = dc.getFontHeight(font);
                if (fh > slotH && fi != line.fontIndex) { continue; }
                var b = inkBounds(y + (slotH - fh) / 2, fh);
                if (dc.getTextWidthInPixels(line.texts[ti], font) <= b[1] - b[0]) {
                    return (ti == 0) ? 2 : 1;
                }
            }
        }
        return 0;
    }

    //! A divider is centred and clipped to the visible width of its row.
    private function fitDivider(line as LayoutLine) as Void {
        line.drawY = line.y;
        if (line.spacerH > 0) {
            line.drawX = _cx;
            line.drawX1 = _cx;
            return;
        }
        var b = inkBounds(line.y, 1);
        var left = _cx - line.dividerHalf;
        var right = _cx + line.dividerHalf;
        if (left < b[0]) { left = b[0]; }
        if (right > b[1]) { right = b[1]; }
        line.drawX = left;
        line.drawX1 = (right > left) ? right : left;
    }

    //! Hide dividers whose title line is hidden; true if any changed.
    private function hideOrphanDividers() as Boolean {
        var changed = false;
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (line.visible && line.linkedTo >= 0 && !_lines[line.linkedTo].visible) {
                line.visible = false;
                changed = true;
            }
        }
        return changed;
    }

    //! Full text first (at the largest font that fits), shorter variants only
    //! when even the smallest font is too wide.
    private function fitLine(dc as Graphics.Dc, line as LayoutLine) as Void {
        _fitCalls += 1;
        var chosen = false;
        for (var ti = 0; ti < line.texts.size() && !chosen; ti++) {
            for (var fi = line.fontIndex; fi < line.fonts.size(); fi++) {
                var font = line.fonts[fi];
                var fh = dc.getFontHeight(font);
                if (fh > line.slotH && fi != line.fontIndex) { continue; }
                var ty = line.y + (line.slotH - fh) / 2;
                var b = inkBounds(ty, fh);
                if (dc.getTextWidthInPixels(line.texts[ti], font) <= b[1] - b[0]) {
                    line.drawFont = font;
                    line.drawText = line.texts[ti];
                    line.drawX = (b[0] + b[1]) / 2;
                    line.drawY = ty;
                    line.fits = true;
                    line.shortened = (ti > 0);
                    chosen = true;
                    break;
                }
            }
        }
        if (!chosen) {
            // Nothing fits: smallest font, shortest text, centred.
            var font = line.fonts[line.fonts.size() - 1];
            var fh = dc.getFontHeight(font);
            var ty = line.y + (line.slotH - fh) / 2;
            var b = inkBounds(ty, fh);
            line.drawFont = font;
            line.drawText = line.texts[line.texts.size() - 1];
            line.drawX = (b[0] + b[1]) / 2;
            line.drawY = ty;
            line.fits = false;
            line.shortened = true;
        }
    }

    //! Footer placement (see setFooterTexts / setFooterChoices). It never
    //! moves above FOOTER_MIN_PCT of the height: a hint that does not fit
    //! lower uses a shorter variant, and if none fits the shortest one sits
    //! at the bottom row, so the band keeps its room either way.
    private function solveFooter(dc as Graphics.Dc) as Void {
        var fh = dc.getFontHeight(_footerFont);
        if (_footerTexts == null) {
            _bandBottom = _h - lowestUsableInset(fh);
            return;
        }
        var texts = _footerTexts as Array<String>;
        var bottom = _h - fh - 2;
        var limit = _h * FOOTER_MIN_PCT / 100;
        var first = 0;
        if (_footerPreferBottom) {
            var b0 = inkBounds(bottom, fh);
            for (var i = 0; i < texts.size(); i++) {
                if (dc.getTextWidthInPixels(texts[i], _footerFont) <= b0[1] - b0[0]) {
                    placeFooter(texts[i], bottom, b0, true);
                    return;
                }
            }
            first = texts.size() - 1;              // then only the shortest may move up
        }
        for (var i = first; i < texts.size(); i++) {
            var tw = dc.getTextWidthInPixels(texts[i], _footerFont);
            var y = bottom;
            var b = inkBounds(y, fh);
            while (y > limit && (b[1] - b[0]) < tw) {
                y -= 2;
                b = inkBounds(y, fh);
            }
            if ((b[1] - b[0]) >= tw) {
                placeFooter(texts[i], y, b, true);
                return;
            }
        }
        placeFooter(texts[texts.size() - 1], bottom, inkBounds(bottom, fh), false);
    }

    private function placeFooter(text as String, y as Number, b as Array<Number>, fits as Boolean) as Void {
        _footerText = text;
        _footerY = y;
        _footerX = (b[0] + b[1]) / 2;
        _footerFits = fits;
        _bandBottom = y - _gap;
    }

    //! Without a footer keep the last line out of the narrowest bottom rows.
    private function lowestUsableInset(fh as Number) as Number {
        return (_shape == System.SCREEN_SHAPE_ROUND) ? (_h * 12 / 100) : (_gap + 2);
    }

    //! Shrink the tallest shrinkable line one font step at a time until the
    //! block fits or nothing can shrink; returns the new total height.
    private function shrinkToFit(dc as Graphics.Dc, total as Number, avail as Number) as Number {
        while (total > avail) {
            var idx = tallestShrinkable(dc);
            if (idx < 0) { break; }
            _lines[idx].fontIndex += 1;
            total = totalHeight(dc);
        }
        return total;
    }

    private function totalHeight(dc as Graphics.Dc) as Number {
        var total = 0;
        var last = lastVisible();
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible) { continue; }
            total += slotHeight(dc, line);
            if (i != last) { total += gapAfter(line); }
        }
        return total;
    }

    private function slotHeight(dc as Graphics.Dc, line as LayoutLine) as Number {
        if (line.isDivider) { return (line.spacerH > 0) ? line.spacerH : 1; }
        return dc.getFontHeight(line.fonts[line.fontIndex]);
    }

    private function gapAfter(line as LayoutLine) as Number {
        return (line.gapAfter >= 0) ? line.gapAfter : _gap;
    }

    private function lastVisible() as Number {
        for (var i = _lines.size() - 1; i >= 0; i--) {
            if (_lines[i].visible) { return i; }
        }
        return -1;
    }

    //! Visible optional line with the lowest priority below `below` (the
    //! later one on ties), or -1.
    private function lowestDroppable(below as Number) as Number {
        var best = -1;
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible || line.priority >= below) { continue; }
            if (best < 0 || line.priority <= _lines[best].priority) { best = i; }
        }
        return best;
    }

    private function tallestShrinkable(dc as Graphics.Dc) as Number {
        var best = -1;
        var bestH = -1;
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible || line.isDivider || line.fontIndex >= line.fonts.size() - 1) { continue; }
            var h = dc.getFontHeight(line.fonts[line.fontIndex]);
            var next = dc.getFontHeight(line.fonts[line.fontIndex + 1]);
            if (next >= h) { continue; }  // no gain
            if (h > bestH) { best = i; bestH = h; }
        }
        return best;
    }

    // -- Geometry -------------------------------------------------------

    //! Horizontal [left, right] available to text whose slot starts at y
    //! with font height fh (ink assumed within 15-85 % of the height).
    private function inkBounds(y as Number, fh as Number) as Array<Number> {
        var cache = _inkCache;
        var key = y * 1024 + fh;
        if (cache != null) {
            var hit = cache[key];
            if (hit != null) {
                return hit;
            }
        }
        var y0 = y + fh * 15 / 100;
        var y1 = y + fh * 85 / 100;
        var hw0 = halfWidthAt(y0);
        var hw1 = halfWidthAt(y1);
        var hw = (hw0 < hw1) ? hw0 : hw1;
        var left = _cx - hw + _edgeMargin;
        var right = _cx + hw - _edgeMargin;
        if (_hasSub) {
            // The subscreen lens and its bezel form a circle around the
            // subscreen box (measured on the Instinct 3: radius = w/2 + 13).
            var ncx = _subX + _subW / 2;
            var ncy = _subY + _subH / 2;
            var nr = _subW / 2 + 13;
            var ry = (ncy < y0) ? y0 : ((ncy > y1) ? y1 : ncy);   // ink row nearest the lens
            var dy = (ry - ncy).abs();
            if (dy < nr) {
                var half = Math.sqrt((nr * nr - dy * dy).toFloat()).toNumber();
                if (ncx >= _cx) {
                    var limit = ncx - half - _edgeMargin;
                    if (right > limit) { right = limit; }
                } else {
                    var limit = ncx + half + _edgeMargin;
                    if (left < limit) { left = limit; }
                }
            }
        }
        if (right < left) { right = left; }
        var result = [left, right] as Array<Number>;
        if (cache != null) {
            cache.put(key, result);
        }
        return result;
    }

    //! Half of the usable display width at row y (display outline, and the
    //! clip circle when one is set).
    private function halfWidthAt(y as Number) as Number {
        var hw = shapeHalfWidthAt(y);
        if (_clipRadius > 0 && hw > 0) {
            var dy = (y - _cy).abs();
            if (dy >= _clipRadius) { return 0; }
            var c = Math.sqrt((_clipRadius * _clipRadius - dy * dy).toFloat()).toNumber();
            if (c < hw) { hw = c; }
        }
        return hw;
    }

    //! Half of the visible display width at row y.
    private function shapeHalfWidthAt(y as Number) as Number {
        if (y < 0 || y >= _h) { return 0; }
        if (_shape == System.SCREEN_SHAPE_ROUND) {
            var r = _w / 2;
            var dy = (y - _cy).abs();
            if (dy >= r) { return 0; }
            return Math.sqrt((r * r - dy * dy).toFloat()).toNumber();
        }
        if (_shape == System.SCREEN_SHAPE_SEMI_OCTAGON) {
            // Octagon-like outline: corners bevelled over the outer 24 %
            // (fitted to the Instinct 3 Solar display outline).
            var cut = _w * 24 / 100;
            var edge = (y < _h - 1 - y) ? y : (_h - 1 - y);
            var c = cut - edge;
            if (c < 0) { c = 0; }
            return _w / 2 - c;
        }
        return _w / 2;
    }

    // -- Drawing --------------------------------------------------------

    function draw(dc as Graphics.Dc, invert as Boolean) as Void {
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible) { continue; }
            if (line.spacerH > 0) {
                continue;
            }
            dc.setColor(Palette.fg(line.color, invert), Graphics.COLOR_TRANSPARENT);
            if (line.isDivider) {
                if (line.drawX1 > line.drawX) {
                    dc.drawLine(line.drawX, line.y, line.drawX1, line.y);
                }
            } else {
                dc.drawText(line.drawX, line.drawY, line.drawFont, line.drawText,
                    Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
        if (_footerText != null) {
            dc.setColor(Palette.fg(_footerColor, invert), Graphics.COLOR_TRANSPARENT);
            dc.drawText(_footerX, _footerY, _footerFont, _footerText as String,
                Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // -- Inspection (tests) ---------------------------------------------

    //! Content did not fit even after dropping and shrinking.
    function hasOverflow() as Boolean { return _overflow; }

    //! Every visible text line and the footer fit the visible width.
    function allTextFits() as Boolean {
        if (!_footerFits) { return false; }
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (line.visible && !line.isDivider && !line.fits) { return false; }
        }
        return true;
    }

    //! Last visible line ends above the footer (no overprint).
    function clearOfFooter(dc as Graphics.Dc) as Boolean {
        if (_footerText == null) { return true; }
        var last = lastVisible();
        if (last < 0) { return true; }
        var line = _lines[last];
        return line.y + line.slotH <= _footerY;
    }

    //! Whether a visible line currently shows exactly this text.
    function showsText(text as String) as Boolean {
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (line.visible && !line.isDivider && text.equals(line.drawText)) { return true; }
        }
        return false;
    }

    //! Whether a visible line contains this fragment.
    function showsFragment(fragment as String) as Boolean {
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (line.visible && !line.isDivider && line.drawText.find(fragment) != null) {
                return true;
            }
        }
        return false;
    }

    //! Text of the first visible line (or the footer) that does not fit, or null.
    function firstMisfit() as String? {
        if (!_footerFits) { return "footer: " + _footerText; }
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (line.visible && !line.isDivider && !line.fits) { return line.drawText; }
        }
        return null;
    }

    function getFooterText() as String? { return _footerText; }

    //! Work done by the last solve(): [solveOnce passes, fitLine calls].
    //! Screens redraw every second, so this is what the watchdog sees.
    (:debug)
    function testWork() as Array<Number> {
        return [_passes, _fitCalls] as Array<Number>;
    }

    //! Every visible divider lies within the visible width of its row and
    //! follows a visible line (tests).
    (:debug)
    function testDividersFit() as Boolean {
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible || !line.isDivider || line.spacerH > 0) { continue; }
            if (line.linkedTo >= 0 && !_lines[line.linkedTo].visible) { return false; }
            var b = inkBounds(line.y, 1);
            if (line.drawX1 > line.drawX && (line.drawX < b[0] || line.drawX1 > b[1])) { return false; }
        }
        return true;
    }

    //! Height of the font line `index` is drawn with (tests).
    (:debug)
    function testSlotHeight(index as Number) as Number {
        return _lines[index].slotH;
    }

    //! One line per text line: visibility, text, y, slot height (tests).
    (:debug)
    function testDescribe() as String {
        var out = "band " + _bandTop + ".." + _bandBottom + " footerY " + _footerY + " passes " + _passes
            + " fits " + _fitCalls + "\n";
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            out += (line.visible ? "  + " : "  - ") + "p" + line.priority + " '" + line.drawText + "' y" + line.y
                + " h" + line.slotH + (line.forceHidden ? " HIDDEN" : "") + (line.fits ? "" : " MISFIT")
                + (line.shortened ? " short" : "") + "\n";
        }
        return out;
    }
    function getFooterY() as Number { return _footerY; }
}
