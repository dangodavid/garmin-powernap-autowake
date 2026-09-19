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

//! One line of a screen: a text (with shorter alternatives) or a divider.
class LayoutLine {
    var texts as Array<String>;                    // longest first
    var fonts as Array<Graphics.FontDefinition>;   // largest first
    var color as Graphics.ColorType;
    var priority as Number;                        // >= ScreenLayout.KEEP is never dropped
    var isDivider as Boolean;
    var dividerHalf as Number = 0;
    var gapAfter as Number = -1;                   // -1 = layout default

    // Solved by ScreenLayout.solve()
    var forceHidden as Boolean = false;   // optional line too wide for its row
    var visible as Boolean = true;
    var fontIndex as Number = 0;
    var y as Number = 0;          // slot top
    var slotH as Number = 0;
    var drawFont as Graphics.FontDefinition;
    var drawText as String;
    var drawX as Number = 0;
    var drawY as Number = 0;
    var fits as Boolean = true;

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
//!   If they do not fit, the lowest-priority lines are dropped first, then
//!   lines move to smaller fonts. Lines at or above KEEP are never dropped.
//! * Each text line then picks the largest font/text variant whose ink fits
//!   the visible width at its own rows (round chord, Instinct subscreen).
class ScreenLayout {

    static const KEEP = 100;

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

    private var _footerText as String? = null;
    private var _footerColor as Graphics.ColorType = Graphics.COLOR_LT_GRAY;
    private var _footerFont as Graphics.FontDefinition = Graphics.FONT_XTINY;
    private var _footerX as Number = 0;
    private var _footerY as Number = 0;
    private var _footerFits as Boolean = true;

    private var _bandTop as Number = 0;
    private var _bandBottom as Number = 0;
    private var _overflow as Boolean = false;

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

    function addDivider(halfWidthPct as Number, color as Graphics.ColorType, priority as Number) as LayoutLine {
        var line = new LayoutLine([""] as Array<String>,
            [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, color, priority, true);
        line.dividerHalf = _w * halfWidthPct / 100;
        _lines.add(line);
        return line;
    }

    function setFooter(text as String, color as Graphics.ColorType) as Void {
        _footerText = text;
        _footerColor = color;
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
        for (var pass = 0; pass < 4; pass++) {
            solveOnce(dc);
            var anyHidden = false;
            for (var i = 0; i < _lines.size(); i++) {
                var line = _lines[i];
                if (line.visible && !line.isDivider && !line.fits && line.priority < KEEP) {
                    line.forceHidden = true;
                    anyHidden = true;
                }
            }
            if (!anyHidden) { return; }
        }
        solveOnce(dc);
    }

    private function solveOnce(dc as Graphics.Dc) as Void {
        solveFooter(dc);
        _bandTop = (_h * _topPct) / 100;
        var avail = _bandBottom - _bandTop;

        for (var i = 0; i < _lines.size(); i++) {
            _lines[i].visible = !_lines[i].forceHidden;
            _lines[i].fontIndex = 0;
            _lines[i].fits = true;
        }
        var total = totalHeight(dc);

        // 1. Drop optional lines, lowest priority first (later lines first on ties).
        while (total > avail) {
            var idx = lowestDroppable();
            if (idx < 0) { break; }
            _lines[idx].visible = false;
            total = totalHeight(dc);
        }
        // 2. Shrink the tallest shrinkable line, one font step at a time.
        while (total > avail) {
            var idx = tallestShrinkable(dc);
            if (idx < 0) { break; }
            _lines[idx].fontIndex += 1;
            total = totalHeight(dc);
        }
        _overflow = (total > avail);

        // 3. Vertical positions, centred in the band.
        var y = _bandTop;
        if (avail > total) { y += (avail - total) / 2; }
        var last = lastVisible();
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible) { continue; }
            line.y = y;
            line.slotH = slotHeight(dc, line);
            y += line.slotH;
            if (i != last) { y += gapAfter(line); }
        }

        // 4. Horizontal fit per line.
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible) { continue; }
            if (line.isDivider) {
                line.drawX = _cx;
                line.drawY = line.y;
                continue;
            }
            fitLine(dc, line);
        }
    }

    //! Full text first (at the largest font that fits), shorter variants only
    //! when even the smallest font is too wide.
    private function fitLine(dc as Graphics.Dc, line as LayoutLine) as Void {
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
        }
    }

    //! Footer: as low as possible while its text fits the visible width.
    private function solveFooter(dc as Graphics.Dc) as Void {
        var fh = dc.getFontHeight(_footerFont);
        if (_footerText == null) {
            _bandBottom = _h - lowestUsableInset(fh);
            return;
        }
        var tw = dc.getTextWidthInPixels(_footerText as String, _footerFont);
        var y = _h - fh - 2;
        var b = inkBounds(y, fh);
        while (y > _cy && (b[1] - b[0]) < tw) {
            y -= 2;
            b = inkBounds(y, fh);
        }
        _footerY = y;
        _footerX = (b[0] + b[1]) / 2;
        _footerFits = (b[1] - b[0]) >= tw;
        _bandBottom = y - _gap;
    }

    //! Without a footer keep the last line out of the narrowest bottom rows.
    private function lowestUsableInset(fh as Number) as Number {
        return (_shape == System.SCREEN_SHAPE_ROUND) ? (_h * 12 / 100) : (_gap + 2);
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
        if (line.isDivider) { return 1; }
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

    private function lowestDroppable() as Number {
        var best = -1;
        for (var i = 0; i < _lines.size(); i++) {
            var line = _lines[i];
            if (!line.visible || line.priority >= KEEP) { continue; }
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
        return [left, right] as Array<Number>;
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
            dc.setColor(Palette.fg(line.color, invert), Graphics.COLOR_TRANSPARENT);
            if (line.isDivider) {
                dc.drawLine(_cx - line.dividerHalf, line.y, _cx + line.dividerHalf, line.y);
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
    function getFooterY() as Number { return _footerY; }
}
